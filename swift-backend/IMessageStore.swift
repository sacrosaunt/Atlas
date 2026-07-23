import Foundation
import CryptoKit

private let appleEpochSeconds = 978_307_200.0

struct IMessageInfo: Codable, Sendable {
    let access: String
    let messages: Int
    let conversations: Int
    let people: Int
}

struct IndexableConversation: Sendable {
    let conversationID: String
    let name: String
    let personIDs: [String]
    let messageCount: Int
}

struct IndexableMessagePage: Sendable {
    let messages: [JSONValue]
    let scannedThroughMessageID: Int
    let hasMore: Bool
}

final class IMessageStore: @unchecked Sendable {
    private let databasePath: String
    private let identityKey: SymmetricKey
    private let contacts: ContactIndex
    private let identityLock = NSLock()
    private var conversationByPublicID: [String: Int] = [:]
    private var personByPublicID: [String: Int] = [:]

    init(databasePath: URL, home: URL, identitySecret: String) {
        self.databasePath = databasePath.path
        identityKey = SymmetricKey(data: Data(identitySecret.utf8))
        contacts = ContactIndex(home: home)
    }

    func info() throws -> IMessageInfo {
        do {
            let database = try openDatabase()
            let row = try database.query("""
            SELECT
              (SELECT COUNT(*) FROM message WHERE item_type = 0) AS messages,
              (SELECT COUNT(*) FROM chat c WHERE EXISTS (
                SELECT 1 FROM chat_message_join cmj
                JOIN message m ON m.ROWID = cmj.message_id
                WHERE cmj.chat_id = c.ROWID AND m.item_type = 0
                LIMIT 1
              )) AS conversations,
              (SELECT COUNT(*) FROM handle) AS handles
            """).first ?? [:]
            return .init(
                access: "read-only",
                messages: row["messages"]?.int ?? 0,
                conversations: row["conversations"]?.int ?? 0,
                people: row["handles"]?.int ?? 0
            )
        } catch {
            throw IMessageError.fullDiskAccess
        }
    }

