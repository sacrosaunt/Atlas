import Foundation
import CryptoKit

private let semanticModelBytes: Int64 = 639_150_592
private let semanticModelSHA = "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439"
private let semanticModelURL = URL(string: "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/main/Qwen3-Embedding-0.6B-Q8_0.gguf")!

actor SemanticIndex {
    private let store: IMessageStore
    private let directory: URL
    private let databaseURL: URL
    private let modelURL: URL
    private let partialModelURL: URL
    private let settingsURL: URL
    private var database: SQLiteDatabase?
    private var foregroundActive = false
    private var enabled: Bool
    private var phase: String
    private var textPhase = "pending"
    private var textError: String?
    private var error: String?
    private var indexedMessages = 0
    private var totalMessages = 0
    private var indexedDocuments = 0
    private var embeddedDocuments = 0
    private var totalDocuments = 0
    private var downloadedBytes: Int64 = 0
    private var workTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var embeddingEngine: EmbeddingEngine?
    private var embeddingLoadCancellation: EmbeddingCancellation?
    private var embeddingRate = 0.0
    private var embeddingStartedAt: Date?
    private var publishedETA: Double?
    private var etaPublishedAt: Date?
    private var sleepAssertion: Process?
    private var textReadyCallback: (@Sendable () async -> Void)?

    init(store: IMessageStore, directory: URL) {
        self.store = store
        self.directory = directory
        databaseURL = directory.appending(path: "search.sqlite")
        modelURL = directory.appending(path: "semantic-search.gguf")
        partialModelURL = directory.appending(path: "semantic-search.gguf.part")
        settingsURL = directory.appending(path: "settings.json")
        enabled = Self.readEnabled(settingsURL)
        let installed = Self.fileSize(modelURL) == semanticModelBytes
        phase = enabled && installed ? "preparing" : "off"
        downloadedBytes = Self.fileSize(partialModelURL)
    }

    func setTextReadyCallback(_ callback: @escaping @Sendable () async -> Void) { textReadyCallback = callback }

    func setForegroundActive(_ active: Bool) {
        foregroundActive = active
        if active { startIndexing() }
        else {
            workTask?.cancel()
            workTask = nil
            embeddingLoadCancellation?.cancel()
            embeddingEngine?.cancelActiveWork()
            stopSleepAssertion()
            if textPhase == "indexing" { textPhase = "paused" }
            if enabled && isModelInstalled && ["preparing", "embedding"].contains(phase) { phase = "paused" }
        }
    }

    func status() -> JSONValue {
        refreshCounts()
        let indexBytes = Self.fileSize(databaseURL) + Self.fileSize(URL(fileURLWithPath: databaseURL.path + "-wal"))
            + Self.fileSize(URL(fileURLWithPath: databaseURL.path + "-shm"))
        return .object([
            "enabled": .bool(enabled), "installed": .bool(isModelInstalled), "phase": .string(phase),
            "text_index_phase": .string(textPhase), "text_index_error": textError.map(JSONValue.string) ?? .null,
            "pause_reason": (!foregroundActive && (phase == "paused" || textPhase == "paused")) ? .string("app_not_active") : .null,
            "downloaded_bytes": .number(Double(phase == "downloading" ? downloadedBytes : (isModelInstalled ? semanticModelBytes : Self.fileSize(partialModelURL)))),
            "total_download_bytes": .number(Double(semanticModelBytes)),
            "indexed_messages": .number(Double(indexedMessages)), "total_messages": .number(Double(totalMessages)),
            "indexed_documents": .number(Double(indexedDocuments)), "embedded_documents": .number(Double(embeddedDocuments)),
            "total_documents": .number(Double(totalDocuments)), "eta_seconds": currentETA.map(JSONValue.number) ?? .null,
            "preventing_sleep": .bool(sleepAssertion != nil), "index_bytes": .number(Double(indexBytes)),
            "error": error.map(JSONValue.string) ?? .null,
        ])
    }

    func enable() -> JSONValue {
        enabled = true; error = nil; saveSettings()
        if isModelInstalled { phase = foregroundActive ? "preparing" : "paused"; if foregroundActive { startIndexing() } }
        else { startDownload() }
        return status()
    }

    func disable() -> JSONValue {
        enabled = false; saveSettings(); downloadTask?.cancel(); phase = "off"; error = nil
        stopSleepAssertion()
        return status()
    }

    func remove() throws -> JSONValue {
        _ = disable()
        for path in [modelURL, partialModelURL] { try? FileManager.default.removeItem(at: path) }
        if let database = try? openDatabase() { try database.execute("UPDATE documents SET embedding = NULL") }
        embeddingEngine = nil; downloadedBytes = 0; embeddedDocuments = 0
        return status()
    }

    func textIndexReady() -> Bool { textPhase == "ready" }

    func searchMessages(_ arguments: JSONValue) throws -> JSONValue? {
        guard textPhase == "ready", FileManager.default.fileExists(atPath: databaseURL.path),
              let query = arguments["query"]?.stringValue, let fts = literalFTS(query) else { return nil }
        var clauses = ["messages_fts MATCH ?"]
        var bindings: [SQLiteValue] = [.text(fts)]
        if let conversation = arguments["conversation_id"]?.stringValue { clauses.append("m.conversation_id = ?"); bindings.append(.text(conversation)) }
        if let since = arguments["since"]?.stringValue { clauses.append("m.sent_at >= ?"); bindings.append(.text(since)) }
        if let until = arguments["until"]?.stringValue { clauses.append("m.sent_at < ?"); bindings.append(.text(until)) }
        if let direction = arguments["direction"]?.stringValue { clauses.append("m.direction = ?"); bindings.append(.text(direction)) }
        let people = Array(Set(arguments["person_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])).prefix(25)
        if !people.isEmpty {
            if arguments["person_match"]?.stringValue == "all" {
                for person in people { clauses.append("EXISTS (SELECT 1 FROM json_each(m.person_ids) WHERE value = ?)"); bindings.append(.text(person)) }
            } else {
                clauses.append("EXISTS (SELECT 1 FROM json_each(m.person_ids) WHERE value IN (\(people.map { _ in "?" }.joined(separator: ","))))")
                bindings += people.map(SQLiteValue.text)
            }
        }
        let limit = min(5_000, max(1, arguments["limit"]?.intValue ?? 50))
        bindings.append(.integer(Int64(limit)))
        let rows = try openDatabase().query("""
        SELECT m.*, c.name AS conversation_name FROM messages_fts
        JOIN messages m ON m.id = messages_fts.rowid JOIN conversations c ON c.conversation_id = m.conversation_id
        WHERE \(clauses.joined(separator: " AND ")) ORDER BY m.sent_at DESC, m.message_id DESC LIMIT ?
        """, bindings: bindings)
        return .array(rows.map(publicMessage))
    }

    func searchContext(_ arguments: JSONValue) async throws -> JSONValue {
        guard enabled else { throw SemanticError.unavailable("Enhanced local search is turned off in Atlas settings") }
        guard isModelInstalled else { throw SemanticError.unavailable("Enhanced local search has not finished downloading") }
        refreshCounts()
        guard indexedDocuments > 0 else { throw SemanticError.unavailable("Enhanced local search is still preparing the message history") }
        guard let query = arguments["query"]?.stringValue, !query.isEmpty else { throw SemanticError.unavailable("query is required") }
        let limit = min(200, max(1, arguments["limit"]?.intValue ?? 30))
        let filters = documentFilters(arguments)
        let database = try openDatabase()
        var ranked: [Int: (row: [String: SQLiteValue], semantic: Double, lexicalRank: Int?)] = [:]
        if embeddedDocuments > 0 {
            let engine = try await loadEmbeddingEngine()
            let vector = try await Task.detached { try engine.embedding(for: query, query: true) }.value
            let queryValues = vector.floats
            for row in try database.query("""
            SELECT d.*, c.name AS conversation_name FROM documents d
            JOIN conversations c ON c.conversation_id = d.conversation_id
            WHERE d.embedding IS NOT NULL \(filters.sql.isEmpty ? "" : "AND \(filters.sql)")
            """, bindings: filters.bindings) {
                guard let id = row["id"]?.int, let embedding = row["embedding"]?.data else { continue }
                let similarity = cosine(queryValues, embedding.floats)
                ranked[id] = (row, similarity, nil)
            }
            let top = ranked.sorted { $0.value.semantic > $1.value.semantic }.prefix(min(800, limit * 5))
            ranked = Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value) })
        }
        if let fts = broadFTS(query) {
            let lexical = try database.query("""
            SELECT d.*, c.name AS conversation_name, bm25(documents_fts) AS lexical_score
            FROM documents_fts JOIN documents d ON d.id = documents_fts.rowid
            JOIN conversations c ON c.conversation_id = d.conversation_id
            WHERE documents_fts MATCH ? \(filters.sql.isEmpty ? "" : "AND \(filters.sql)")
            ORDER BY lexical_score LIMIT ?
            """, bindings: [.text(fts)] + filters.bindings + [.integer(Int64(min(800, limit * 5)))])
            for (rank, row) in lexical.enumerated() {
                guard let id = row["id"]?.int else { continue }
                let current = ranked[id] ?? (row, 0, nil)
                ranked[id] = (current.row, current.semantic, rank)
            }
        }
        let values = ranked.values.sorted { left, right in
            let leftScore = (left.semantic > 0 ? 1.0 / 61.0 + left.semantic * 0.001 : 0) + (left.lexicalRank.map { 1.0 / Double(61 + $0) } ?? 0)
            let rightScore = (right.semantic > 0 ? 1.0 / 61.0 + right.semantic * 0.001 : 0) + (right.lexicalRank.map { 1.0 / Double(61 + $0) } ?? 0)
            return leftScore > rightScore
        }.prefix(limit)
        let latestUnembedded = try database.query("SELECT MAX(end_at) AS latest FROM documents WHERE embedding IS NULL").first?["latest"]?.string
        return .object([
            "query": .string(query), "indexed_messages": .number(Double(indexedMessages)),
            "embedded_passages": .number(Double(embeddedDocuments)),
            "semantic_coverage_percent": .number(totalDocuments > 0 ? Double(embeddedDocuments) * 100 / Double(totalDocuments) : 0),
            "semantic_fully_covered_after": latestUnembedded.map(JSONValue.string) ?? .null,
            "text_index_complete": .bool(textPhase == "ready"), "semantic_index_complete": .bool(phase == "ready"),
            "passages": .array(values.map { publicDocument($0.row, relevance: max(0, min(1, $0.semantic)), match: $0.semantic > 0 && $0.lexicalRank != nil ? "hybrid" : $0.semantic > 0 ? "semantic" : "keyword") }),
        ])
    }

    private func startIndexing() {
        guard foregroundActive, workTask == nil else { return }
        workTask = Task { [weak self] in
            guard let self else { return }
            await self.buildIndex()
        }
    }

    private func buildIndex() async {
        defer { workTask = nil }
        do {
            try Task.checkCancellation()
            textPhase = "indexing"; textError = nil
            let database = try openDatabase()
            let conversations = try store.indexableConversations()
            totalMessages = conversations.reduce(0) { $0 + $1.messageCount }
            for conversation in conversations {
                try Task.checkCancellation()
                try database.execute("""
                INSERT INTO conversations(conversation_id,name,person_ids,message_count) VALUES(?,?,?,?)
                ON CONFLICT(conversation_id) DO UPDATE SET name=excluded.name,person_ids=excluded.person_ids,message_count=excluded.message_count
                """, bindings: [.text(conversation.conversationID), .text(conversation.name), .text(jsonString(conversation.personIDs)), .integer(Int64(conversation.messageCount))])
                let stored = try database.query("SELECT last_message_id FROM conversations WHERE conversation_id=?", bindings: [.text(conversation.conversationID)]).first
                var cursor = stored?["last_message_id"]?.int ?? 0
                while true {
                    try Task.checkCancellation()
                    let page = try store.indexableMessages(conversationID: conversation.conversationID, afterMessageID: cursor)
                    guard !page.messages.isEmpty else { break }
                    try database.executeScript("BEGIN IMMEDIATE")
                    do {
                        for message in page.messages {
                            let content = [message["subject"]?.stringValue, message["text"]?.stringValue].compactMap { $0 }.joined(separator: " — ").trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !content.isEmpty else { continue }
                            let sender = jsonString(message["sender"] ?? .object([:]))
                            try database.execute("""
                            INSERT OR IGNORE INTO messages(conversation_id,message_id,sent_at,direction,sender_json,service,subject,text,is_reply,person_ids)
                            VALUES(?,?,?,?,?,?,?,?,?,?)
                            """, bindings: [
                                .text(conversation.conversationID), .integer(Int64(message["message_id"]?.intValue ?? 0)), optionalText(message["sent_at"]?.stringValue),
                                .text(message["direction"]?.stringValue ?? "to_me"), .text(sender), optionalText(message["service"]?.stringValue),
                                optionalText(message["subject"]?.stringValue), optionalText(message["text"]?.stringValue), .integer(message["is_reply"]?.boolValue == true ? 1 : 0),
                                .text(jsonString(conversation.personIDs)),
                            ])
                            if database.changes > 0 { try database.execute("INSERT INTO messages_fts(rowid,content) VALUES(?,?)", bindings: [.integer(database.lastInsertRowID), .text(content)]) }
                        }
                        for offset in stride(from: 0, to: page.messages.count, by: 6) {
                            let group = Array(page.messages[offset..<min(page.messages.count, offset + 8)])
                            let text = formatDocument(group)
                            guard !text.isEmpty else { continue }
                            try database.execute("""
                            INSERT OR IGNORE INTO documents(conversation_id,start_message_id,end_message_id,start_at,end_at,person_ids,directions,text,message_count)
                            VALUES(?,?,?,?,?,?,?,?,?)
                            """, bindings: [
                                .text(conversation.conversationID), .integer(Int64(group.first?["message_id"]?.intValue ?? 0)), .integer(Int64(group.last?["message_id"]?.intValue ?? 0)),
                                optionalText(group.first?["sent_at"]?.stringValue), optionalText(group.last?["sent_at"]?.stringValue), .text(jsonString(conversation.personIDs)),
                                .text(jsonString(Array(Set(group.compactMap { $0["direction"]?.stringValue })))), .text(text), .integer(Int64(group.count)),
                            ])
                            if database.changes > 0 { try database.execute("INSERT INTO documents_fts(rowid,text) VALUES(?,?)", bindings: [.integer(database.lastInsertRowID), .text(text)]) }
                        }
                        try database.execute("UPDATE conversations SET last_message_id=?,indexed_messages=indexed_messages+? WHERE conversation_id=?", bindings: [.integer(Int64(page.scannedThroughMessageID)), .integer(Int64(page.messages.count)), .text(conversation.conversationID)])
                        try database.executeScript("COMMIT")
                    } catch { try? database.executeScript("ROLLBACK"); throw error }
                    cursor = page.scannedThroughMessageID
                    refreshCounts()
                    await Task.yield()
                    if !page.hasMore { break }
                }
            }
            textPhase = "ready"
            await textReadyCallback?()
            try Task.checkCancellation()
            if enabled && isModelInstalled { try await embedPending() }
            else if phase != "downloading" { phase = "off" }
        } catch is CancellationError {
            if textPhase == "indexing" { textPhase = "paused" }
            if enabled && isModelInstalled { phase = "paused" }
            stopSleepAssertion()
        } catch {
            textPhase = "error"; textError = error.localizedDescription; self.error = error.localizedDescription
            stopSleepAssertion()
        }
    }

    private func openDatabase() throws -> SQLiteDatabase {
        if let database { return database }
        let database = try SQLiteDatabase(path: databaseURL.path)
        try database.executeScript("""
        PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS conversations(conversation_id TEXT PRIMARY KEY,name TEXT NOT NULL,person_ids TEXT NOT NULL,message_count INTEGER NOT NULL DEFAULT 0,last_message_id INTEGER NOT NULL DEFAULT 0,indexed_messages INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS documents(id INTEGER PRIMARY KEY,conversation_id TEXT NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,start_message_id INTEGER NOT NULL,end_message_id INTEGER NOT NULL,start_at TEXT,end_at TEXT,person_ids TEXT NOT NULL,directions TEXT NOT NULL,text TEXT NOT NULL,message_count INTEGER NOT NULL,embedding BLOB CHECK(embedding IS NULL OR vec_length(embedding)=384),UNIQUE(conversation_id,start_message_id,end_message_id));
        CREATE INDEX IF NOT EXISTS documents_conversation ON documents(conversation_id); CREATE INDEX IF NOT EXISTS documents_dates ON documents(start_at,end_at); CREATE INDEX IF NOT EXISTS documents_pending_embeddings_newest ON documents(end_at DESC,id DESC) WHERE embedding IS NULL;
        CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(text,tokenize='unicode61 remove_diacritics 2');
        CREATE TABLE IF NOT EXISTS messages(id INTEGER PRIMARY KEY,conversation_id TEXT NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,message_id INTEGER NOT NULL,sent_at TEXT,direction TEXT NOT NULL,sender_json TEXT NOT NULL,service TEXT,subject TEXT,text TEXT,is_reply INTEGER NOT NULL DEFAULT 0,person_ids TEXT NOT NULL,UNIQUE(conversation_id,message_id));
        CREATE INDEX IF NOT EXISTS messages_conversation_date ON messages(conversation_id,sent_at DESC); CREATE INDEX IF NOT EXISTS messages_date ON messages(sent_at DESC);
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(content,tokenize='unicode61 remove_diacritics 2');
        INSERT OR REPLACE INTO metadata(key,value) VALUES('schema_version','3');
        INSERT OR REPLACE INTO metadata(key,value) VALUES('vector_dimensions','384');
        INSERT OR REPLACE INTO metadata(key,value) VALUES('model_sha256','\(semanticModelSHA)');
        INSERT OR REPLACE INTO metadata(key,value) VALUES('embedding_order','reverse_chronological_v1');
        """)
        self.database = database
        return database
    }

    private func refreshCounts() {
        guard let database = try? openDatabase() else { return }
        indexedMessages = (try? database.scalar("SELECT COALESCE(SUM(indexed_messages),0) FROM conversations")?.int) ?? 0
        indexedDocuments = (try? database.scalar("SELECT COUNT(*) FROM documents")?.int) ?? 0
        embeddedDocuments = (try? database.scalar("SELECT COUNT(*) FROM documents WHERE embedding IS NOT NULL")?.int) ?? 0
        totalDocuments = indexedDocuments
        totalMessages = (try? store.info().messages) ?? totalMessages
        if textPhase == "pending" || textPhase == "paused" {
            if indexedMessages >= totalMessages && totalMessages > 0 { textPhase = "ready" }
        }
        if enabled && isModelInstalled && totalDocuments > 0 && embeddedDocuments >= totalDocuments { phase = "ready" }
    }

    private var isModelInstalled: Bool { Self.fileSize(modelURL) == semanticModelBytes }
    private var currentETA: Double? {
        guard phase == "embedding", embeddingRate > 0, let started = embeddingStartedAt, Date().timeIntervalSince(started) >= 120 else { return nil }
        if publishedETA == nil || etaPublishedAt.map({ Date().timeIntervalSince($0) >= 60 }) == true {
            publishedETA = max(0, Double(totalDocuments - embeddedDocuments) / embeddingRate); etaPublishedAt = Date()
        }
        return publishedETA
    }

    private func startDownload() {
        guard downloadTask == nil else { return }
        phase = "downloading"; downloadedBytes = 0; error = nil
        downloadTask = Task { [weak self] in
            guard let self else { return }
            await self.downloadModel()
        }
    }

    private func downloadModel() async {
        defer { downloadTask = nil }
        do {
            try? FileManager.default.removeItem(at: partialModelURL)
            let delegate = AtlasDownloadDelegate { [weak self] bytes in Task { await self?.setDownloadedBytes(bytes) } }
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            let temporary = try await delegate.download(using: session, from: semanticModelURL)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: temporary, to: partialModelURL)
            guard Self.fileSize(partialModelURL) == semanticModelBytes else { throw SemanticError.unavailable("The downloaded search component had an unexpected size") }
            guard try sha256(partialModelURL) == semanticModelSHA else { throw SemanticError.unavailable("The downloaded search component could not be verified") }
            try FileManager.default.moveItem(at: partialModelURL, to: modelURL)
            phase = foregroundActive ? "preparing" : "paused"
            if foregroundActive { startIndexing() }
        } catch is CancellationError { phase = enabled ? "off" : "off" }
        catch { phase = "error"; self.error = error.localizedDescription }
    }

    private func setDownloadedBytes(_ value: Int64) { downloadedBytes = value }

    private func loadEmbeddingEngine() async throws -> EmbeddingEngine {
        if let embeddingEngine { return embeddingEngine }
        let path = modelURL
        let cancellation = EmbeddingCancellation()
        embeddingLoadCancellation = cancellation
        let engine = try await Task.detached { try EmbeddingEngine(modelPath: path, cancellation: cancellation) }.value
        embeddingLoadCancellation = nil
        try Task.checkCancellation()
        guard foregroundActive else { engine.cancelActiveWork(); throw CancellationError() }
        embeddingEngine = engine
        return engine
    }

    private func embedPending() async throws {
        phase = "embedding"; embeddingStartedAt = Date(); embeddingRate = 0; publishedETA = nil; etaPublishedAt = nil
        startSleepAssertion()
        let database = try openDatabase(), engine = try await loadEmbeddingEngine()
        while foregroundActive && enabled {
            try Task.checkCancellation()
            if powerStateShouldPauseEmbedding() { phase = "paused"; stopSleepAssertion(); try await Task.sleep(for: .seconds(2)); continue }
            phase = "embedding"; startSleepAssertion()
            let rows = try database.query("SELECT id,text FROM documents WHERE embedding IS NULL ORDER BY end_at DESC,id DESC LIMIT 64")
            if rows.isEmpty { break }
            for row in rows {
                try Task.checkCancellation()
                guard let id = row["id"]?.int, let text = row["text"]?.string else { continue }
                let started = ContinuousClock.now
                let embedding = try await Task.detached { try engine.embedding(for: text) }.value
                try database.execute("UPDATE documents SET embedding=? WHERE id=?", bindings: [.blob(embedding), .integer(Int64(id))])
                embeddedDocuments += 1
                let seconds = max(0.001, Double(started.duration(to: .now).components.attoseconds) / 1e18 + Double(started.duration(to: .now).components.seconds))
                let rate = 1 / seconds; embeddingRate = embeddingRate > 0 ? embeddingRate * 0.85 + rate * 0.15 : rate
                await Task.yield()
            }
        }
        if !foregroundActive || !enabled { throw CancellationError() }
        phase = "ready"; stopSleepAssertion()
    }

    private func startSleepAssertion() {
        guard sleepAssertion == nil, !powerStateShouldPauseEmbedding() else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate"); process.arguments = ["-i", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run(); if process.isRunning { sleepAssertion = process }
    }

    private func stopSleepAssertion() { if let process = sleepAssertion, process.isRunning { process.terminate() }; sleepAssertion = nil }

    private func saveSettings() {
        let value: JSONValue = .object(["enabled": .bool(enabled)])
        if let data = try? JSONEncoder().encode(value) { try? AtlasSecurity.writePrivate(data, to: settingsURL) }
    }

    private static func readEnabled(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return false }
        return value["enabled"]?.boolValue == true
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}

