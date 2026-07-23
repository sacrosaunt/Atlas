import CoreML
import CONNXRuntime
import CryptoKit
import Foundation

private struct ToneModelFile: Sendable {
    let path: String
    let bytes: Int64
    let sha256: String
}

private let toneRevision = "f3ec4d0925f90c3ca7ee7814f52d6ee7cf180445"
private let toneFiles = [
    ToneModelFile(path: "onnx/model_quantized.onnx", bytes: 125_905_426, sha256: "046f7e4cc46b399558fa9b2de966f6b0d42c69e4b01f582bfb4099b01a0bb5d7"),
    ToneModelFile(path: "merges.txt", bytes: 456_318, sha256: "1ce1664773c50f3e0cc8842619a93edc4624525b728b188a9e0be33b7726adc5"),
    ToneModelFile(path: "vocab.json", bytes: 798_293, sha256: "ed19656ea1707df69134c4af35c8ceda2cc9860bf2c3495026153a133670ab5e"),
]
private let disposableToneMetadata = ["config.json", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"]
private let toneDownloadBytes = toneFiles.reduce(Int64(0)) { $0 + $1.bytes }

actor ToneIndex {
    private let databaseURL: URL
    private let directory: URL
    private let modelDirectory: URL
    private let coreMLPackage: URL
    private let coreMLCompiledModel: URL
    private let coreMLSetupProgress: URL
    private let coreMLSetupScript: URL
    private let markerURL: URL
    private let settingsURL: URL
    private var database: SQLiteDatabase?
    private var enabled: Bool
    private var foregroundActive = false
    private var textIndexReady = false
    private var phase: String
    private var error: String?
    private var downloadedBytes: Int64 = 0
    private var totalTurns = 0
    private var analyzedTurns = 0
    private var totalWindows = 0
    private var analyzedWindows = 0
    private var completedOnce = false
    private var runBaseline = 0
    private var runTotal = 0
    private var rate = 0.0
    private var startedAt: Date?
    private var publishedETA: Double?
    private var etaPublishedAt: Date?
    private var task: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var coreMLPreparation: CoreMLPreparationProcess?
    private var coreMLPreparationID: UUID?
    private var classifier: NativeToneClassifier?
    private var inferenceBackend: String?
    private var sleepAssertion: Process?

    init(databaseURL: URL, directory: URL) {
        self.databaseURL = databaseURL
        self.directory = directory
        modelDirectory = directory.appending(path: "model", directoryHint: .isDirectory)
        coreMLPackage = directory.appending(path: "coreml/ToneClassifier.mlpackage")
        coreMLCompiledModel = directory.appending(path: "coreml/ToneClassifier.mlmodelc")
        coreMLSetupProgress = directory.appending(path: "coreml/setup-progress.json")
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let bundledSetup = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/CoreMLSetup/prepare-tone-coreml.sh")
        let developmentSetup = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "scripts/prepare-tone-coreml.sh")
        coreMLSetupScript = FileManager.default.isExecutableFile(atPath: bundledSetup.path)
            ? bundledSetup
            : developmentSetup
        markerURL = directory.appending(path: "model/verified.json")
        settingsURL = directory.appending(path: "settings.json")
        enabled = Self.readEnabled(directory.appending(path: "settings.json"))
        phase = enabled ? "starting" : "off"
        inferenceBackend = FileManager.default.fileExists(atPath: coreMLCompiledModel.path)
            || FileManager.default.fileExists(atPath: coreMLPackage.path) ? "coreml" : nil
        if Self.compiledModelIsValid(coreMLCompiledModel) {
            Self.removeDisposableCoreMLArtifacts(package: coreMLPackage)
        }
        for filename in disposableToneMetadata {
            try? FileManager.default.removeItem(at: modelDirectory.appending(path: filename))
        }
        try? FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func setTextIndexReady(_ ready: Bool) {
        textIndexReady = ready
        scheduleIfPossible()
    }

    func setForegroundActive(_ active: Bool) {
        foregroundActive = active
        if active {
            startCoreMLPreparationIfNeeded()
            scheduleIfPossible()
        }
        else {
            task?.cancel(); task = nil; stopSleepAssertion()
            coreMLPreparation?.terminate(); coreMLPreparation = nil; coreMLPreparationID = nil
            if enabled && isInstalled && !["ready", "downloading", "off", "error"].contains(phase) { phase = "waiting_for_app" }
        }
    }

    func status() -> JSONValue {
        refreshCounts()
        let progress = analysisProgress
        let coreMLProgress = (try? Data(contentsOf: coreMLSetupProgress))
            .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        return .object([
            "enabled": .bool(enabled), "installed": .bool(isInstalled), "phase": .string(phase),
            "pause_reason": phase == "waiting_for_app" ? .string("app_not_active") : .null,
            "preventing_sleep": .bool(sleepAssertion != nil),
            "downloaded_bytes": .number(Double(phase == "downloading" ? downloadedBytes : installedBytes)),
            "total_download_bytes": .number(Double(toneDownloadBytes)),
            "analyzed_turns": .number(Double(analyzedTurns)), "total_turns": .number(Double(totalTurns)),
            "analyzed_windows": .number(Double(analyzedWindows)), "total_windows": .number(Double(totalWindows)),
            "progress_completed_units": .number(Double(progress.completed)), "progress_total_units": .number(Double(progress.total)),
            "eta_seconds": currentETA.map(JSONValue.number) ?? .null,
            "inference_backend": inferenceBackend.map(JSONValue.string) ?? .null,
            "coreml_setup": coreMLProgress ?? .null,
            "model_revision": .string(toneRevision), "error": error.map(JSONValue.string) ?? .null,
        ])
    }

    func enable() -> JSONValue {
        enabled = true; error = nil; saveSettings()
        if foregroundActive { startCoreMLPreparationIfNeeded() }
        if modelFilesInstalled { scheduleIfPossible() } else { startDownload() }
        return status()
    }

    func summary(_ arguments: JSONValue) throws -> JSONValue {
        let database = try openDatabase(); try ensureSchema(database)
        let bucket = arguments["bucket"]?.stringValue ?? "month"
        var conditions = ["t.positive IS NOT NULL"], windowConditions = ["w.positive IS NOT NULL"]
        var bindings: [SQLiteValue] = [], windowBindings: [SQLiteValue] = []
        func add(_ turn: String, _ window: String, _ value: SQLiteValue) {
            conditions.append(turn); windowConditions.append(window); bindings.append(value); windowBindings.append(value)
        }
        if let value = arguments["conversation_id"]?.stringValue { add("t.conversation_id=?", "w.conversation_id=?", .text(value)) }
        if let value = arguments["since"]?.stringValue { add("t.start_at>=?", "w.start_at>=?", .text(value)) }
        if let value = arguments["until"]?.stringValue { add("t.start_at<?", "w.start_at<?", .text(value)) }
        let people = Array(Set(arguments["person_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])).prefix(25)
        if arguments["person_match"]?.stringValue == "all" {
            for person in people { add("EXISTS(SELECT 1 FROM json_each(c.person_ids) WHERE value=?)", "EXISTS(SELECT 1 FROM json_each(c.person_ids) WHERE value=?)", .text(person)) }
        } else if !people.isEmpty {
            let marks = people.map { _ in "?" }.joined(separator: ",")
            conditions.append("EXISTS(SELECT 1 FROM json_each(c.person_ids) WHERE value IN (\(marks)))")
            windowConditions.append("EXISTS(SELECT 1 FROM json_each(c.person_ids) WHERE value IN (\(marks)))")
            bindings += people.map(SQLiteValue.text); windowBindings += people.map(SQLiteValue.text)
        }
        let overall = try database.query("SELECT \(aggregateSQL("t")) FROM sentiment_turns t JOIN conversations c ON c.conversation_id=t.conversation_id WHERE \(conditions.joined(separator: " AND "))", bindings: bindings).first ?? [:]
        let directions = try database.query("SELECT t.direction,\(aggregateSQL("t")) FROM sentiment_turns t JOIN conversations c ON c.conversation_id=t.conversation_id WHERE \(conditions.joined(separator: " AND ")) GROUP BY t.direction", bindings: bindings)
        let windows = try database.query("SELECT \(aggregateSQL("w")) FROM sentiment_windows w JOIN conversations c ON c.conversation_id=w.conversation_id WHERE \(windowConditions.joined(separator: " AND "))", bindings: windowBindings).first ?? [:]
        let period: String
        if bucket == "year" { period = "substr(t.start_at,1,4)" }
        else if bucket == "quarter" { period = "substr(t.start_at,1,4)||'-Q'||CAST(((CAST(substr(t.start_at,6,2) AS INTEGER)-1)/3+1) AS INTEGER)" }
        else { period = "substr(t.start_at,1,7)" }
        let timelineRows = try database.query("SELECT \(period) AS period,\(aggregateSQL("t")) FROM sentiment_turns t JOIN conversations c ON c.conversation_id=t.conversation_id WHERE \(conditions.joined(separator: " AND ")) GROUP BY period ORDER BY period", bindings: bindings)
        refreshCounts()
        let analyzed = analyzedTurns + analyzedWindows, total = totalTurns + totalWindows
        return .object([
            "status": .string(phase), "model": .string("local three-way sentiment classifier"),
            "measurement_notes": .array([
                .string("Turn tone measures coherent same-speaker utterances assembled from adjacent message bubbles."),
                .string("Window tone measures short multi-speaker exchanges and is not attributed to one person."),
                .string("Sentiment describes textual tone, not emotion, intent, sarcasm, or personality."),
            ]),
            "coverage_percent": .number(total > 0 ? rounded(Double(analyzed) * 100 / Double(total)) : 0),
            "turn_tone": .object([
                "overall": publicAggregate(overall),
                "by_direction": .object(Dictionary(uniqueKeysWithValues: directions.compactMap { row in row["direction"]?.string.map { ($0, publicAggregate(row)) } })),
            ]),
            "window_tone": publicAggregate(windows),
            "timeline": .array(timelineRows.map { row in
                var value = publicAggregateObject(row); value["period"] = row["period"]?.string.map(JSONValue.string) ?? .null; return .object(value)
            }),
        ])
    }

    func trends() throws -> JSONValue {
        let calendar = Calendar(identifier: .gregorian), now = Date()
        let components = calendar.dateComponents([.year, .month], from: now)
        let recent = calendar.date(from: DateComponents(year: components.year, month: (components.month ?? 1) - 11, day: 1)) ?? now
        let formatter = ISO8601DateFormatter()
        let yearly = try summary(.object(["bucket": .string("year")]))
        let monthly = try summary(.object(["bucket": .string("month"), "since": .string(formatter.string(from: recent))]))
        let year = String(components.year ?? 0), month = String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
        return .object([
            "status": yearly["status"] ?? .string(phase), "coverage_percent": yearly["coverage_percent"] ?? .number(0),
            "yearly": chartPoints(yearly["timeline"]?.arrayValue ?? [], current: year),
            "recent": chartPoints(monthly["timeline"]?.arrayValue ?? [], current: month),
        ])
    }

    private func chartPoints(_ values: [JSONValue], current: String) -> JSONValue {
        .array(values.map { value in .object([
            "period": value["period"] ?? .null, "count": value["count"] ?? .number(0),
            "positive": value["dominant_share"]?["positive"] ?? .number(0),
            "neutral": value["dominant_share"]?["neutral"] ?? .number(0),
            "negative": value["dominant_share"]?["negative"] ?? .number(0),
            "net": value["average"]?["valence"] ?? .number(0),
            "partial": .bool(value["period"]?.stringValue == current),
        ]) })
    }

    private func scheduleIfPossible() {
        guard enabled else { phase = "off"; return }
        guard modelFilesInstalled else { phase = downloadTask == nil ? "not_downloaded" : "downloading"; return }
        guard coreMLPreparation == nil else { phase = "preparing"; return }
        guard foregroundActive else { phase = "waiting_for_app"; return }
        guard textIndexReady else { phase = "waiting_for_index"; return }
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.analyze()
        }
    }

    private func startCoreMLPreparationIfNeeded() {
        guard enabled,
              coreMLPreparation == nil,
              !FileManager.default.fileExists(atPath: coreMLCompiledModel.path),
              FileManager.default.isExecutableFile(atPath: coreMLSetupScript.path) else { return }
        let preparation = CoreMLPreparationProcess()
        let preparationID = UUID()
        coreMLPreparation = preparation
        coreMLPreparationID = preparationID
        do {
            try preparation.start(script: coreMLSetupScript) { [weak self] status in
                Task { await self?.coreMLPreparationFinished(id: preparationID, status: status) }
            }
        } catch {
            coreMLPreparation = nil
            coreMLPreparationID = nil
            self.error = "Core ML setup could not start: \(error.localizedDescription)"
        }
    }

    private func coreMLPreparationFinished(id: UUID, status: Int32) {
        guard coreMLPreparationID == id else { return }
        coreMLPreparation = nil
        coreMLPreparationID = nil
        if status == 0,
           FileManager.default.fileExists(atPath: coreMLCompiledModel.path)
            || FileManager.default.fileExists(atPath: coreMLPackage.path) {
            inferenceBackend = "coreml"
            task?.cancel()
            task = nil
        }
        scheduleIfPossible()
    }

    private func analyze() async {
        defer { task = nil; classifier = nil; stopSleepAssertion() }
        do {
            phase = "preparing"; error = nil
            let database = try openDatabase()
            refreshCounts()
            try materialize(database)
            beginProgressRun()
            phase = "analyzing"; startedAt = Date(); rate = 0; publishedETA = nil; etaPublishedAt = nil
            startSleepAssertion()
            let classifier = try NativeToneClassifier(
                modelPackage: coreMLPackage,
                compiledModel: coreMLCompiledModel,
                onnxModel: modelDirectory.appending(path: "onnx/model_quantized.onnx"),
                modelDirectory: modelDirectory
            )
            self.classifier = classifier
            inferenceBackend = classifier.backendName
            while foregroundActive && enabled {
                try Task.checkCancellation()
                if ProcessInfo.processInfo.isLowPowerModeEnabled { phase = "paused"; stopSleepAssertion(); try await Task.sleep(for: .seconds(15)); continue }
                phase = "analyzing"; startSleepAssertion()
                let rows = try database.query("SELECT kind,id,text FROM (SELECT 'turn' kind,id,text,end_at FROM sentiment_turns WHERE positive IS NULL UNION ALL SELECT 'window' kind,id,text,end_at FROM sentiment_windows WHERE positive IS NULL) ORDER BY end_at DESC,id DESC LIMIT 80")
                if rows.isEmpty { break }
                let ordered = rows.sorted { ($0["text"]?.string?.count ?? 0) < ($1["text"]?.string?.count ?? 0) }
                for offset in stride(from: 0, to: ordered.count, by: 8) {
                    try Task.checkCancellation(); guard foregroundActive else { throw CancellationError() }
                    let batch = Array(ordered[offset..<min(ordered.count, offset + 8)])
                    let start = Date(), scores = try classifier.classify(batch.compactMap { $0["text"]?.string })
                    try database.executeScript("BEGIN IMMEDIATE")
                    do {
                        for (index, row) in batch.enumerated() {
                            guard index < scores.count, let id = row["id"]?.int else { continue }
                            let score = scores[index], table = row["kind"]?.string == "turn" ? "sentiment_turns" : "sentiment_windows"
                            try database.execute("UPDATE \(table) SET negative=?,neutral=?,positive=?,valence=?,confidence=? WHERE id=?", bindings: [.real(score.negative), .real(score.neutral), .real(score.positive), .real(score.positive-score.negative), .real(max(score.negative,score.neutral,score.positive)), .integer(Int64(id))])
                        }
                        try database.executeScript("COMMIT")
                    } catch { try? database.executeScript("ROLLBACK"); throw error }
                    let seconds = max(0.001, Date().timeIntervalSince(start)), instant = Double(batch.count) / seconds
                    rate = rate > 0 ? rate * 0.85 + instant * 0.15 : instant
                    refreshCounts(); await Task.yield()
                }
            }
            guard foregroundActive && enabled else { throw CancellationError() }
            phase = "ready"; refreshCounts(); markCompleted(database)
        } catch is CancellationError {
            phase = enabled ? "waiting_for_app" : "off"
        } catch {
            phase = "error"; self.error = error.localizedDescription
        }
    }

    private func materialize(_ database: SQLiteDatabase) throws {
        try ensureSchema(database)
        let conversations = try database.query("SELECT conversation_id,last_message_id FROM conversations")
        for conversation in conversations {
            guard let id = conversation["conversation_id"]?.string else { continue }
            let latest = conversation["last_message_id"]?.int ?? 0
            let stored = try database.scalar("SELECT last_message_id FROM sentiment_conversations WHERE conversation_id=?", bindings: [.text(id)])?.int ?? -1
            guard latest > stored else { continue }
            let messages = try database.query("SELECT conversation_id,message_id,sent_at,direction,sender_json,subject,text FROM messages WHERE conversation_id=? ORDER BY message_id", bindings: [.text(id)])
            let turns = buildTurns(messages), windows = buildWindows(turns)
            try database.executeScript("BEGIN IMMEDIATE")
            do {
                try database.execute("DELETE FROM sentiment_windows WHERE conversation_id=?", bindings: [.text(id)])
                try database.execute("DELETE FROM sentiment_turns WHERE conversation_id=?", bindings: [.text(id)])
                for turn in turns { try insertTurn(turn, database) }
                for window in windows { try insertWindow(window, database) }
                try database.execute("INSERT INTO sentiment_conversations(conversation_id,last_message_id) VALUES(?,?) ON CONFLICT(conversation_id) DO UPDATE SET last_message_id=excluded.last_message_id", bindings: [.text(id), .integer(Int64(latest))])
                try database.executeScript("COMMIT")
            } catch { try? database.executeScript("ROLLBACK"); throw error }
        }
        refreshCounts()
    }

    private func ensureSchema(_ database: SQLiteDatabase) throws {
        try database.executeScript("""
        CREATE TABLE IF NOT EXISTS sentiment_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS sentiment_conversations(conversation_id TEXT PRIMARY KEY,last_message_id INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS sentiment_turns(id INTEGER PRIMARY KEY,conversation_id TEXT NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,start_message_id INTEGER NOT NULL,end_message_id INTEGER NOT NULL,start_at TEXT,end_at TEXT,direction TEXT NOT NULL,speaker_key TEXT NOT NULL,message_count INTEGER NOT NULL,text TEXT NOT NULL,negative REAL,neutral REAL,positive REAL,valence REAL,confidence REAL,UNIQUE(conversation_id,start_message_id,end_message_id));
        CREATE INDEX IF NOT EXISTS sentiment_turns_dates ON sentiment_turns(start_at,end_at); CREATE INDEX IF NOT EXISTS sentiment_turns_pending ON sentiment_turns(end_at DESC,id DESC) WHERE positive IS NULL;
        CREATE TABLE IF NOT EXISTS sentiment_windows(id INTEGER PRIMARY KEY,conversation_id TEXT NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,start_message_id INTEGER NOT NULL,end_message_id INTEGER NOT NULL,start_at TEXT,end_at TEXT,turn_count INTEGER NOT NULL,directions TEXT NOT NULL,text TEXT NOT NULL,negative REAL,neutral REAL,positive REAL,valence REAL,confidence REAL,UNIQUE(conversation_id,start_message_id,end_message_id));
        CREATE INDEX IF NOT EXISTS sentiment_windows_dates ON sentiment_windows(start_at,end_at); CREATE INDEX IF NOT EXISTS sentiment_windows_pending ON sentiment_windows(end_at DESC,id DESC) WHERE positive IS NULL;
        INSERT OR REPLACE INTO sentiment_metadata(key,value) VALUES('model_version','cardiff-twitter-roberta-coreml-fp16:3216a57f2a0d9c45a2e6c20157c20c49fb4bf9c7:safe-mask-v1');
        INSERT OR IGNORE INTO sentiment_metadata(key,value) VALUES('completed_once','0');
        """)
    }

    private func openDatabase() throws -> SQLiteDatabase {
        if let database { return database }
        let value = try SQLiteDatabase(path: databaseURL.path); database = value; return value
    }

    private func refreshCounts() {
        guard let database = try? openDatabase(), (try? ensureSchema(database)) != nil else { return }
        totalTurns = (try? database.scalar("SELECT COUNT(*) FROM sentiment_turns")?.int) ?? 0
        analyzedTurns = (try? database.scalar("SELECT COUNT(*) FROM sentiment_turns WHERE positive IS NOT NULL")?.int) ?? 0
        totalWindows = (try? database.scalar("SELECT COUNT(*) FROM sentiment_windows")?.int) ?? 0
        analyzedWindows = (try? database.scalar("SELECT COUNT(*) FROM sentiment_windows WHERE positive IS NOT NULL")?.int) ?? 0
        completedOnce = (try? database.scalar("SELECT value FROM sentiment_metadata WHERE key='completed_once'")?.string) == "1"
        if totalTurns + totalWindows > 0 && analyzedTurns + analyzedWindows >= totalTurns + totalWindows { phase = "ready" }
        if !completedOnce && totalTurns + totalWindows > 0 && analyzedTurns + analyzedWindows >= totalTurns + totalWindows {
            markCompleted(database)
        }
    }

    private var analysisProgress: (completed: Int, total: Int) {
        let analyzed = analyzedTurns + analyzedWindows
        let total = totalTurns + totalWindows
        guard completedOnce else { return (min(analyzed, total), total) }
        return (min(max(0, analyzed - runBaseline), runTotal), runTotal)
    }

    private func beginProgressRun() {
        let analyzed = analyzedTurns + analyzedWindows
        let total = totalTurns + totalWindows
        runBaseline = completedOnce ? analyzed : 0
        runTotal = completedOnce ? max(0, total - analyzed) : total
    }

    private func markCompleted(_ database: SQLiteDatabase) {
        let analyzed = analyzedTurns + analyzedWindows
        let total = totalTurns + totalWindows
        guard total > 0, analyzed >= total else { return }
        completedOnce = true
        try? database.execute("UPDATE sentiment_metadata SET value='1' WHERE key='completed_once'")
    }

    private var currentETA: Double? {
        guard phase == "analyzing", rate > 0, let startedAt, Date().timeIntervalSince(startedAt) >= 30 else { return nil }
        if publishedETA == nil || etaPublishedAt.map({ Date().timeIntervalSince($0) >= 60 }) == true {
            publishedETA = max(0, Double(totalTurns + totalWindows - analyzedTurns - analyzedWindows) / rate); etaPublishedAt = Date()
        }
        return publishedETA
    }

    private var installedBytes: Int64 { toneFiles.reduce(0) { $0 + min($1.bytes, fileSize(modelDirectory.appending(path: $1.path))) } }
    private var modelFilesInstalled: Bool { FileManager.default.fileExists(atPath: markerURL.path) && toneFiles.allSatisfy { fileSize(modelDirectory.appending(path: $0.path)) == $0.bytes } }
    private var isInstalled: Bool { modelFilesInstalled }

    private func startDownload() {
        guard downloadTask == nil else { return }
        phase = "downloading"; downloadedBytes = 0
        downloadTask = Task { [weak self] in guard let self else { return }; await self.download() }
    }

    private func download() async {
        var temporaryDownload: URL?
        defer { downloadTask = nil }
        do {
            try? FileManager.default.removeItem(at: markerURL)
            for file in toneFiles {
                try Task.checkCancellation()
                let destination = modelDirectory.appending(path: file.path), partial = URL(fileURLWithPath: destination.path + ".part")
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try? FileManager.default.removeItem(at: partial)
                if fileSize(destination) == file.bytes, (try? hash(destination)) == file.sha256 {
                    downloadedBytes += file.bytes
                    continue
                }
                try? FileManager.default.removeItem(at: destination)
                let before = downloadedBytes
                let delegate = ToneDownloadDelegate { [weak self] bytes in Task { await self?.setDownloadProgress(before + bytes) } }
                let source = URL(string: "https://huggingface.co/Xenova/twitter-roberta-base-sentiment-latest/resolve/\(toneRevision)/\(file.path)")!
                let temporary = try await delegate.download(from: source)
                temporaryDownload = temporary
                try FileManager.default.moveItem(at: temporary, to: partial)
                temporaryDownload = nil
                guard fileSize(partial) == file.bytes, try hash(partial) == file.sha256 else { throw ToneError.invalidDownload }
                try FileManager.default.moveItem(at: partial, to: destination); downloadedBytes = before + file.bytes
            }
            try AtlasSecurity.writePrivate(Data("{\"revision\":\"\(toneRevision)\"}\n".utf8), to: markerURL)
            scheduleIfPossible()
        } catch is CancellationError {
            cleanupToneDownloadArtifacts(temporaryDownload)
            phase = enabled ? "not_downloaded" : "off"
        } catch {
            cleanupToneDownloadArtifacts(temporaryDownload)
            phase = "error"; self.error = error.localizedDescription
        }
    }

    private func setDownloadProgress(_ value: Int64) { downloadedBytes = value }
    private func cleanupToneDownloadArtifacts(_ temporary: URL?) {
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        for file in toneFiles {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: modelDirectory.appending(path: file.path).path + ".part")
            )
        }
    }

    private static func compiledModelIsValid(_ url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true, (values?.fileSize ?? 0) > 1_024 { return true }
        }
        return false
    }

    private static func removeDisposableCoreMLArtifacts(package: URL) {
        let manager = FileManager.default
        try? manager.removeItem(at: package)
        let cache = manager.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/Atlas/ToneCoreML", directoryHint: .isDirectory)
        try? manager.removeItem(at: cache)
    }
    private func saveSettings() { try? AtlasSecurity.writePrivate(Data("{\"enabled\":\(enabled)}\n".utf8), to: settingsURL) }
    private static func readEnabled(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return true }
        return value["enabled"]?.boolValue != false
    }
    private func startSleepAssertion() {
        guard sleepAssertion == nil, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate"); process.arguments = ["-i", "-w", String(ProcessInfo.processInfo.processIdentifier)]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run(); if process.isRunning { sleepAssertion = process }
    }
    private func stopSleepAssertion() { if let process = sleepAssertion, process.isRunning { process.terminate() }; sleepAssertion = nil }
}

