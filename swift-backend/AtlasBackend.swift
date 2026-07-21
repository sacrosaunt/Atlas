import Foundation
import Hummingbird
import Darwin

private let atlasHost = "127.0.0.1"
private let atlasPort = Int(ProcessInfo.processInfo.environment["ATLAS_PORT"] ?? "") ?? 47_831
private let atlasLeaseSeconds: TimeInterval = 15

@main
struct AtlasBackendMain {
    static func main() async throws {
        let parentPID = Darwin.getppid()
        if parentPID > 1 {
            Task.detached {
                while true {
                    try? await Task.sleep(for: .seconds(2))
                    if Darwin.getppid() != parentPID { Darwin.exit(0) }
                }
            }
        }
        let runtime = try AtlasRuntime()
        await runtime.startServices()
        let router = Router(context: BasicRequestContext.self)
        mountCoreRoutes(router, runtime: runtime)
        mountMCPRoutes(router, runtime: runtime)
        let application = Application(
            router: router,
            configuration: .init(address: .hostname(atlasHost, port: atlasPort))
        )
        try await application.runService()
    }
}

actor AtlasRuntime {
    let paths: AtlasPaths
    let token: String
    let identitySecret: String
    let history: AtlasHistory
    let messages: IMessageStore
    let calendar: CalendarStore
    let codex: CodexClient
    let semantic: SemanticIndex
    let tone: ToneIndex
    var activeChats: [String: Task<Void, Never>] = [:]
    var chatActivities: [String: ChatActivityState] = [:]
    var starterSuggestions: [String]?
    var starterSuggestionsGeneratedAt = Date.distantPast
    var starterSuggestionsRefresh: Task<Void, Never>?
    var insightRefresh: Task<Void, Never>?
    private var leaseExpiration = Date.distantPast
    private var leaseGeneration = 0

    init() throws {
        let paths = AtlasPaths()
        try paths.prepare()
        self.paths = paths
        token = try AtlasSecurity.loadOrCreateSecret(at: paths.token)
        identitySecret = try AtlasSecurity.loadOrCreateSecret(at: paths.identityKey)
        history = try AtlasHistory(path: paths.historyDatabase)
        messages = IMessageStore(databasePath: paths.messagesDatabase, home: paths.home, identitySecret: identitySecret)
        calendar = CalendarStore(snapshotPath: paths.calendarSnapshot, identitySecret: identitySecret)
        codex = CodexClient(paths: paths, token: token, port: atlasPort)
        semantic = SemanticIndex(store: messages, directory: paths.semanticDirectory)
        tone = ToneIndex(databaseURL: paths.semanticDirectory.appending(path: "search.sqlite"), directory: paths.toneDirectory)
    }

    func startServices() async {
        let tone = tone
        await semantic.setTextReadyCallback { await tone.setTextIndexReady(true) }
        let semanticStatus = await semantic.status()
        await tone.setTextIndexReady(semanticStatus["text_index_phase"]?.stringValue == "ready")
        await semantic.setForegroundActive(false)
        await tone.setForegroundActive(false)
    }

    func authorized(_ request: Request) -> Bool {
        let host = request.head.authority
        guard host == "\(atlasHost):\(atlasPort)" || host == "localhost:\(atlasPort)",
              let authorization = request.headers[.authorization],
              authorization.hasPrefix("Bearer ") else { return false }
        return AtlasSecurity.constantTimeEquals(String(authorization.dropFirst(7)), token)
    }

    func consentAccepted() -> Bool { AtlasSecurity.consentAccepted(at: paths.consent) }

    func acceptConsent() throws { try AtlasSecurity.saveConsent(at: paths.consent) }

    func renewLease() async {
        leaseExpiration = Date().addingTimeInterval(atlasLeaseSeconds)
        leaseGeneration += 1
        let generation = leaseGeneration
        await semantic.setForegroundActive(true)
        await tone.setForegroundActive(true)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(atlasLeaseSeconds + 0.2))
            await self?.expireLease(ifGeneration: generation)
        }
    }

    func releaseLease() async {
        leaseExpiration = .distantPast
        leaseGeneration += 1
        for task in activeChats.values { task.cancel() }
        starterSuggestionsRefresh?.cancel()
        insightRefresh?.cancel()
        await semantic.setForegroundActive(false)
        await tone.setForegroundActive(false)
    }

    func isActive() -> Bool { Date() < leaseExpiration }

    private func expireLease(ifGeneration generation: Int) async {
        guard generation == leaseGeneration, Date() >= leaseExpiration else { return }
        await releaseLease()
    }
}