private struct DocumentFilters { let sql: String; let bindings: [SQLiteValue] }

private extension SemanticIndex {
    func documentFilters(_ arguments: JSONValue) -> DocumentFilters {
        var clauses: [String] = [], values: [SQLiteValue] = []
        if let conversation = arguments["conversation_id"]?.stringValue { clauses.append("d.conversation_id=?"); values.append(.text(conversation)) }
        if let since = arguments["since"]?.stringValue { clauses.append("d.end_at>=?"); values.append(.text(since)) }
        if let until = arguments["until"]?.stringValue { clauses.append("d.start_at<?"); values.append(.text(until)) }
        if let direction = arguments["direction"]?.stringValue { clauses.append("EXISTS(SELECT 1 FROM json_each(d.directions) WHERE value=?)"); values.append(.text(direction)) }
        let people = Array(Set(arguments["person_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])).prefix(25)
        if arguments["person_match"]?.stringValue == "all" {
            for person in people { clauses.append("EXISTS(SELECT 1 FROM json_each(d.person_ids) WHERE value=?)"); values.append(.text(person)) }
        } else if !people.isEmpty {
            clauses.append("EXISTS(SELECT 1 FROM json_each(d.person_ids) WHERE value IN (\(people.map { _ in "?" }.joined(separator: ","))))")
            values += people.map(SQLiteValue.text)
        }
        return .init(sql: clauses.joined(separator: " AND "), bindings: values)
    }
}

private final class AtlasDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }
    func download(using session: URLSession, from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            session.downloadTask(with: url).resume()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { progress(totalBytesWritten) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do { try FileManager.default.moveItem(at: location, to: destination); lock.withLock { continuation }.map { $0.resume(returning: destination) } }
        catch { lock.withLock { continuation }.map { $0.resume(throwing: error) } }
        lock.withLock { continuation = nil }; session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let value = lock.withLock { let value = continuation; continuation = nil; return value }
        value?.resume(throwing: error)
    }
}

private enum SemanticError: Error, LocalizedError { case unavailable(String); var errorDescription: String? { if case .unavailable(let value) = self { return value }; return nil } }

private func optionalText(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
private func jsonString<T: Encodable>(_ value: T) -> String { (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "null" }
private func formatDocument(_ messages: [JSONValue]) -> String {
    String(messages.compactMap { message -> String? in
        let body = [message["subject"]?.stringValue, message["text"]?.stringValue].compactMap { $0 }.joined(separator: " — ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let author = message["direction"]?.stringValue == "from_me" ? "You" : message["sender"]?["name"]?.stringValue ?? "Contact"
        return "\(message["sent_at"]?.stringValue ?? "Unknown date") · \(author): \(body)"
    }.joined(separator: "\n").prefix(24_000))
}

private func ftsTokens(_ query: String) -> [String] {
    let pattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]{2,}"#)
    let range = NSRange(query.startIndex..<query.endIndex, in: query.precomposedStringWithCompatibilityMapping)
    return Array(Set(pattern.matches(in: query.precomposedStringWithCompatibilityMapping, range: range).compactMap { Range($0.range, in: query.precomposedStringWithCompatibilityMapping).map { String(query.precomposedStringWithCompatibilityMapping[$0]).replacingOccurrences(of: "\"", with: "\"\"") } })).prefix(32).map { $0 }
}
private func literalFTS(_ query: String) -> String? { let tokens = ftsTokens(query); return tokens.isEmpty ? nil : tokens.map { "\"\($0)\"*" }.joined(separator: " AND ") }
private func broadFTS(_ query: String) -> String? { let tokens = ftsTokens(query); return tokens.isEmpty ? nil : tokens.map { "\"\($0)\"*" }.joined(separator: " OR ") }

private func publicMessage(_ row: [String: SQLiteValue]) -> JSONValue {
    let sender: JSONValue = row["sender_json"]?.string.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } ?? .object(["person_id": .string("unknown"), "name": .string("Unknown")])
    return .object([
        "conversation_id": row["conversation_id"]?.string.map(JSONValue.string) ?? .null,
        "conversation_name": row["conversation_name"]?.string.map(JSONValue.string) ?? .null,
        "message_id": .number(Double(row["message_id"]?.int ?? 0)), "sent_at": row["sent_at"]?.string.map(JSONValue.string) ?? .null,
        "direction": row["direction"]?.string.map(JSONValue.string) ?? .null, "sender": sender,
        "service": row["service"]?.string.map(JSONValue.string) ?? .null, "text": row["text"]?.string.map(JSONValue.string) ?? .null,
        "subject": row["subject"]?.string.map(JSONValue.string) ?? .null, "is_reply": .bool((row["is_reply"]?.int ?? 0) != 0), "attachments": .array([]),
    ])
}

private func publicDocument(_ row: [String: SQLiteValue], relevance: Double, match: String) -> JSONValue {
    let people = row["person_ids"]?.string.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } ?? .array([])
    let directions = row["directions"]?.string.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } ?? .array([])
    return .object([
        "passage_id": .string("passage_\(row["id"]?.int ?? 0)"), "conversation_id": row["conversation_id"]?.string.map(JSONValue.string) ?? .null,
        "conversation_name": row["conversation_name"]?.string.map(JSONValue.string) ?? .null,
        "start_at": row["start_at"]?.string.map(JSONValue.string) ?? .null, "end_at": row["end_at"]?.string.map(JSONValue.string) ?? .null,
        "message_count": .number(Double(row["message_count"]?.int ?? 0)), "person_ids": people, "directions": directions,
        "text": row["text"]?.string.map(JSONValue.string) ?? .null, "relevance": .number(relevance), "match": .string(match),
    ])
}

private extension Data { var floats: [Float] { withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } } }
private func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
    let count = min(lhs.count, rhs.count); guard count > 0 else { return 0 }
    var dot: Double = 0, left: Double = 0, right: Double = 0
    for index in 0..<count { let a = Double(lhs[index]), b = Double(rhs[index]); dot += a*b; left += a*a; right += b*b }
    return dot / max(1e-12, sqrt(left * right))
}

private func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    var hash = SHA256()
    while true { let data = try handle.read(upToCount: 1_048_576) ?? Data(); if data.isEmpty { break }; hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

private func powerStateShouldPauseEmbedding() -> Bool {
    let process = Process(); let output = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); process.arguments = ["-g", "batt"]; process.standardOutput = output; process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }; process.waitUntilExit()
    return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.localizedCaseInsensitiveContains("Battery Power") == true
}