private struct ToneTurn {
    let conversation: String, startID: Int, endID: Int, start: String?, end: String?, direction: String, speaker: String, count: Int, text: String
}
private struct ToneWindow { let conversation: String, startID: Int, endID: Int, start: String?, end: String?, count: Int, directions: String, text: String }

private func buildTurns(_ rows: [[String: SQLiteValue]]) -> [ToneTurn] {
    var result: [ToneTurn] = []
    for row in rows {
        let text = [row["subject"]?.string, row["text"]?.string].compactMap { $0 }.joined(separator: " — ").replacingOccurrences(of: #"https?://\S+|www\.\S+"#, with: "http", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let conversation = row["conversation_id"]?.string, let messageID = row["message_id"]?.int else { continue }
        let direction = row["direction"]?.string ?? "to_me"
        let speaker = direction == "from_me" ? "me" : (row["sender_json"]?.string.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }?["person_id"]?.stringValue ?? "contact")
        let sent = row["sent_at"]?.string
        if let last = result.last, last.speaker == speaker, last.count < 20, last.text.count + text.count + 1 <= 2_000,
           let previous = last.end.flatMap(isoDate), let current = sent.flatMap(isoDate), current.timeIntervalSince(previous) >= 0, current.timeIntervalSince(previous) <= 120 {
            result[result.count - 1] = ToneTurn(conversation: conversation, startID: last.startID, endID: messageID, start: last.start, end: sent, direction: last.direction, speaker: speaker, count: last.count + 1, text: last.text + "\n" + text)
        } else { result.append(.init(conversation: conversation, startID: messageID, endID: messageID, start: sent, end: sent, direction: direction, speaker: speaker, count: 1, text: String(text.prefix(2_000)))) }
    }
    return result
}