    func listConversations(query: String? = nil, limit: Int? = nil) throws -> JSONValue {
        let database = try openDatabase()
        let safeLimit = clamp(limit, minimum: 1, maximum: 100, fallback: 25)
        let search = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let like = search.flatMap { $0.isEmpty ? nil : "%\($0)%" }
        let rows = try database.query("""
        SELECT c.ROWID AS chat_id, c.display_name, c.service_name, c.is_archived,
          (SELECT GROUP_CONCAT(h.id, ', ')
             FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id
            WHERE chj.chat_id = c.ROWID) AS participants,
          CASE WHEN ABS(MAX(cmj.message_date)) > 1000000000000
            THEN CAST(MAX(cmj.message_date) / 1000000000 AS INTEGER)
            ELSE MAX(cmj.message_date) END AS last_apple_seconds
        FROM chat c LEFT JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
        WHERE (? IS NULL OR c.display_name LIKE ? COLLATE NOCASE
          OR c.chat_identifier LIKE ? COLLATE NOCASE
          OR EXISTS (SELECT 1 FROM chat_handle_join s
             JOIN handle h ON h.ROWID = s.handle_id
            WHERE s.chat_id = c.ROWID AND h.id LIKE ? COLLATE NOCASE))
        GROUP BY c.ROWID ORDER BY MAX(cmj.message_date) DESC LIMIT ?
        """, bindings: [
            like.map(SQLiteValue.text) ?? .null,
            like.map(SQLiteValue.text) ?? .null,
            like.map(SQLiteValue.text) ?? .null,
            like.map(SQLiteValue.text) ?? .null,
            .integer(Int64(safeLimit)),
        ])
        let mapped = rows.compactMap { row -> JSONValue? in
            guard let chatID = row["chat_id"]?.int else { return nil }
            let participantIdentifiers = row["participants"]?.string?.components(separatedBy: ", ") ?? []
            let participants = participantIdentifiers.map(personForIdentifier)
            if let search, !search.isEmpty {
                let metadataMatch = contactsMatch(participantIdentifiers, query: search)
                let databaseMatch = [row["display_name"]?.string, participantIdentifiers.joined(separator: ", ")]
                    .compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(search) }
                if !metadataMatch && !databaseMatch { return nil }
            }
            return .object([
                "conversation_id": .string(conversationID(chatID)),
                "name": .string(safeConversationName(row["display_name"]?.string, participants: participants)),
                "participants": .array(participants),
                "service": row["service_name"]?.string.map(JSONValue.string) ?? .null,
                "archived": .bool((row["is_archived"]?.int ?? 0) != 0),
                "last_message_at": appleISO(row["last_apple_seconds"]?.double).map(JSONValue.string) ?? .null,
            ])
        }
        return .array(Array(mapped.prefix(safeLimit)))
    }

    func listPeople(query: String? = nil, limit: Int? = nil) throws -> JSONValue {
        let database = try openDatabase()
        let safeLimit = clamp(limit, minimum: 1, maximum: 200, fallback: 50)
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rows = try database.query("""
        SELECT h.id AS identifier, COUNT(DISTINCT chj.chat_id) AS conversation_count,
          CASE WHEN ABS(MAX(cmj.message_date)) > 1000000000000
            THEN CAST(MAX(cmj.message_date) / 1000000000 AS INTEGER)
            ELSE MAX(cmj.message_date) END AS last_apple_seconds
        FROM handle h LEFT JOIN chat_handle_join chj ON chj.handle_id = h.ROWID
        LEFT JOIN chat_message_join cmj ON cmj.chat_id = chj.chat_id
        WHERE h.id IS NOT NULL GROUP BY h.ROWID ORDER BY MAX(cmj.message_date) DESC
        """)
        var people: [JSONValue] = []
        for row in rows {
            guard let identifier = row["identifier"]?.string else { continue }
            if !needle.isEmpty && !contacts.matches(identifier, query: needle) { continue }
            guard case .object(var person) = personForIdentifier(identifier) else { continue }
            person["conversation_count"] = .number(Double(row["conversation_count"]?.int ?? 0))
            person["last_message_at"] = appleISO(row["last_apple_seconds"]?.double).map(JSONValue.string) ?? .null
            people.append(.object(person))
            if people.count == safeLimit { break }
        }
        return .array(people)
    }

    func indexableConversations() throws -> [IndexableConversation] {
        let database = try openDatabase()
        return try database.query("""
        SELECT c.ROWID AS chat_id, c.display_name, COUNT(DISTINCT m.ROWID) AS message_count
        FROM chat c JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
        JOIN message m ON m.ROWID = cmj.message_id WHERE m.item_type = 0
        GROUP BY c.ROWID HAVING message_count > 0 ORDER BY c.ROWID
        """).compactMap { row in
            guard let chatID = row["chat_id"]?.int else { return nil }
            let participants = try? participantsForChat(chatID, database: database)
            return .init(
                conversationID: conversationID(chatID),
                name: safeConversationName(row["display_name"]?.string, participants: participants ?? []),
                personIDs: (participants ?? []).compactMap { $0["person_id"]?.stringValue },
                messageCount: row["message_count"]?.int ?? 0
            )
        }
    }

    func indexableMessages(conversationID publicID: String, afterMessageID: Int, limit requestedLimit: Int = 512) throws -> IndexableMessagePage {
        let chatID = try resolveConversationID(publicID)
        let limit = clamp(requestedLimit, minimum: 1, maximum: 1_000, fallback: 512)
        let rows = try openDatabase().query("""
        SELECT m.ROWID AS message_id, m.text, m.attributedBody AS attributed_body, m.subject,
          m.is_from_me, m.service, m.reply_to_guid, h.id AS sender,
          CASE WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER) ELSE m.date END AS apple_seconds,
          '[]' AS attachments_json
        FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE cmj.chat_id = ? AND m.item_type = 0 AND m.ROWID > ?
        ORDER BY m.ROWID LIMIT ?
        """, bindings: [.integer(Int64(chatID)), .integer(Int64(max(0, afterMessageID))), .integer(Int64(limit))])
        return .init(
            messages: rows.map(cleanMessage),
            scannedThroughMessageID: rows.last?["message_id"]?.int ?? afterMessageID,
            hasMore: rows.count == limit
        )
    }

    func readConversation(_ arguments: JSONValue) throws -> JSONValue {
        guard let publicID = arguments["conversation_id"]?.stringValue else {
            throw IMessageError.invalid("conversation_id is required")
        }
        let chatID = try resolveConversationID(publicID)
        let limit = clamp(arguments["limit"]?.intValue, minimum: 1, maximum: 10_000, fallback: 100)
        let before = arguments["before_message_id"]?.intValue
        let since = try appleSeconds(arguments["since"]?.stringValue, label: "since")
        let until = try appleSeconds(arguments["until"]?.stringValue, label: "until")
        let database = try openDatabase()
        guard let chat = try database.query(
            "SELECT ROWID AS chat_id, display_name AS name, service_name AS service FROM chat WHERE ROWID = ?",
            bindings: [.integer(Int64(chatID))]
        ).first else { throw IMessageError.invalid("Unknown conversation_id") }
        let rows = try database.query("""
        SELECT m.ROWID AS message_id, m.text, m.attributedBody AS attributed_body,
          m.subject, m.is_from_me, m.service, m.reply_to_guid, h.id AS sender,
          CASE WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER)
               ELSE m.date END AS apple_seconds,
          (SELECT json_group_array(json_object('filename', a.filename, 'mime_type', a.mime_type,
                    'transfer_name', a.transfer_name))
             FROM message_attachment_join maj JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id = m.ROWID) AS attachments_json
        FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE cmj.chat_id = ? AND (? IS NULL OR m.ROWID < ?)
          AND (? IS NULL OR (CASE WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER) ELSE m.date END) >= ?)
          AND (? IS NULL OR (CASE WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER) ELSE m.date END) < ?)
        ORDER BY m.date DESC, m.ROWID DESC LIMIT ?
        """, bindings: [
            .integer(Int64(chatID)), optionalInteger(before), optionalInteger(before),
            optionalReal(since), optionalReal(since), optionalReal(until), optionalReal(until),
            .integer(Int64(limit)),
        ])
        let participants = try participantsForChat(chatID, database: database)
        let messages = rows.reversed().map(cleanMessage)
        let cursor = rows.count == limit ? rows.compactMap { $0["message_id"]?.int }.min() : nil
        return .object([
            "conversation": .object([
                "conversation_id": .string(publicID),
                "name": .string(safeConversationName(chat["name"]?.string, participants: participants)),
                "participants": .array(participants),
                "service": chat["service"]?.string.map(JSONValue.string) ?? .null,
            ]),
            "messages": .array(messages),
            "next_before_message_id": cursor.map { .number(Double($0)) } ?? .null,
        ])
    }

    func searchMessages(_ arguments: JSONValue) throws -> JSONValue {
        guard let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else { throw IMessageError.invalid("query is required") }
        guard query.count <= 500 else { throw IMessageError.invalid("query must be 500 characters or fewer") }
        let chatID = try arguments["conversation_id"]?.stringValue.map(resolveConversationID)
        let personIDs = arguments["person_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let handleIDs = try resolvePersonIDs(personIDs)
        let requireAll = arguments["person_match"]?.stringValue == "all"
        let requiredCount = requireAll ? handleIDs.count : min(handleIDs.count, 1)
        let limit = clamp(arguments["limit"]?.intValue, minimum: 1, maximum: 5_000, fallback: 50)
        let since = try appleSeconds(arguments["since"]?.stringValue, label: "since")
        let until = try appleSeconds(arguments["until"]?.stringValue, label: "until")
        let fromMe = arguments["direction"]?.stringValue == "from_me" ? 1
            : arguments["direction"]?.stringValue == "to_me" ? 0 : nil
        let handlesJSON = String(data: try JSONEncoder().encode(handleIDs), encoding: .utf8) ?? "[]"
        let database = try openDatabase()
        let rows = try database.query("""
        SELECT m.ROWID AS message_id, m.text, m.attributedBody AS attributed_body,
          m.subject, m.is_from_me, m.service, m.reply_to_guid, h.id AS sender,
          c.ROWID AS chat_id, c.display_name AS chat_name,
          CASE WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER) ELSE m.date END AS apple_seconds,
          '[]' AS attachments_json
        FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON c.ROWID = cmj.chat_id LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE (? IS NULL OR c.ROWID = ?)
          AND (? = 0 OR (SELECT COUNT(DISTINCT p.handle_id) FROM chat_handle_join p
             WHERE p.chat_id = c.ROWID AND p.handle_id IN (SELECT value FROM json_each(?))) >= ?)
          AND (? IS NULL OR (CASE WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER) ELSE m.date END) >= ?)
          AND (? IS NULL OR (CASE WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER) ELSE m.date END) < ?)
          AND (? IS NULL OR m.is_from_me = ?)
          AND (m.text LIKE ? COLLATE NOCASE OR instr(m.attributedBody, ?) > 0)
        ORDER BY m.date DESC, m.ROWID DESC LIMIT ?
        """, bindings: [
            optionalInteger(chatID), optionalInteger(chatID), .integer(Int64(requiredCount)), .text(handlesJSON),
            .integer(Int64(requiredCount)), optionalReal(since), optionalReal(since), optionalReal(until), optionalReal(until),
            optionalInteger(fromMe), optionalInteger(fromMe), .text("%\(query)%"), .blob(Data(query.utf8)), .integer(Int64(limit)),
        ])
        return .array(try rows.map { row in
            var value = cleanMessage(row).objectValue ?? [:]
            let rowChatID = row["chat_id"]?.int ?? 0
            let participants = try participantsForChat(rowChatID, database: database)
            value["conversation_id"] = .string(conversationID(rowChatID))
            value["conversation_name"] = .string(safeConversationName(row["chat_name"]?.string, participants: participants))
            return .object(value)
        })
    }

    func conversationStats(_ arguments: JSONValue = .object([:])) throws -> JSONValue {
        let chatID = try arguments["conversation_id"]?.stringValue.map(resolveConversationID)
        let since = try appleSeconds(arguments["since"]?.stringValue, label: "since")
        let until = try appleSeconds(arguments["until"]?.stringValue, label: "until")
        let database = try openDatabase()
        let date = "CASE WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER) ELSE m.date END"
        let filter = "(? IS NULL OR cmj.chat_id = ?) AND (? IS NULL OR \(date) >= ?) AND (? IS NULL OR \(date) < ?) AND m.item_type = 0"
        let bindings = [optionalInteger(chatID), optionalInteger(chatID), optionalReal(since), optionalReal(since), optionalReal(until), optionalReal(until)]
        let totals = try database.query("""
        SELECT COUNT(DISTINCT m.ROWID) AS messages,
          SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS from_me,
          SUM(CASE WHEN m.is_from_me = 0 THEN 1 ELSE 0 END) AS to_me,
          MIN(\(date)) AS first_apple_seconds, MAX(\(date)) AS last_apple_seconds,
          COUNT(DISTINCT cmj.chat_id) AS conversations
        FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID WHERE \(filter)
        """, bindings: bindings).first ?? [:]
        let years = try database.query("""
        SELECT strftime('%Y', \(date) + \(Int(appleEpochSeconds)), 'unixepoch') AS year,
          COUNT(DISTINCT m.ROWID) AS messages,
          SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS from_me,
          SUM(CASE WHEN m.is_from_me = 0 THEN 1 ELSE 0 END) AS to_me
        FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID WHERE \(filter)
        GROUP BY year ORDER BY year
        """, bindings: bindings)
        let totalObject: [String: JSONValue] = [
            "messages": .number(Double(totals["messages"]?.int ?? 0)),
            "from_me": .number(Double(totals["from_me"]?.int ?? 0)),
            "to_me": .number(Double(totals["to_me"]?.int ?? 0)),
            "conversations": .number(Double(totals["conversations"]?.int ?? 0)),
            "first_message_at": appleISO(totals["first_apple_seconds"]?.double).map(JSONValue.string) ?? .null,
            "last_message_at": appleISO(totals["last_apple_seconds"]?.double).map(JSONValue.string) ?? .null,
        ]
        return .object([
            "scope": chatID == nil ? .object(["all_conversations": .bool(true)]) : .object(["conversation_id": arguments["conversation_id"] ?? .null]),
            "period": .object(["since": arguments["since"] ?? .null, "until": arguments["until"] ?? .null]),
            "totals": .object(totalObject),
            "by_year": .array(years.map { row in .object([
                "year": row["year"]?.string.map(JSONValue.string) ?? .null,
                "messages": .number(Double(row["messages"]?.int ?? 0)),
                "from_me": .number(Double(row["from_me"]?.int ?? 0)),
                "to_me": .number(Double(row["to_me"]?.int ?? 0)),
            ]) }),
        ])
    }

    func sampleConversation(_ arguments: JSONValue) throws -> JSONValue {
        guard let publicID = arguments["conversation_id"]?.stringValue else { throw IMessageError.invalid("conversation_id is required") }
        let chatID = try resolveConversationID(publicID)
        let limit = clamp(arguments["limit"]?.intValue, minimum: 5, maximum: 2_500, fallback: 60)
        let since = try appleSeconds(arguments["since"]?.stringValue, label: "since")
        let until = try appleSeconds(arguments["until"]?.stringValue, label: "until")
        let database = try openDatabase()
        let rows = try database.query("""
        WITH eligible AS (
          SELECT m.ROWID AS message_id, m.text, m.attributedBody AS attributed_body, m.subject,
            m.is_from_me, m.service, m.reply_to_guid, h.id AS sender,
            CASE WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER) ELSE m.date END AS apple_seconds,
            ROW_NUMBER() OVER (ORDER BY m.date, m.ROWID) AS row_number, COUNT(*) OVER () AS total_rows,
            '[]' AS attachments_json
          FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
          LEFT JOIN handle h ON h.ROWID = m.handle_id WHERE cmj.chat_id = ? AND m.item_type = 0
            AND (? IS NULL OR (CASE WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER) ELSE m.date END) >= ?)
            AND (? IS NULL OR (CASE WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER) ELSE m.date END) < ?)
        ) SELECT * FROM eligible WHERE total_rows <= ? OR (row_number - 1) % MAX(1, CAST(total_rows / ? AS INTEGER)) = 0
        ORDER BY row_number LIMIT ?
        """, bindings: [
            .integer(Int64(chatID)), optionalReal(since), optionalReal(since), optionalReal(until), optionalReal(until),
            .integer(Int64(limit)), .integer(Int64(limit)), .integer(Int64(limit)),
        ])
        return .object([
            "conversation_id": .string(publicID),
            "sampling": .string("evenly spaced across the requested period; not a random or complete sample"),
            "period": .object(["since": arguments["since"] ?? .null, "until": arguments["until"] ?? .null]),
            "messages": .array(rows.map(cleanMessage)),
        ])
    }

    private func openDatabase() throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: databasePath, readOnly: true)
        try database.executeScript("PRAGMA query_only = ON")
        return database
    }

    private func opaqueID(_ namespace: String, _ value: String) -> String {
        let digest = HMAC<SHA256>.authenticationCode(for: Data("\(namespace):\(value)".utf8), using: identityKey)
        let encoded = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(namespace)_\(encoded.prefix(18))"
    }

    private func conversationID(_ id: Int) -> String { opaqueID("conv", String(id)) }
    private func personID(_ identifier: String) -> String { opaqueID("person", identifier) }

    private func refreshIdentityIndex() throws {
        let database = try openDatabase()
        var conversations: [String: Int] = [:]
        for row in try database.query("SELECT ROWID AS chat_id FROM chat") {
            if let id = row["chat_id"]?.int { conversations[conversationID(id)] = id }
        }
        var people: [String: Int] = [:]
        for row in try database.query("SELECT ROWID AS handle_id, id FROM handle WHERE id IS NOT NULL") {
            if let id = row["handle_id"]?.int, let identifier = row["id"]?.string { people[personID(identifier)] = id }
        }
        identityLock.withLock {
            conversationByPublicID = conversations
            personByPublicID = people
        }
    }

    private func resolveConversationID(_ publicID: String) throws -> Int {
        if let id = identityLock.withLock({ conversationByPublicID[publicID] }) { return id }
        try refreshIdentityIndex()
        guard let id = identityLock.withLock({ conversationByPublicID[publicID] }) else { throw IMessageError.invalid("Unknown conversation_id") }
        return id
    }

    private func resolvePersonIDs(_ publicIDs: [String]) throws -> [Int] {
        if publicIDs.isEmpty { return [] }
        try refreshIdentityIndex()
        return try Array(Set(publicIDs.map { publicID in
            guard let id = identityLock.withLock({ personByPublicID[publicID] }) else { throw IMessageError.invalid("Unknown person_id") }
            return id
        }))
    }

    private func participantsForChat(_ chatID: Int, database: SQLiteDatabase) throws -> [JSONValue] {
        try database.query("""
        SELECT h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id
        WHERE chj.chat_id = ? ORDER BY h.ROWID
        """, bindings: [.integer(Int64(chatID))]).compactMap { $0["id"]?.string }.map(personForIdentifier)
    }

    private func personForIdentifier(_ identifier: String) -> JSONValue {
        guard !identifier.isEmpty else { return .object(["person_id": .string("unknown"), "name": .string("Unknown person")]) }
        let profile = contacts.profile(for: identifier)
        let name = safeContactValue(profile?.name) ?? "Unknown person"
        var value: [String: JSONValue] = ["person_id": .string(personID(identifier)), "name": .string(name)]
        for (key, candidate) in [("nickname", profile?.nickname), ("company", profile?.company), ("job_title", profile?.jobTitle), ("department", profile?.department)] {
            if let safe = safeContactValue(candidate), !(key == "nickname" && safe == name) { value[key] = .string(safe) }
        }
        return .object(value)
    }

    private func safeContactValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let redacted = PrivacyRedaction.redact(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return redacted.isEmpty || redacted.contains("[redacted:") ? nil : redacted
    }

    private func safeConversationName(_ displayName: String?, participants: [JSONValue]) -> String {
        if let displayName, let safe = safeContactValue(displayName) { return safe }
        let names = participants.compactMap { $0["name"]?.stringValue }.filter { $0 != "Unknown person" }
        return names.isEmpty ? "Unnamed conversation" : names.joined(separator: ", ")
    }

    private func cleanMessage(_ row: [String: SQLiteValue]) -> JSONValue {
        let rawText = row["text"]?.string ?? AttributedBodyDecoder.decode(row["attributed_body"]?.data)
        let isFromMe = (row["is_from_me"]?.int ?? 0) != 0
        var attachments: [JSONValue] = []
        if let raw = row["attachments_json"]?.string, let data = raw.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(JSONValue.self, from: data), case .array(let items) = parsed {
            attachments = items.map { item in .object([
                "name": PrivacyRedaction.privateAttachmentName(item["transfer_name"]?.stringValue ?? item["filename"]?.stringValue).map(JSONValue.string) ?? .null,
                "mime_type": item["mime_type"]?.stringValue.map(JSONValue.string) ?? .null,
            ]) }
        }
        return .object([
            "message_id": .number(Double(row["message_id"]?.int ?? 0)),
            "sent_at": appleISO(row["apple_seconds"]?.double).map(JSONValue.string) ?? .null,
            "direction": .string(isFromMe ? "from_me" : "to_me"),
            "sender": isFromMe ? .object(["person_id": .string("me"), "name": .string("You")])
                : personForIdentifier(row["sender"]?.string ?? ""),
            "service": row["service"]?.string.map(JSONValue.string) ?? .null,
            "text": rawText.map { .string(PrivacyRedaction.redact($0)) } ?? .null,
            "subject": row["subject"]?.string.map { .string(PrivacyRedaction.redact($0)) } ?? .null,
            "is_reply": .bool(row["reply_to_guid"]?.string != nil),
            "attachments": .array(attachments),
        ])
    }

    private func contactsMatch(_ identifiers: [String], query: String) -> Bool {
        identifiers.contains { contacts.matches($0, query: query) }
    }
}

enum IMessageError: Error, LocalizedError {
    case fullDiskAccess
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .fullDiskAccess: return "Atlas needs Full Disk Access to read the Messages database"
        case .invalid(let message): return message
        }
    }
}


private func clamp(_ value: Int?, minimum: Int, maximum: Int, fallback: Int) -> Int {
    min(maximum, max(minimum, value ?? fallback))
}

private func optionalInteger(_ value: Int?) -> SQLiteValue { value.map { .integer(Int64($0)) } ?? .null }
private func optionalReal(_ value: Double?) -> SQLiteValue { value.map(SQLiteValue.real) ?? .null }

private func appleISO(_ value: Double?) -> String? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date(timeIntervalSince1970: value + appleEpochSeconds))
}

private func appleSeconds(_ value: String?, label: String) throws -> Double? {
    guard let value, !value.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: value) ?? ISO8601DateFormatter.atlasFallback.date(from: value) else {
        throw IMessageError.invalid("\(label) must be an ISO-8601 date")
    }
    return date.timeIntervalSince1970 - appleEpochSeconds
}

private extension ISO8601DateFormatter {
    static var atlasFallback: ISO8601DateFormatter {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }
}