private func mountCoreRoutes(_ router: Router<BasicRequestContext>, runtime: AtlasRuntime) {
    router.get("/api/health") { _, _ -> Response in
        do {
            let info = try await runtime.messages.info()
            return try atlasResponse(.object([
                "ok": .bool(true),
                "messages": .number(Double(info.messages)),
                "conversations": .number(Double(info.conversations)),
            ]))
        } catch {
            return try atlasResponse(.object([
                "ok": .bool(false),
                "error": .string(error.localizedDescription),
            ]), status: .serviceUnavailable)
        }
    }

    router.get("/api/setup") { _, _ -> Response in
        let paths = await runtime.paths
        let disclosureAccepted = await runtime.consentAccepted()
        let info: IMessageInfo?
        let accessError: String?
        do {
            info = try await runtime.messages.info()
            accessError = nil
        } catch {
            info = nil
            accessError = error.localizedDescription
        }
        let codex = CodexDiscovery.status(checkLogin: disclosureAccepted)
        return try atlasResponse(.object([
            "full_disk_access": .bool(info != nil),
            "full_disk_access_error": accessError.map(JSONValue.string) ?? .null,
            "codex_installed": .bool(codex.path != nil),
            "codex_logged_in": .bool(codex.loggedIn),
            "disclosure_accepted": .bool(disclosureAccepted),
            "codex_path": codex.path.map(JSONValue.string) ?? .null,
            "service_executable": .string(atlasPermissionTarget()),
            "install_command": .string("npm install --global @openai/codex"),
            "login_command": .string("codex login"),
            "state_directory": .string(paths.support.path),
        ]))
    }

    router.get("/api/consent") { request, _ -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        return try atlasResponse(.object([
            "accepted": .bool(await runtime.consentAccepted()),
            "disclosure_version": .number(Double(AtlasSecurity.disclosureVersion)),
        ]))
    }

    router.post("/api/consent") { request, context -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        let body = try await atlasBody(request, context: context)
        guard body["accepted"]?.boolValue == true,
              body["disclosure_version"]?.intValue == AtlasSecurity.disclosureVersion else {
            return try atlasError("Explicit acceptance of the current disclosure is required", status: .badRequest)
        }
        try await runtime.acceptConsent()
        return try atlasResponse(.object([
            "accepted": .bool(true),
            "disclosure_version": .number(Double(AtlasSecurity.disclosureVersion)),
        ]))
    }

    router.post("/api/app/heartbeat") { request, _ -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        await runtime.renewLease()
        return try atlasResponse(.object([
            "active": .bool(true),
            "lease_ms": .number(atlasLeaseSeconds * 1_000),
        ]))
    }

    router.delete("/api/app/heartbeat") { request, _ -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        await runtime.releaseLease()
        return try atlasResponse(.object(["active": .bool(false)]))
    }

    router.post("/api/restart") { request, _ -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            Darwin.exit(75)
        }
        return try atlasResponse(.object(["restarting": .bool(true)]))
    }

    router.get("/api/chats") { request, _ -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        let chats = try await runtime.history.listChats()
        return try atlasEncodableResponse(["chats": chats])
    }

    router.get("/api/suggestions") { request, _ -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        guard await runtime.consentAccepted() else { return try atlasConsentRequired() }
        guard await runtime.isActive() else { return try atlasActiveRequired() }
        return try atlasResponse(await runtime.suggestionsResponse())
    }

    router.post("/api/suggestions/refresh") { request, _ -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        guard await runtime.consentAccepted() else { return try atlasConsentRequired() }
        guard await runtime.isActive() else { return try atlasActiveRequired() }
        let response = await runtime.requestSuggestionsRefresh()
        return try atlasResponse(response, status: response["status"]?.stringValue == "refreshing" ? .accepted : .ok)
    }

    router.get("/api/insights") { request, _ -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        guard await runtime.consentAccepted() else { return try atlasConsentRequired() }
        guard await runtime.isActive() else { return try atlasActiveRequired() }
        return try atlasResponse(try await runtime.insightsResponse())
    }

    router.post("/api/insights/refresh") { request, _ -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        guard await runtime.consentAccepted() else { return try atlasConsentRequired() }
        guard await runtime.isActive() else { return try atlasActiveRequired() }
        await runtime.forceInsightRefresh()
        return try atlasResponse(.object(["status": .string("refreshing")]), status: .accepted)
    }

    router.post("/api/chats") { request, context -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        guard await runtime.consentAccepted() else { return try atlasConsentRequired() }
        guard await runtime.isActive() else { return try atlasActiveRequired() }
        let body = try await atlasBody(request, context: context)
        guard let prompt = atlasPrompt(body) else {
            return try atlasError("Message must be between 1 and 8,000 characters", status: .badRequest)
        }
        let profile = body["response_profile"]?.stringValue == "faster" ? "faster" : "deeper"
        let insight = body["insight_context"]
        let theme = insight?["theme"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = insight?["evidence"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let codexPrompt: String?
        if let theme, !theme.isEmpty, let evidence, !evidence.isEmpty {
            codexPrompt = """
            Context selected from Atlas Insights:

            Theme: \(String(theme.prefix(300)))

            Evidence point: \(String(evidence.prefix(2_000)))

            Re-examine this evidence against the underlying messages. Be specific, calibrated, and willing to overturn the earlier reading.

            Question: \(prompt)
            """
        } else { codexPrompt = nil }
        do {
            let chat = try await runtime.startNewChat(displayPrompt: prompt, codexPrompt: codexPrompt, profile: profile)
            return try atlasEncodableResponse(chat, status: .accepted)
        } catch ChatCoordinatorError.tooMany {
            return try atlasError(ChatCoordinatorError.tooMany.localizedDescription, status: .tooManyRequests)
        }
    }

    router.get("/api/chats/{id}") { request, context -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        guard let id = context.parameters.get("id", as: String.self),
              let chat = try await runtime.history.getChat(id) else {
            return try atlasError("Conversation not found", status: .notFound)
        }
        return try atlasEncodableResponse(chat)
    }

    router.get("/api/chats/{id}/activity") { request, context -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        guard let id = context.parameters.get("id", as: String.self),
              try await runtime.history.getChat(id) != nil else {
            return try atlasError("Conversation not found", status: .notFound)
        }
        return try atlasResponse(try await runtime.activity(for: id))
    }

    router.delete("/api/chats/{id}") { request, context -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        guard let id = context.parameters.get("id", as: String.self),
              try await runtime.history.getChat(id) != nil else {
            return try atlasError("Conversation not found", status: .notFound)
        }
        do {
            try await runtime.deleteChatAndThread(id)
            return try atlasResponse(.object(["deleted": .bool(true)]))
        } catch {
            return try atlasError("Atlas couldn't delete that conversation. Please try again.", status: .internalServerError)
        }
    }

    router.post("/api/chats/{id}/stop") { request, context -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        guard let id = context.parameters.get("id", as: String.self),
              try await runtime.history.getChat(id) != nil else {
            return try atlasError("Conversation not found", status: .notFound)
        }
        return try atlasResponse(.object(["stopped": .bool(try await runtime.stopChat(id))]))
    }

    router.post("/api/chats/{id}/messages") { request, context -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        guard await runtime.consentAccepted() else { return try atlasConsentRequired() }
        guard await runtime.isActive() else { return try atlasActiveRequired() }
        guard let id = context.parameters.get("id", as: String.self) else {
            return try atlasError("Conversation not found", status: .notFound)
        }
        let body = try await atlasBody(request, context: context)
        guard let prompt = atlasPrompt(body) else {
            return try atlasError("Message must be between 1 and 8,000 characters", status: .badRequest)
        }
        do {
            let chat = try await runtime.continueChat(id, prompt: prompt, profile: body["response_profile"]?.stringValue == "faster" ? "faster" : "deeper")
            return try atlasEncodableResponse(chat, status: .accepted)
        } catch ChatCoordinatorError.notFound {
            return try atlasError("Conversation not found", status: .notFound)
        } catch ChatCoordinatorError.notResumable {
            return try atlasError("Conversation cannot be resumed", status: .conflict)
        } catch ChatCoordinatorError.tooMany {
            return try atlasError(ChatCoordinatorError.tooMany.localizedDescription, status: .tooManyRequests)
        } catch {
            return try atlasError("Atlas couldn't complete that request. Please try again.", status: .internalServerError)
        }
    }

    router.post("/api/conversations") { request, context -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        guard await runtime.consentAccepted() else { return try atlasConsentRequired() }
        guard await runtime.isActive() else { return try atlasActiveRequired() }
        let body = try await atlasBody(request, context: context)
        guard let prompt = atlasPrompt(body) else { return try atlasError("Message must be between 1 and 8,000 characters", status: .badRequest) }
        let chat = try await runtime.startNewChat(displayPrompt: prompt, profile: "deeper")
        while (try await runtime.activity(for: chat.id)["status"]?.stringValue) == "working" { try await Task.sleep(for: .milliseconds(100)) }
        guard let completed = try await runtime.history.getChat(chat.id) else { return try atlasError("Conversation not found", status: .notFound) }
        let response = completed.messages.last(where: { $0.role == "assistant" })?.content ?? ""
        return try atlasResponse(.object([
            "chat_id": .string(completed.id), "thread_id": completed.codex_thread_id.map(JSONValue.string) ?? .null,
            "turn_id": .null, "response": .string(response),
        ]))
    }

    mountCompatibilityStatusRoutes(router, runtime: runtime)
}

private func atlasPermissionTarget() -> String {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    guard let range = executable.range(of: ".app/Contents/MacOS/") else { return executable }
    return String(executable[..<range.lowerBound]) + ".app"
}

private func atlasPrompt(_ body: JSONValue) -> String? {
    guard let value = body["prompt"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty, value.count <= 8_000 else { return nil }
    return value
}

private func mountCompatibilityStatusRoutes(_ router: Router<BasicRequestContext>, runtime: AtlasRuntime) {
    router.get("/api/semantic/status") { request, _ -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        return try atlasResponse(await runtime.semantic.status())
    }
    router.post("/api/semantic/enable") { request, _ -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        return try atlasResponse(await runtime.semantic.enable(), status: .accepted)
    }
    router.post("/api/semantic/disable") { request, _ -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        return try atlasResponse(await runtime.semantic.disable())
    }
    router.delete("/api/semantic") { request, _ -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        return try atlasResponse(try await runtime.semantic.remove())
    }
    router.get("/api/sentiment/status") { request, _ -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        return try atlasResponse(await runtime.tone.status())
    }
    router.get("/api/sentiment/trends") { request, _ -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        guard await runtime.consentAccepted() else { return try atlasConsentRequired() }
        do { return try atlasResponse(try await runtime.tone.trends()) }
        catch { return try atlasError("Local tone trends are not ready yet.", status: .serviceUnavailable) }
    }
    router.post("/api/sentiment/enable") { request, _ -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        return try atlasResponse(await runtime.tone.enable(), status: .accepted)
    }
    router.get("/api/insights/status") { request, _ -> Response in
        guard await runtime.authorized(request) else { return try atlasUnauthorized() }
        guard await runtime.consentAccepted() else { return try atlasConsentRequired() }
        guard await runtime.isActive() else { return try atlasActiveRequired() }
        let insight = try await runtime.history.getInsights()
        return try atlasResponse(.object([
            "status": .string(insight.status),
            "has_document": .bool(insight.content != nil),
            "updated_at": insight.updated_at.map(JSONValue.string) ?? .null,
        ]))
    }
}

func atlasBody(_ request: Request, context: BasicRequestContext) async throws -> JSONValue {
    let buffer = try await request.body.collect(upTo: 1_048_576)
    return try JSONDecoder().decode(JSONValue.self, from: Data(buffer.readableBytesView))
}

func atlasEncodableResponse<T: Encodable>(
    _ value: T,
    status: HTTPResponse.Status = .ok
) throws -> Response {
    let data = try JSONEncoder().encode(value)
    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
    buffer.writeBytes(data)
    return Response(
        status: status,
        headers: [.contentType: "application/json; charset=utf-8"],
        body: .init(byteBuffer: buffer)
    )
}

func atlasResponse(_ value: JSONValue, status: HTTPResponse.Status = .ok) throws -> Response {
    try atlasEncodableResponse(value, status: status)
}

func atlasError(_ message: String, status: HTTPResponse.Status) throws -> Response {
    try atlasResponse(.object(["error": .string(message)]), status: status)
}

func atlasUnauthorized() throws -> Response {
    try atlasError("Atlas app authentication required", status: .unauthorized)
}

private func atlasConsentRequired() throws -> Response {
    try atlasError("Approve the data disclosure in Atlas before using OpenAI analysis", status: .init(code: 428))
}

private func atlasActiveRequired() throws -> Response {
    try atlasError("Open Atlas before starting analysis", status: .conflict)
}