private func buildWindows(_ turns: [ToneTurn]) -> [ToneWindow] {
    var result: [ToneWindow] = []
    for offset in stride(from: 0, to: turns.count, by: 4) {
        let group = Array(turns[offset..<min(turns.count, offset + 5)])
        guard group.count >= 3, Set(group.map(\.speaker)).count >= 2, let first = group.first, let last = group.last else { continue }
        let directions = String(data: try! JSONEncoder().encode(Array(Set(group.map(\.direction)))), encoding: .utf8)!
        result.append(.init(conversation: first.conversation, startID: first.startID, endID: last.endID, start: first.start, end: last.end, count: group.count, directions: directions, text: String(group.map(\.text).joined(separator: "\n").prefix(4_000))))
    }
    return result
}

private func insertTurn(_ value: ToneTurn, _ database: SQLiteDatabase) throws {
    try database.execute("INSERT INTO sentiment_turns(conversation_id,start_message_id,end_message_id,start_at,end_at,direction,speaker_key,message_count,text) VALUES(?,?,?,?,?,?,?,?,?)", bindings: [.text(value.conversation),.integer(Int64(value.startID)),.integer(Int64(value.endID)),value.start.map(SQLiteValue.text) ?? .null,value.end.map(SQLiteValue.text) ?? .null,.text(value.direction),.text(value.speaker),.integer(Int64(value.count)),.text(value.text)])
}
private func insertWindow(_ value: ToneWindow, _ database: SQLiteDatabase) throws {
    try database.execute("INSERT INTO sentiment_windows(conversation_id,start_message_id,end_message_id,start_at,end_at,turn_count,directions,text) VALUES(?,?,?,?,?,?,?,?)", bindings: [.text(value.conversation),.integer(Int64(value.startID)),.integer(Int64(value.endID)),value.start.map(SQLiteValue.text) ?? .null,value.end.map(SQLiteValue.text) ?? .null,.integer(Int64(value.count)),.text(value.directions),.text(value.text)])
}

