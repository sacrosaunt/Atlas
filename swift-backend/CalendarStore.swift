import Foundation
import CryptoKit

final class CalendarStore: @unchecked Sendable {
    private let snapshotPath: URL
    private let identityKey: SymmetricKey
    private let lock = NSLock()
    private var cached: JSONValue?
    private var cachedModification: Date?

    init(snapshotPath: URL, identitySecret: String) {
        self.snapshotPath = snapshotPath
        identityKey = SymmetricKey(data: Data(identitySecret.utf8))
    }

    func status() throws -> JSONValue {
        guard let snapshot = try reload() else {
            return .object([
                "connected": .bool(false), "event_count": .number(0), "calendars": .array([]),
                "updated_at": .null, "range_start": .null, "range_end": .null,
            ])
        }
        let events = snapshot["events"]?.arrayValue ?? []
        var calendars: [String: (name: String, count: Int)] = [:]
        for event in events {
            let source = event["calendar_id"]?.stringValue ?? event["calendar"]?.stringValue ?? "calendar"
            let current = calendars[source] ?? (event["calendar"]?.stringValue ?? "Calendar", 0)
            calendars[source] = (current.name, current.count + 1)
        }
        let values = calendars.map { source, entry in JSONValue.object([
            "calendar_id": .string(opaqueID("calendar", source)),
            "name": .string(entry.name), "event_count": .number(Double(entry.count)),
        ]) }.sorted { ($0["name"]?.stringValue ?? "") < ($1["name"]?.stringValue ?? "") }
        return .object([
            "connected": .bool(true), "event_count": .number(Double(events.count)),
            "calendars": .array(values), "updated_at": snapshot["updated_at"] ?? .null,
            "range_start": snapshot["range_start"] ?? .null, "range_end": snapshot["range_end"] ?? .null,
        ])
    }

    func searchEvents(_ arguments: JSONValue) throws -> JSONValue {
        guard let snapshot = try reload() else { throw CalendarError.notConnected }
        let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var since = try parseDate(arguments["since"]?.stringValue, name: "since")
        var until = try parseDate(arguments["until"]?.stringValue, name: "until")
        if let since, let until, until <= since { throw CalendarError.invalid("until must be after since") }
        if query.isEmpty && since == nil && until == nil {
            let calendar = Calendar.current
            since = calendar.startOfDay(for: Date())
            until = calendar.date(byAdding: .year, value: 1, to: since!)
        }
        let requestedCalendars = Set(arguments["calendar_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let limit = try normalizedLimit(arguments["limit"]?.intValue, fallback: 100, maximum: 1_000)
        let events = snapshot["events"]?.arrayValue ?? []
        let matches = events.filter { event in
            guard let start = parseEventDate(event["start_at"]?.stringValue),
                  let end = parseEventDate(event["end_at"]?.stringValue) else { return false }
            if let since, end < since { return false }
            if let until, start >= until { return false }
            let source = event["calendar_id"]?.stringValue ?? event["calendar"]?.stringValue ?? "calendar"
            if !requestedCalendars.isEmpty && !requestedCalendars.contains(opaqueID("calendar", source)) { return false }
            guard !query.isEmpty else { return true }
            return ["title", "calendar", "location", "notes"].contains { key in
                event[key]?.stringValue?.lowercased().contains(query) == true
            }
        }.sorted { (parseEventDate($0["start_at"]?.stringValue) ?? .distantPast) < (parseEventDate($1["start_at"]?.stringValue) ?? .distantPast) }
        return .object([
            "events": .array(matches.prefix(limit).map { eventResult($0, fullDetails: false) }),
            "total_matches": .number(Double(matches.count)), "returned": .number(Double(min(matches.count, limit))),
            "snapshot_updated_at": snapshot["updated_at"] ?? .null,
            "snapshot_range": .object(["since": snapshot["range_start"] ?? .null, "until": snapshot["range_end"] ?? .null]),
        ])
    }

    func readEvents(_ arguments: JSONValue) throws -> JSONValue {
        guard let snapshot = try reload() else { throw CalendarError.notConnected }
        let eventIDs = arguments["event_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard (1...100).contains(eventIDs.count) else {
            throw CalendarError.invalid("event_ids must contain between 1 and 100 opaque event IDs")
        }
        let requested = Set(eventIDs)
        let events = (snapshot["events"]?.arrayValue ?? []).filter { event in
            guard let source = event["source_id"]?.stringValue else { return false }
            return requested.contains(opaqueID("event", source))
        }.map { eventResult($0, fullDetails: true) }
        return .object([
            "events": .array(events), "requested": .number(Double(requested.count)), "found": .number(Double(events.count)),
        ])
    }

    private func reload() throws -> JSONValue? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: snapshotPath.path),
              let modification = attributes[.modificationDate] as? Date else {
            return lock.withLock { cached = nil; cachedModification = nil; return nil }
        }
        if let value = lock.withLock({ cachedModification == modification ? cached : nil }) { return value }
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: snapshotPath))
        guard value["format_version"]?.intValue == 1, value["events"]?.arrayValue != nil else {
            throw CalendarError.invalid("Atlas's local calendar snapshot is invalid; reconnect Calendar in Settings")
        }
        lock.withLock { cached = value; cachedModification = modification }
        return value
    }

    private func eventResult(_ event: JSONValue, fullDetails: Bool) -> JSONValue {
        let source = event["source_id"]?.stringValue ?? "event"
        let calendarSource = event["calendar_id"]?.stringValue ?? event["calendar"]?.stringValue ?? "calendar"
        var value: [String: JSONValue] = [
            "event_id": .string(opaqueID("event", source)),
            "title": .string(event["title"]?.stringValue ?? "Untitled event"),
            "start_at": event["start_at"] ?? .null, "end_at": event["end_at"] ?? .null,
            "is_all_day": .bool(event["is_all_day"]?.boolValue == true),
            "calendar": .object(["calendar_id": .string(opaqueID("calendar", calendarSource)), "name": .string(event["calendar"]?.stringValue ?? "Calendar")]),
            "location": event["location"] ?? .null,
            "status": .string(event["status"]?.stringValue ?? "none"),
            "availability": .string(event["availability"]?.stringValue ?? "not_supported"),
        ]
        if fullDetails {
            value["notes"] = event["notes"]?.stringValue.map { .string(String($0.prefix(10_000))) } ?? .null
        } else {
            value["notes_preview"] = event["notes"]?.stringValue.map { .string(String($0.prefix(280))) } ?? .null
        }
        return .object(value)
    }

    private func opaqueID(_ kind: String, _ source: String) -> String {
        let digest = HMAC<SHA256>.authenticationCode(for: Data("\(kind):\(source)".utf8), using: identityKey)
        let encoded = Data(digest).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "\(kind)_\(encoded.prefix(22))"
    }

    private func parseDate(_ value: String?, name: String) throws -> Date? {
        guard let value, !value.isEmpty else { return nil }
        guard let date = parseEventDate(value) else { throw CalendarError.invalid("\(name) must be an ISO-8601 date") }
        return date
    }

    private func parseEventDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func normalizedLimit(_ value: Int?, fallback: Int, maximum: Int) throws -> Int {
        let result = value ?? fallback
        guard (1...maximum).contains(result) else { throw CalendarError.invalid("limit must be between 1 and \(maximum)") }
        return result
    }
}

enum CalendarError: Error, LocalizedError {
    case notConnected
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Calendar is not connected. Connect it in Atlas Settings first."
        case .invalid(let value): return value
        }
    }
}
