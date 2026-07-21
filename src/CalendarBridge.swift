import EventKit
import Foundation
import SwiftUI

private let atlasCalendarEnabledKey = "atlas.calendar.enabled"
private let atlasCalendarSnapshotURL = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Application Support/Atlas/calendar-events.json")

enum AtlasCalendarConnectionState: Equatable {
    case disconnected
    case requesting
    case syncing
    case connected
    case denied
    case restricted
    case error(String)
}

private struct AtlasCalendarEventRecord: Codable, Sendable {
    let sourceID: String
    let calendarID: String
    let calendar: String
    let title: String
    let startAt: Date
    let endAt: Date
    let isAllDay: Bool
    let location: String?
    let notes: String?
    let status: String
    let availability: String
}

private struct AtlasCalendarSnapshot: Codable, Sendable {
    let formatVersion: Int
    let updatedAt: Date
    let rangeStart: Date
    let rangeEnd: Date
    let events: [AtlasCalendarEventRecord]
}

@MainActor
final class AtlasCalendarBridge: ObservableObject {
    @Published private(set) var state: AtlasCalendarConnectionState = .disconnected
    @Published private(set) var eventCount = 0
    @Published private(set) var updatedAt: Date?

    private let eventStore = EKEventStore()
    private var syncInProgress = false

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: atlasCalendarEnabledKey)
    }

    func refresh(force: Bool = false) async {
        let authorization = EKEventStore.authorizationStatus(for: .event)
        guard authorization == .fullAccess else {
            if authorization == .denied {
                state = .denied
            } else if authorization == .restricted {
                state = .restricted
            } else {
                state = .disconnected
            }
            if authorization == .denied || authorization == .restricted {
                clearSnapshot()
            } else {
                loadSnapshotMetadata()
            }
            return
        }
        guard isEnabled else {
            state = .disconnected
            loadSnapshotMetadata()
            return
        }
        loadSnapshotMetadata()
        if !force, let updatedAt, Date().timeIntervalSince(updatedAt) < 15 * 60 {
            state = .connected
            return
        }
        await synchronize()
    }

    func connect() async {
        state = .requesting
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            guard granted else {
                UserDefaults.standard.set(false, forKey: atlasCalendarEnabledKey)
                state = .denied
                clearSnapshot()
                return
            }
            UserDefaults.standard.set(true, forKey: atlasCalendarEnabledKey)
            eventStore.reset()
            await synchronize()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func disconnect() {
        UserDefaults.standard.set(false, forKey: atlasCalendarEnabledKey)
        clearSnapshot()
        state = .disconnected
    }

    private func synchronize() async {
        guard !syncInProgress else { return }
        syncInProgress = true
        state = .syncing
        defer { syncInProgress = false }
        do {
            let snapshot = await buildCalendarSnapshot()
            try writeCalendarSnapshot(snapshot)
            eventCount = snapshot.events.count
            updatedAt = snapshot.updatedAt
            state = .connected
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func loadSnapshotMetadata() {
        guard let data = try? Data(contentsOf: atlasCalendarSnapshotURL) else {
            eventCount = 0
            updatedAt = nil
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let snapshot = try? decoder.decode(AtlasCalendarSnapshot.self, from: data) else {
            eventCount = 0
            updatedAt = nil
            return
        }
        eventCount = snapshot.events.count
        updatedAt = snapshot.updatedAt
    }

    private func clearSnapshot() {
        try? FileManager.default.removeItem(at: atlasCalendarSnapshotURL)
        eventCount = 0
        updatedAt = nil
    }
}

private func buildCalendarSnapshot() async -> AtlasCalendarSnapshot {
    await Task.detached(priority: .utility) {
        let store = EKEventStore()
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1))!
        let end = calendar.date(byAdding: .year, value: 5, to: Date())!
        let calendars = store.calendars(for: .event)
        var cursor = start
        var records: [String: AtlasCalendarEventRecord] = [:]

        while cursor < end {
            let next = min(calendar.date(byAdding: .year, value: 1, to: cursor)!, end)
            let predicate = store.predicateForEvents(withStart: cursor, end: next, calendars: calendars)
            for event in store.events(matching: predicate) {
                let identifier = event.eventIdentifier ?? "event"
                let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let sourceID = [event.calendar.calendarIdentifier, identifier, event.startDate.ISO8601Format()]
                    .joined(separator: "|")
                records[sourceID] = AtlasCalendarEventRecord(
                    sourceID: sourceID,
                    calendarID: event.calendar.calendarIdentifier,
                    calendar: event.calendar.title,
                    title: title.isEmpty ? "Untitled event" : title,
                    startAt: event.startDate,
                    endAt: event.endDate,
                    isAllDay: event.isAllDay,
                    location: event.location,
                    notes: event.notes,
                    status: atlasEventStatus(event.status),
                    availability: atlasEventAvailability(event.availability)
                )
            }
            cursor = next
        }

        return AtlasCalendarSnapshot(
            formatVersion: 1,
            updatedAt: Date(),
            rangeStart: start,
            rangeEnd: end,
            events: records.values.sorted { $0.startAt < $1.startAt }
        )
    }.value
}

private func writeCalendarSnapshot(_ snapshot: AtlasCalendarSnapshot) throws {
    let directory = atlasCalendarSnapshotURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(snapshot)
    try data.write(to: atlasCalendarSnapshotURL, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: atlasCalendarSnapshotURL.path
    )
}

private func atlasEventStatus(_ status: EKEventStatus) -> String {
    switch status {
    case .confirmed: return "confirmed"
    case .tentative: return "tentative"
    case .canceled: return "canceled"
    default: return "none"
    }
}

private func atlasEventAvailability(_ availability: EKEventAvailability) -> String {
    switch availability {
    case .busy: return "busy"
    case .free: return "free"
    case .tentative: return "tentative"
    case .unavailable: return "unavailable"
    default: return "not_supported"
    }
}