private struct ToneScore { let negative: Double, neutral: Double, positive: Double }

private final class CoreMLPreparationProcess: @unchecked Sendable {
    private let process = Process()

    func start(script: URL, completion: @escaping @Sendable (Int32) -> Void) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in completion(process.terminationStatus) }
        try process.run()
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

private final class NativeToneClassifier {
    private let tokenizer: RobertaTokenizer
    private let backend: ToneInferenceBackend
    let backendName: String

    init(modelPackage: URL, compiledModel: URL, onnxModel: URL, modelDirectory: URL) throws {
        tokenizer = try RobertaTokenizer(vocab: modelDirectory.appending(path: "vocab.json"), merges: modelDirectory.appending(path: "merges.txt"))
        let preference = ProcessInfo.processInfo.environment["ATLAS_TONE_BACKEND"]
        if preference != "onnx", FileManager.default.fileExists(atPath: compiledModel.path) || FileManager.default.fileExists(atPath: modelPackage.path) {
            backend = .coreML(try CoreMLToneInference(modelPackage: modelPackage, compiledModel: compiledModel))
            backendName = "coreml"
        } else {
            backend = .onnx(try ONNXToneInference(model: onnxModel))
            backendName = "onnx"
        }
    }

    func classify(_ texts: [String]) throws -> [ToneScore] {
        let tokenized = texts.map { tokenizer.encode($0, maximum: 512) }
        let length = [32,64,128,256,512].first { $0 >= (tokenized.map(\.count).max() ?? 1) } ?? 512
        var ids = [Int64](repeating: 1, count: texts.count * length)
        var mask = [Int64](repeating: 0, count: texts.count * length)
        for (row, tokens) in tokenized.enumerated() {
            for (column, token) in tokens.prefix(length).enumerated() {
                ids[row * length + column] = Int64(token)
                mask[row * length + column] = 1
            }
        }
        return try backend.classify(ids: &ids, mask: &mask, batch: texts.count, length: length)
    }
}

func verifyToneRuntime(at directory: URL) throws -> JSONValue {
    let modelDirectory = directory.appending(path: "model", directoryHint: .isDirectory)
    let classifier = try NativeToneClassifier(
        modelPackage: directory.appending(path: "coreml/ToneClassifier.mlpackage"),
        compiledModel: directory.appending(path: "coreml/ToneClassifier.mlmodelc"),
        onnxModel: modelDirectory.appending(path: "onnx/model_quantized.onnx"),
        modelDirectory: modelDirectory
    )
    let samples = ["That worked beautifully.", "I am waiting for an update.", "This is deeply frustrating."]
    let scores = try classifier.classify(samples)
    return .object([
        "backend": .string(classifier.backendName),
        "scores": .array(scores.map { .object([
            "negative": .number($0.negative), "neutral": .number($0.neutral), "positive": .number($0.positive),
        ]) }),
    ])
}

private enum ToneInferenceBackend {
    case coreML(CoreMLToneInference)
    case onnx(ONNXToneInference)

    func classify(ids: inout [Int64], mask: inout [Int64], batch: Int, length: Int) throws -> [ToneScore] {
        switch self {
        case .coreML(let model): return try model.classify(ids: ids, mask: mask, batch: batch, length: length)
        case .onnx(let model): return try model.classify(ids: &ids, mask: &mask, batch: batch, length: length)
        }
    }
}

private final class CoreMLToneInference {
    private let compiled: URL
    private var models: [Int: MLModel] = [:]

    init(modelPackage: URL, compiledModel: URL) throws {
        if FileManager.default.fileExists(atPath: compiledModel.path) {
            compiled = compiledModel
        } else {
            compiled = try MLModel.compileModel(at: modelPackage)
        }
    }

    func classify(ids sourceIDs: [Int64], mask sourceMask: [Int64], batch: Int, length: Int) throws -> [ToneScore] {
        let shape = [NSNumber(value: 8), NSNumber(value: length)]
        let ids = try MLMultiArray(shape: shape, dataType: .int32), mask = try MLMultiArray(shape: shape, dataType: .int32)
        for index in 0..<(8 * length) { ids[index] = 1; mask[index] = 0 }
        for index in sourceIDs.indices { ids[index] = NSNumber(value: sourceIDs[index]); mask[index] = NSNumber(value: sourceMask[index]) }
        let configuration = MLModelConfiguration(); configuration.computeUnits = .all; configuration.functionName = "tone_b8_s\(length)"
        let model: MLModel
        if let existing = models[length] { model = existing } else { model = try MLModel(contentsOf: compiled, configuration: configuration); models[length] = model }
        let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": MLFeatureValue(multiArray: ids), "attention_mask": MLFeatureValue(multiArray: mask)])
        guard let logits = try model.prediction(from: input).featureValue(for: "logits")?.multiArrayValue else { throw ToneError.invalidOutput }
        return (0..<batch).map { row in
            let values = (0..<3).map { logits[row*3+$0].doubleValue }, maximum = values.max() ?? 0
            return toneScore(values, maximum: maximum)
        }
    }
}

private final class ONNXToneInference {
    private let api: UnsafePointer<OrtApi>
    private var environment: OpaquePointer?
    private var sessionOptions: OpaquePointer?
    private var session: OpaquePointer?
    private var memoryInfo: OpaquePointer?

    init(model: URL) throws {
        guard FileManager.default.fileExists(atPath: model.path),
              let base = OrtGetApiBase(),
              let loadedAPI = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
            throw ToneError.missingRuntime
        }
        api = loadedAPI
        try check(api.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "AtlasTone", &environment))
        try check(api.pointee.CreateSessionOptions(&sessionOptions))
        try check(api.pointee.SetIntraOpNumThreads(sessionOptions, 2))
        try check(api.pointee.SetSessionGraphOptimizationLevel(sessionOptions, ORT_ENABLE_ALL))
        try model.path.withCString { path in
            try check(api.pointee.CreateSession(environment, path, sessionOptions, &session))
        }
        try check(api.pointee.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memoryInfo))
    }

    deinit {
        if let memoryInfo { api.pointee.ReleaseMemoryInfo(memoryInfo) }
        if let session { api.pointee.ReleaseSession(session) }
        if let sessionOptions { api.pointee.ReleaseSessionOptions(sessionOptions) }
        if let environment { api.pointee.ReleaseEnv(environment) }
    }

    func classify(ids: inout [Int64], mask: inout [Int64], batch: Int, length: Int) throws -> [ToneScore] {
        let shape = [Int64(batch), Int64(length)]
        var idTensor: OpaquePointer?
        var maskTensor: OpaquePointer?
        defer {
            if let idTensor { api.pointee.ReleaseValue(idTensor) }
            if let maskTensor { api.pointee.ReleaseValue(maskTensor) }
        }

        try shape.withUnsafeBufferPointer { shapeBuffer in
            try ids.withUnsafeMutableBytes { buffer in
                try check(api.pointee.CreateTensorWithDataAsOrtValue(
                    memoryInfo, buffer.baseAddress, buffer.count, shapeBuffer.baseAddress, shape.count,
                    ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &idTensor
                ))
            }
            try mask.withUnsafeMutableBytes { buffer in
                try check(api.pointee.CreateTensorWithDataAsOrtValue(
                    memoryInfo, buffer.baseAddress, buffer.count, shapeBuffer.baseAddress, shape.count,
                    ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &maskTensor
                ))
            }
        }

        let firstName = strdup("input_ids"), secondName = strdup("attention_mask"), outputName = strdup("logits")
        defer { free(firstName); free(secondName); free(outputName) }
        let inputNames: [UnsafePointer<CChar>?] = [UnsafePointer(firstName), UnsafePointer(secondName)]
        let inputValues: [OpaquePointer?] = [idTensor, maskTensor]
        let outputNames: [UnsafePointer<CChar>?] = [UnsafePointer(outputName)]
        var output: OpaquePointer?
        try inputNames.withUnsafeBufferPointer { names in
            try inputValues.withUnsafeBufferPointer { values in
                try outputNames.withUnsafeBufferPointer { outputs in
                    try check(api.pointee.Run(session, nil, names.baseAddress, values.baseAddress, values.count, outputs.baseAddress, outputs.count, &output))
                }
            }
        }
        guard let output else { throw ToneError.invalidOutput }
        defer { api.pointee.ReleaseValue(output) }
        var raw: UnsafeMutableRawPointer?
        try check(api.pointee.GetTensorMutableData(output, &raw))
        guard let floats = raw?.assumingMemoryBound(to: Float.self) else { throw ToneError.invalidOutput }
        return (0..<batch).map { row in
            let values = (0..<3).map { Double(floats[row * 3 + $0]) }
            return toneScore(values, maximum: values.max() ?? 0)
        }
    }

    private func check(_ status: OpaquePointer?) throws {
        guard let status else { return }
        let message = api.pointee.GetErrorMessage(status).map(String.init(cString:)) ?? "ONNX Runtime error"
        api.pointee.ReleaseStatus(status)
        throw ToneError.runtime(message)
    }
}

private func toneScore(_ values: [Double], maximum: Double) -> ToneScore {
    let exponents = values.map { Foundation.exp($0 - maximum) }, total = exponents.reduce(0, +)
    return ToneScore(negative: exponents[0] / total, neutral: exponents[1] / total, positive: exponents[2] / total)
}

private final class RobertaTokenizer {
    private let vocab: [String:Int], ranks: [String:Int], pattern: NSRegularExpression, bytes: [UInt8:String]
    private var cache: [String:[String]] = [:]
    init(vocab: URL, merges: URL) throws {
        self.vocab = try JSONDecoder().decode([String:Int].self, from: Data(contentsOf: vocab))
        let lines = try String(contentsOf: merges, encoding: .utf8).split(separator: "\n").dropFirst()
        ranks = Dictionary(uniqueKeysWithValues: lines.enumerated().map { ($0.element.trimmingCharacters(in: .whitespacesAndNewlines), $0.offset) })
        pattern = try NSRegularExpression(pattern: #"(?i:'s|'t|'re|'ve|'m|'ll|'d)| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#)
        bytes = byteEncoder()
    }
    func encode(_ text: String, maximum: Int) -> [Int32] {
        var result: [Int32] = [0]
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in pattern.matches(in: text, range: range) {
            guard let range = Range(match.range, in: text) else { continue }
            let token = String(text[range]).utf8.compactMap { bytes[$0] }.joined()
            for piece in bpe(token) { if let id = vocab[piece], result.count < maximum - 1 { result.append(Int32(id)) } }
        }
        result.append(2); return result
    }
    private func bpe(_ token: String) -> [String] {
        if let value = cache[token] { return value }
        var parts = token.map(String.init)
        while parts.count > 1 {
            var best: (index:Int,rank:Int)?
            for index in 0..<(parts.count-1) { if let rank = ranks[parts[index]+" "+parts[index+1]], best == nil || rank < best!.rank { best = (index,rank) } }
            guard let best else { break }
            parts.replaceSubrange(best.index...best.index+1, with: [parts[best.index]+parts[best.index+1]])
        }
        cache[token] = parts; return parts
    }
}

private func byteEncoder() -> [UInt8:String] {
    var values = Array(33...126) + Array(161...172) + Array(174...255), unicode = values, extra = 0
    for byte in 0...255 where !values.contains(byte) { values.append(byte); unicode.append(256+extra); extra += 1 }
    return Dictionary(uniqueKeysWithValues: zip(values,unicode).compactMap { byte, scalar in UnicodeScalar(scalar).map { (UInt8(byte),String(Character($0))) } })
}

private func aggregateSQL(_ alias: String) -> String { "COUNT(*) count,AVG(\(alias).negative) negative,AVG(\(alias).neutral) neutral,AVG(\(alias).positive) positive,AVG(\(alias).valence) valence,AVG(\(alias).confidence) confidence,SUM(CASE WHEN \(alias).negative>=\(alias).neutral AND \(alias).negative>=\(alias).positive THEN 1 ELSE 0 END) negative_count,SUM(CASE WHEN \(alias).neutral>\(alias).negative AND \(alias).neutral>=\(alias).positive THEN 1 ELSE 0 END) neutral_count,SUM(CASE WHEN \(alias).positive>\(alias).negative AND \(alias).positive>\(alias).neutral THEN 1 ELSE 0 END) positive_count" }
private func publicAggregate(_ row: [String:SQLiteValue]) -> JSONValue { .object(publicAggregateObject(row)) }
private func publicAggregateObject(_ row: [String:SQLiteValue]) -> [String:JSONValue] {
    let count = row["count"]?.int ?? 0
    return ["count":.number(Double(count)),"average":.object(["negative":.number(rounded(row["negative"]?.double ?? 0)),"neutral":.number(rounded(row["neutral"]?.double ?? 0)),"positive":.number(rounded(row["positive"]?.double ?? 0)),"valence":.number(rounded(row["valence"]?.double ?? 0)),"confidence":.number(rounded(row["confidence"]?.double ?? 0))]),"dominant_share":.object(["negative":.number(count > 0 ? rounded(Double(row["negative_count"]?.int ?? 0)/Double(count)) : 0),"neutral":.number(count > 0 ? rounded(Double(row["neutral_count"]?.int ?? 0)/Double(count)) : 0),"positive":.number(count > 0 ? rounded(Double(row["positive_count"]?.int ?? 0)/Double(count)) : 0)])]
}
private func rounded(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
private func isoDate(_ value: String) -> Date? { ISO8601DateFormatter().date(from: value) }
private func fileSize(_ url: URL) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0 }
private func hash(_ url: URL) throws -> String { let data = try Data(contentsOf: url, options: .mappedIfSafe); return SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined() }

private enum ToneError: Error, LocalizedError {
    case invalidDownload, invalidOutput, missingRuntime, runtime(String)
    var errorDescription: String? {
        switch self {
        case .invalidDownload: "The downloaded tone component could not be verified"
        case .invalidOutput: "The local tone model returned an invalid result"
        case .missingRuntime: "The local tone runtime is unavailable"
        case .runtime(let message): "Local tone analysis failed: \(message)"
        }
    }
}

private final class ToneDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64)->Void, lock = NSLock(); private var continuation: CheckedContinuation<URL,Error>?
    init(progress: @escaping @Sendable (Int64)->Void) { self.progress = progress }
    func download(from url: URL) async throws -> URL { try await withCheckedThrowingContinuation { value in lock.withLock { continuation = value }; URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil).downloadTask(with: url).resume() } }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { progress(totalBytesWritten) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString); do { try FileManager.default.moveItem(at: location, to: destination); lock.withLock { let value=continuation; continuation=nil; value?.resume(returning: destination) } } catch { lock.withLock { let value=continuation; continuation=nil; value?.resume(throwing:error) } }; session.finishTasksAndInvalidate() }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { guard let error else{return}; lock.withLock { let value=continuation; continuation=nil; value?.resume(throwing:error) } }
}
