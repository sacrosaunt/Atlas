import SwiftUI
import LocalAuthentication
import AppKit

private let serviceURL = URL(string: "http://127.0.0.1:47831")!
private let tokenPath = NSString(string: "~/Library/Application Support/Atlas/mcp-token").expandingTildeInPath
private let currentOnboardingVersion = 2

private struct HealthResponse: Decodable {
    let ok: Bool
    let messages: Int?
    let conversations: Int?
    let error: String?
}

private struct ChatListResponse: Decodable { let chats: [ChatSummary] }
private struct ErrorResponse: Decodable { let error: String }
private struct StopResponse: Decodable { let stopped: Bool }
private struct SuggestionResponse: Decodable {
    let suggestions: [String]
    let status: String
}
private struct SetupResponse: Decodable {
    let full_disk_access: Bool
    let codex_installed: Bool
    let codex_logged_in: Bool
    let install_command: String
    let login_command: String
}

struct SemanticSearchStatus: Decodable, Equatable {
    let enabled: Bool
    let installed: Bool
    let phase: String
    let text_index_phase: String
    let text_index_error: String?
    let pause_reason: String?
    let downloaded_bytes: Int64
    let total_download_bytes: Int64
    let indexed_messages: Int
    let total_messages: Int
    let indexed_documents: Int
    let embedded_documents: Int
    let total_documents: Int
    let eta_seconds: Double?
    let preventing_sleep: Bool
    let index_bytes: Int64
    let error: String?
}

struct SentimentStatus: Decodable, Equatable {
    let enabled: Bool
    let installed: Bool
    let phase: String
    let pause_reason: String?
    let preventing_sleep: Bool
    let downloaded_bytes: Int64
    let total_download_bytes: Int64
    let analyzed_turns: Int
    let total_turns: Int
    let analyzed_windows: Int
    let total_windows: Int
    let eta_seconds: Double?
    let model_revision: String
    let error: String?
}

private func atlasETAText(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds > 0 else { return "" }
    if seconds < 60 { return "Less than a minute remaining" }
    if seconds < 3_600 {
        let minutes = Int(ceil(seconds / 60))
        return "About \(minutes) min remaining"
    }
    let hours = Int(ceil(seconds / 3_600))
    return "About \(hours) hr remaining"
}

private func atlasPauseText(_ reason: String?) -> String {
    switch reason {
    case "battery": return "Connect power to continue"
    case "low_power_mode": return "Turn off Low Power Mode to continue"
    case "thermal": return "Waiting for your Mac to cool down"
    default: return "Optimization will resume automatically"
    }
}

struct ChatSummary: Decodable, Identifiable, Hashable {
    let id: String
    let codex_thread_id: String?
    let title: String
    let summary: String?
    let created_at: String
    let updated_at: String
    let preview: String?
    let message_count: Int
}

struct ChatMessage: Decodable, Identifiable, Hashable {
    let id: Int
    let role: String
    let content: String
    let messages_read: Int?
    let created_at: String
}

struct ChatDetail: Decodable {
    let id: String
    let codex_thread_id: String?
    let title: String
    let created_at: String
    let updated_at: String
    let messages: [ChatMessage]
}

struct ChatActivity: Decodable, Equatable {
    let status: String
    let detail: String
    let messages_read: Int
    let tool_calls: Int
    let draft: String?
    let started_at: String?
}

struct InsightSnapshot: Decodable {
    let document: InsightDocument?
    let codex_thread_id: String?
    let source_message_count: Int
    let current_message_count: Int
    let status: String
    let error: String?
    let updated_at: String?
}

struct InsightDocument: Decodable {
    let title: String
    let subtitle: String
    let coverage: InsightCoverage
    let metrics: [InsightMetric]
    let direction: InsightDirection?
    let themes: [InsightTheme]
    let what_could_change: [String]
}

struct InsightDirection: Decodable {
    let sent_count: Int
    let received_count: Int
    let sent_percent: Double
    let received_percent: Double
}

struct InsightCoverage: Decodable {
    let period: String
    let scope: String
    let caveat: String
}

struct InsightMetric: Decodable, Identifiable {
    var id: String { label }
    let label: String
    let value: String
}

struct InsightTheme: Decodable, Identifiable {
    let id: String
    let category: String
    let title: String
    let claim: String
    let confidence: String
    let evidence_strength: Int
    let trajectory: String
    let evidence: [String]
    let counterevidence: String
    let why_it_matters: String
}

private struct ChatBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatScrollIntentMonitor: NSViewRepresentable {
    let onUserScroll: () -> Void

    final class Coordinator {
        var onUserScroll: () -> Void
        private var observer: NSObjectProtocol?

        init(onUserScroll: @escaping () -> Void) {
            self.onUserScroll = onUserScroll
        }

        func attach(to view: NSView) {
            guard observer == nil else { return }
            guard let scrollView = view.enclosingScrollView else {
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.attach(to: view)
                }
                return
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.onUserScroll()
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onUserScroll: onUserScroll)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.attach(to: view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onUserScroll = onUserScroll
        context.coordinator.attach(to: view)
    }
}

enum SidebarSelection: Hashable {
    case insights
    case chat(String)
}

@MainActor
final class AtlasModel: ObservableObject {
    enum LockState: Equatable { case locked, unlocking, unlocked }

    @Published var lockState: LockState = .locked
    @Published var chats: [ChatSummary] = []
    @Published var selection: SidebarSelection? = .insights
    @Published var selectedChat: ChatDetail?
    @Published var insights: InsightSnapshot?
    @Published var prompt = ""
    @Published var isSending = false
    @Published var sendingChatID: String?
    @Published var chatActivity: ChatActivity?
    @Published var status = "Checking local service…"
    @Published var fullDiskAccessReady = false
    @Published var codexInstalled = false
    @Published var codexLoggedIn = false
    @Published var codexInstallCommand = "npm install --global @openai/codex"
    @Published var codexLoginCommand = "codex login"
    @Published var semanticSearch: SemanticSearchStatus?
    @Published var sentiment: SentimentStatus?
    @Published var suggestions: [String] = []
    @Published var suggestionsRefreshing = false
    @Published var error: String?

    private var authContext: LAContext?

    func unlock() async {
        guard lockState != .unlocking else { return }
        lockState = .unlocking
        error = nil
        let context = LAContext()
        context.localizedCancelTitle = "Keep Locked"
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &policyError) else {
            lockState = .locked
            error = "Touch ID is unavailable: \(policyError?.localizedDescription ?? "unknown reason")"
            return
        }
        do {
            if try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock your private Atlas conversations"
            ) {
                authContext = context
                lockState = .unlocked
                await loadInitialData()
            } else {
                lockState = .locked
            }
        } catch {
            lockState = .locked
            self.error = error.localizedDescription
        }
    }

    func lock() {
        authContext?.invalidate()
        authContext = nil
        lockState = .locked
        selectedChat = nil
        prompt = ""
        error = nil
    }

    func unlockWithoutBiometrics() async {
        guard lockState != .unlocked else { return }
        authContext?.invalidate()
        authContext = nil
        lockState = .unlocked
        error = nil
        await loadInitialData()
    }

    func loadInitialData() async {
        async let health: Void = checkHealth()
        async let history: Void = loadChats()
        async let profile: Void = loadInsights()
        async let semantic: Void = loadSemanticStatus()
        async let tone: Void = loadSentimentStatus()
        async let starters: Void = loadSuggestions()
        _ = await (health, history, profile, semantic, tone, starters)
    }

    func checkHealth() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: serviceURL.appending(path: "api/health"))
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let health = try JSONDecoder().decode(HealthResponse.self, from: data)
            status = http.statusCode == 200 && health.ok
                ? "Local · \(health.conversations ?? 0) conversations"
                : health.error ?? "Local service needs attention"
            fullDiskAccessReady = http.statusCode == 200 && health.ok
        } catch {
            status = "Atlas service unavailable"
            fullDiskAccessReady = false
        }
    }

    func checkSetup() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: serviceURL.appending(path: "api/setup"))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let setup = try JSONDecoder().decode(SetupResponse.self, from: data)
            fullDiskAccessReady = setup.full_disk_access
            codexInstalled = setup.codex_installed
            codexLoggedIn = setup.codex_logged_in
            codexInstallCommand = setup.install_command
            codexLoginCommand = setup.login_command
        } catch {
            fullDiskAccessReady = false
            codexInstalled = false
            codexLoggedIn = false
        }
    }

    func loadChats() async {
        do {
            let response: ChatListResponse = try await request(path: "api/chats")
            chats = response.chats
        } catch {
            self.error = error.localizedDescription
        }
    }

    func select(_ newSelection: SidebarSelection?) async {
        selection = newSelection
        prompt = ""
        chatActivity = nil
        error = nil
        switch newSelection {
        case .chat(let id): await loadChat(id)
        case .insights: selectedChat = nil; await loadInsights()
        case nil: selectedChat = nil
        }
    }

    func newChat() {
        selection = nil
        selectedChat = nil
        prompt = ""
        chatActivity = nil
        error = nil
        Task { await loadSuggestions(refresh: true) }
    }

    func loadSuggestions(refresh: Bool = false) async {
        suggestionsRefreshing = true
        for attempt in 0..<10 {
            do {
                let response: SuggestionResponse
                if refresh && attempt == 0 {
                    response = try await request(
                        path: "api/suggestions/refresh",
                        method: "POST",
                        body: [:]
                    )
                } else {
                    response = try await request(path: "api/suggestions")
                }
                if !response.suggestions.isEmpty, response.suggestions != suggestions {
                    withAnimation(.spring(response: 0.46, dampingFraction: 0.82)) {
                        suggestions = response.suggestions
                    }
                }
                if response.status == "ready" {
                    suggestionsRefreshing = false
                    return
                }
            } catch {
                suggestionsRefreshing = false
                return
            }
            if attempt < 9 { try? await Task.sleep(for: .seconds(2)) }
        }
        suggestionsRefreshing = false
    }

    func loadChat(_ id: String) async {
        do {
            selectedChat = try await request(path: "api/chats/\(id)")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteChat(_ id: String) async {
        if sendingChatID == id {
            withAnimation(.smooth(duration: 0.2)) {
                isSending = false
                sendingChatID = nil
                chatActivity = nil
            }
        }
        do {
            let _: DeleteResponse = try await request(path: "api/chats/\(id)", method: "DELETE")
            if case .chat(let selectedID) = selection, selectedID == id {
                selection = .insights
                selectedChat = nil
                prompt = ""
            }
            await loadChats()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadInsights() async {
        guard lockState == .unlocked else { return }
        do {
            insights = try await request(path: "api/insights")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refreshInsights() async {
        do {
            let _: RefreshResponse = try await request(path: "api/insights/refresh", method: "POST", body: [:])
            await loadInsights()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadSemanticStatus() async {
        do {
            semanticSearch = try await request(path: "api/semantic/status")
        } catch {
            // Keep the rest of Atlas usable if enhanced search is unavailable.
        }
    }

    func enableSemanticSearch() async {
        do {
            semanticSearch = try await request(path: "api/semantic/enable", method: "POST", body: [:])
        } catch {
            self.error = error.localizedDescription
        }
    }

    func disableSemanticSearch() async {
        do {
            semanticSearch = try await request(path: "api/semantic/disable", method: "POST", body: [:])
        } catch {
            self.error = error.localizedDescription
        }
    }

    func removeSemanticSearch() async {
        do {
            semanticSearch = try await request(path: "api/semantic", method: "DELETE")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadSentimentStatus() async {
        do {
            sentiment = try await request(path: "api/sentiment/status")
        } catch {
            // Tone analysis is additive; keep the rest of Atlas available.
        }
    }

    func enableSentimentAnalysis() async {
        do {
            sentiment = try await request(path: "api/sentiment/enable", method: "POST", body: [:])
        } catch {
            self.error = error.localizedDescription
        }
    }

    func send(responseProfile: String) async {
        let message = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isSending else { return }
        let profile = responseProfile == "faster" ? "faster" : "deeper"
        isSending = true
        if case .chat(let id) = selection { sendingChatID = id }
        chatActivity = ChatActivity(
            status: "working",
            detail: "Understanding your question…",
            messages_read: 0,
            tool_calls: 0,
            draft: "",
            started_at: nil
        )
        prompt = ""
        error = nil
        do {
            let chat: ChatDetail
            if case .chat(let id) = selection {
                chat = try await request(
                    path: "api/chats/\(id)/messages",
                    method: "POST",
                    body: ["prompt": message, "response_profile": profile]
                )
            } else {
                chat = try await request(
                    path: "api/chats",
                    method: "POST",
                    body: ["prompt": message, "response_profile": profile]
                )
                selection = .chat(chat.id)
            }
            sendingChatID = chat.id
            withAnimation(.smooth(duration: 0.3)) {
                selectedChat = chat
                selection = .chat(chat.id)
            }
            await loadChats()
            await monitorChat(chat.id)
        } catch {
            prompt = message
            self.error = error.localizedDescription
        }
        if isSending {
            withAnimation(.smooth(duration: 0.25)) {
                isSending = false
                sendingChatID = nil
                chatActivity = nil
            }
        }
    }

    func stopSending() async {
        guard isSending, let id = sendingChatID else { return }
        if let current = chatActivity {
            withAnimation(.smooth(duration: 0.2)) {
                chatActivity = ChatActivity(
                    status: "stopping",
                    detail: "Stopping…",
                    messages_read: current.messages_read,
                    tool_calls: current.tool_calls,
                    draft: current.draft,
                    started_at: current.started_at
                )
            }
        }
        do {
            let _: StopResponse = try await request(
                path: "api/chats/\(id)/stop",
                method: "POST",
                body: [:]
            )
            if case .chat(let selectedID) = selection, selectedID == id {
                await loadChat(id)
            }
            withAnimation(.smooth(duration: 0.2)) {
                isSending = false
                sendingChatID = nil
                chatActivity = nil
            }
            await loadChats()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func monitorChat(_ id: String) async {
        while !Task.isCancelled {
            guard isSending, sendingChatID == id else { return }
            try? await Task.sleep(for: .milliseconds(160))
            guard isSending, sendingChatID == id else { return }
            do {
                let activity: ChatActivity = try await request(path: "api/chats/\(id)/activity")
                withAnimation(.smooth(duration: 0.18)) { chatActivity = activity }
                if ["complete", "error", "stopped"].contains(activity.status) {
                    let chat: ChatDetail = try await request(path: "api/chats/\(id)")
                    var handoff = Transaction(animation: nil)
                    handoff.disablesAnimations = true
                    withTransaction(handoff) {
                        if case .chat(let selectedID) = selection, selectedID == id {
                            selectedChat = chat
                        }
                        isSending = false
                        sendingChatID = nil
                        chatActivity = nil
                    }
                    await loadChats()
                    if activity.status == "error" { error = activity.detail }
                    return
                }
            } catch {
                guard isSending, sendingChatID == id else { return }
                self.error = "Atlas lost contact with its local service."
                return
            }
        }
    }

    private struct RefreshResponse: Decodable { let status: String }
    private struct DeleteResponse: Decodable { let deleted: Bool }

    private func request<T: Decodable>(
        path: String,
        method: String = "GET",
        body: [String: String]? = nil
    ) async throws -> T {
        let token = try String(contentsOfFile: tokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: serviceURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 660
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode >= 400 {
            let serverError = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw NSError(
                domain: "Atlas",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: serverError?.error ?? "Request failed"]
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

struct AtlasView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model = AtlasModel()
    @AppStorage("atlas.onboarding.version") private var onboardingVersion = 0
    @AppStorage("atlas.disclosure.acceptedAt") private var disclosureAcceptedAt = ""
    @AppStorage("atlas.touchID.enabled") private var touchIDEnabled = true
    @AppStorage("atlas.response.profile") private var responseProfile = "deeper"
    @State private var chatPendingDeletion: ChatSummary?
    @State private var copiedMessageID: Int?
    @State private var showSettings = false
    @State private var chatIsNearBottom = true
    @State private var hoveredSuggestion: String?
    @Namespace private var reasoningToggleAnimation

    private var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.48, green: 0.82, blue: 0.62)
            : Color(red: 0.10, green: 0.38, blue: 0.25)
    }

    private var background: Color {
        colorScheme == .dark
            ? Color(red: 0.055, green: 0.065, blue: 0.058)
            : Color(red: 0.955, green: 0.94, blue: 0.89)
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            ambientBackground
            if onboardingVersion < currentOnboardingVersion {
                AtlasOnboardingView(model: model, touchIDEnabled: $touchIDEnabled) {
                    disclosureAcceptedAt = ISO8601DateFormatter().string(from: Date())
                    onboardingVersion = currentOnboardingVersion
                }
            } else if model.lockState == .unlocked {
                mainView
            } else {
                lockedView
            }
        }
        .frame(minWidth: 880, minHeight: 640)
        .task(id: "\(onboardingVersion)-\(touchIDEnabled)") {
            if onboardingVersion >= currentOnboardingVersion && model.lockState == .locked {
                if touchIDEnabled {
                    await model.unlock()
                } else {
                    await model.unlockWithoutBiometrics()
                }
            }
        }
        .task(id: model.lockState) {
            guard model.lockState == .unlocked else { return }
            while !Task.isCancelled && model.lockState == .unlocked {
                let delay: Duration = model.insights?.status == "refreshing"
                    ? .seconds(1)
                    : .seconds(30)
                try? await Task.sleep(for: delay)
                await model.loadInsights()
            }
        }
        .task(id: "semantic-\(model.lockState)") {
            guard model.lockState == .unlocked else { return }
            while !Task.isCancelled && model.lockState == .unlocked {
                async let semantic: Void = model.loadSemanticStatus()
                async let tone: Void = model.loadSentimentStatus()
                _ = await (semantic, tone)
                let phase = model.semanticSearch?.phase ?? ""
                let textIndexing = model.semanticSearch?.text_index_phase == "indexing"
                let tonePhase = model.sentiment?.phase ?? ""
                let delay: Duration = phase == "paused" || tonePhase == "paused"
                    ? .seconds(3)
                    : (textIndexing
                       || ["downloading", "indexing", "embedding"].contains(phase)
                       || ["downloading", "preparing", "analyzing"].contains(tonePhase)
                       ? .milliseconds(700)
                       : .seconds(30))
                try? await Task.sleep(for: delay)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if onboardingVersion >= currentOnboardingVersion && touchIDEnabled && phase != .active { model.lock() }
        }
    }

    private var ambientBackground: some View {
        GeometryReader { geometry in
            Circle()
                .fill(accent.opacity(colorScheme == .dark ? 0.12 : 0.20))
                .frame(width: 520, height: 520)
                .blur(radius: 28)
                .offset(x: -220, y: geometry.size.height - 280)
            Circle()
                .fill(Color.orange.opacity(colorScheme == .dark ? 0.08 : 0.14))
                .frame(width: 420, height: 420)
                .blur(radius: 32)
                .offset(x: geometry.size.width - 210, y: -220)
        }
        .allowsHitTesting(false)
    }

    private var lockedView: some View {
        VStack(spacing: 22) {
            Image(systemName: "touchid")
                .font(.system(size: 62, weight: .light))
                .foregroundStyle(accent)
            Text("Atlas")
                .font(.system(size: 46, weight: .medium, design: .serif))
            Text("Your message history stays on this Mac.\nUnlock with Touch ID to continue.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
            Button(model.lockState == .unlocking ? "Waiting for Touch ID…" : "Unlock with Touch ID") {
                Task { await model.unlock() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(accent)
            .disabled(model.lockState == .unlocking)
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: 420)
            }
        }
        .padding(60)
    }

    private var mainView: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                brandHeader
                List(selection: Binding(
                    get: { model.selection },
                    set: { value in Task { await model.select(value) } }
                )) {
                    Section {
                        Label("Insights", systemImage: "sparkles")
                            .tag(SidebarSelection.insights)
                    }
                    Section("Conversations") {
                        ForEach(model.chats) { chat in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chat.title).lineLimit(1).font(.callout.weight(.medium))
                                if let summary = chat.summary ?? chat.preview {
                                    Text(summary.replacingOccurrences(of: "\n", with: " "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .padding(.vertical, 4)
                            .tag(SidebarSelection.chat(chat.id))
                            .contextMenu {
                                Button("Delete Conversation", role: .destructive) {
                                    chatPendingDeletion = chat
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    chatPendingDeletion = chat
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                if let semantic = model.semanticSearch {
                    if semantic.text_index_phase == "indexing" {
                        sidebarTextIndexProgress(semantic)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                    }
                }
                if let sentiment = model.sentiment,
                   ["downloading", "preparing", "analyzing", "paused"].contains(sentiment.phase) {
                    sidebarSentimentProgress(sentiment)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                } else if let semantic = model.semanticSearch,
                          semantic.text_index_phase != "indexing",
                          ["downloading", "indexing", "embedding", "paused"].contains(semantic.phase) {
                        sidebarSemanticProgress(semantic)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                }
                HStack {
                    Label(model.status, systemImage: "lock.fill")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).fixedSize().help("Atlas settings")
                    if touchIDEnabled {
                        Button { model.lock() } label: { Image(systemName: "lock") }
                            .buttonStyle(.plain).help("Lock Atlas")
                    }
                }
                .padding(14)
            }
            .background(.ultraThinMaterial)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.newChat() } label: { Image(systemName: "square.and.pencil") }
                        .help("New conversation")
                }
            }
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .tint(accent)
        .alert(
            "Delete conversation?",
            isPresented: Binding(
                get: { chatPendingDeletion != nil },
                set: { if !$0 { chatPendingDeletion = nil } }
            ),
            presenting: chatPendingDeletion
        ) { chat in
            Button("Cancel", role: .cancel) { chatPendingDeletion = nil }
            Button("Delete", role: .destructive) {
                chatPendingDeletion = nil
                Task { await model.deleteChat(chat.id) }
            }
        } message: { chat in
            Text("This removes “\(chat.title)” and its messages from Atlas. It does not change anything in Messages.")
        }
        .sheet(isPresented: $showSettings) {
            AtlasSettingsView(
                model: model,
                touchIDEnabled: $touchIDEnabled,
                accent: accent
            ) {
                showSettings = false
                model.lock()
                onboardingVersion = 0
            }
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            AtlasBrandMark(size: 36)
            Text("Atlas").font(.system(size: 22, weight: .semibold, design: .serif))
            Spacer()
        }
        .padding(16)
    }

    private func sidebarSemanticProgress(_ status: SemanticSearchStatus) -> some View {
        let isDownloading = status.phase == "downloading"
        let isEmbedding = status.phase == "embedding"
        let isPaused = status.phase == "paused"
        let usesEmbeddingProgress = isEmbedding || isPaused
        let completed = isDownloading
            ? status.downloaded_bytes
            : Int64(usesEmbeddingProgress ? status.embedded_documents : status.indexed_messages)
        let total = isDownloading
            ? status.total_download_bytes
            : Int64(usesEmbeddingProgress ? status.total_documents : status.total_messages)
        let fraction = total > 0 ? min(1, Double(completed) / Double(total)) : 0
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: isDownloading ? "arrow.down.circle" : "sparkles")
                    .foregroundStyle(accent)
                Text(isDownloading
                     ? "Downloading enhanced search…"
                     : (isPaused
                        ? "Optimization paused"
                        : (isEmbedding ? "Optimizing model…" : "Preparing enhanced search…")))
                    .font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: fraction).tint(accent)
            if isPaused {
                Text(atlasPauseText(status.pause_reason))
                    .font(.caption2).foregroundStyle(.secondary)
            } else if isEmbedding {
                Text(status.eta_seconds.map { atlasETAText($0) } ?? "Computing ETA…")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if !isDownloading, status.total_messages > 0 {
                Text("\(status.indexed_messages.formatted()) of \(status.total_messages.formatted()) messages")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
    }

    private func sidebarSentimentProgress(_ status: SentimentStatus) -> some View {
        let isDownloading = status.phase == "downloading"
        let completedUnits = status.analyzed_turns + status.analyzed_windows
        let totalUnits = status.total_turns + status.total_windows
        let completed = isDownloading ? status.downloaded_bytes : Int64(completedUnits)
        let total = isDownloading ? status.total_download_bytes : Int64(totalUnits)
        let fraction = total > 0 ? min(1, Double(completed) / Double(total)) : 0
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: isDownloading ? "arrow.down.circle" : "waveform.path.ecg")
                    .foregroundStyle(accent)
                Text(isDownloading
                     ? "Downloading tone analysis…"
                     : (status.phase == "paused" ? "Tone analysis paused" : "Analyzing conversational tone…"))
                    .font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: fraction).tint(accent)
            if status.phase == "paused" {
                Text(atlasPauseText(status.pause_reason))
                    .font(.caption2).foregroundStyle(.secondary)
            } else if isDownloading {
                Text("Runs privately on this Mac after fast search is ready")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(status.eta_seconds.map { atlasETAText($0) } ?? "Computing ETA…")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
    }

    private func sidebarTextIndexProgress(_ status: SemanticSearchStatus) -> some View {
        let fraction = status.total_messages > 0
            ? min(1, Double(status.indexed_messages) / Double(status.total_messages))
            : 0
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(accent)
                Text("Preparing fast search…")
                    .font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: fraction).tint(accent)
            if status.total_messages > 0 {
                Text("\(status.indexed_messages.formatted()) of \(status.total_messages.formatted()) messages")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
    }

    @ViewBuilder
    private var detailView: some View {
        ZStack {
            Color.clear
            switch model.selection {
            case .insights: insightsView
            case .chat: chatView
            case nil: newChatView
            }
        }
        .background(background.opacity(colorScheme == .dark ? 0.55 : 0.72))
        .overlay(alignment: .top) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).padding(10)
                    .background(.regularMaterial, in: Capsule())
                    .foregroundStyle(.red).padding()
            }
        }
    }

    private var insightsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Insights About You")
                            .font(.system(size: 42, weight: .regular, design: .serif))
                        Text(model.insights?.document?.subtitle ?? "Evidence-based patterns, including uncertainty and counterevidence.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.insights?.status == "refreshing" {
                        Label("Updating…", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else if let updated = model.insights?.updated_at {
                        Label(updated.atlasUpdatedLabel, systemImage: "checkmark.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                if model.insights?.status == "refreshing" {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.insights?.document == nil
                                 ? "Insights will be ready shortly"
                                 : "Updating insights from new messages…")
                                .font(.callout.weight(.medium))
                            if model.insights?.document == nil {
                                Text("Atlas is reviewing your message history now.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }

                if let document = model.insights?.document {
                    insightMetrics(document.metrics, direction: document.direction)
                    coverageCard(document.coverage)
                    evidenceOverview(document.themes)

                    VStack(alignment: .leading, spacing: 14) {
                        Text("PATTERNS").font(.caption.bold()).tracking(1.4).foregroundStyle(.secondary)
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 380), spacing: 16, alignment: .top)],
                            alignment: .leading,
                            spacing: 16
                        ) {
                            ForEach(document.themes) { theme in
                                insightCard(theme)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Label("What could change this read", systemImage: "questionmark.circle")
                            .font(.headline)
                        ForEach(document.what_could_change, id: \.self) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(accent.opacity(0.7)).frame(width: 5, height: 5).padding(.top, 7)
                                Text(item).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                } else if model.insights?.status != "refreshing" {
                    ContentUnavailableView(
                        "No insights yet",
                        systemImage: "sparkles",
                        description: Text("Atlas will build a careful longitudinal read from your local message history.")
                    )
                    .frame(minHeight: 320)
                }

            }
            .padding(34)
        }
    }

    private func insightMetrics(_ metrics: [InsightMetric], direction: InsightDirection?) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12, alignment: .top),
                GridItem(.flexible(), spacing: 12, alignment: .top),
            ],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(Array(metrics.prefix(direction == nil ? 4 : 3))) { metric in
                VStack(alignment: .leading, spacing: 7) {
                    Text(metric.value)
                        .font(.system(size: metric.value.count > 18 ? 18 : 27, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(metric.label.uppercased())
                        .font(.caption2.bold()).tracking(0.8).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            if let direction {
                directionCard(direction)
            }
        }
    }

    private func directionCard(_ direction: InsightDirection) -> some View {
        let sentColor = accent
        let receivedColor = Color(red: 0.39, green: 0.58, blue: 0.96)
        return VStack(alignment: .leading, spacing: 10) {
            Text("DIRECTION").font(.caption2.bold()).tracking(0.8).foregroundStyle(.secondary)

            GeometryReader { geometry in
                HStack(spacing: 2) {
                    Rectangle()
                        .fill(sentColor.gradient)
                        .frame(width: max(2, (geometry.size.width - 2) * direction.sent_percent / 100))
                    Rectangle().fill(receivedColor.gradient)
                }
                .clipShape(Capsule())
            }
            .frame(height: 13)

            HStack(spacing: 12) {
                directionLegend("Sent", value: direction.sent_percent, color: sentColor)
                directionLegend("Received", value: direction.received_percent, color: receivedColor)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func directionLegend(_ label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(label) \(value, specifier: "%.1f")%")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func coverageCard(_ coverage: InsightCoverage) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                Image(systemName: "scope")
                    .font(.title3).foregroundStyle(accent)
                    .frame(width: 38, height: 38)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text("EVIDENCE COVERAGE").font(.caption2.bold()).tracking(1).foregroundStyle(.secondary)
                    Text(coverage.period).font(.headline)
                }
                Spacer()
            }
            Text(coverage.scope)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.55)
            Label {
                Text(coverage.caveat).font(.caption).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "info.circle").foregroundStyle(accent)
            }
        }
        .padding(20)
        .background(accent.opacity(colorScheme == .dark ? 0.10 : 0.075), in: RoundedRectangle(cornerRadius: 18))
    }

    private func evidenceOverview(_ themes: [InsightTheme]) -> some View {
        let broad = themes.filter { $0.evidence_strength >= 5 }
        let repeated = themes.filter { $0.evidence_strength == 4 }
        let limited = themes.filter { $0.evidence_strength <= 3 }
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("How well supported are these patterns?").font(.headline)
                Text("This shows how widely a pattern appears in your messages—not whether it is good, bad, or permanent.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 12
            ) {
                if !broad.isEmpty {
                    evidenceGroup(
                        "Broad evidence",
                        detail: "Repeated across several people and years",
                        icon: "square.stack.3d.up.fill",
                        color: .green,
                        themes: broad
                    )
                }
                if !repeated.isEmpty {
                    evidenceGroup(
                        "Repeated evidence",
                        detail: "Seen in several contexts, with some limits",
                        icon: "repeat",
                        color: .blue,
                        themes: repeated
                    )
                }
                if !limited.isEmpty {
                    evidenceGroup(
                        "Early signal",
                        detail: "Based on narrower or more ambiguous evidence",
                        icon: "binoculars.fill",
                        color: .orange,
                        themes: limited
                    )
                }
            }
        }
        .padding(22)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }

    private func evidenceGroup(
        _ title: String,
        detail: String,
        icon: String,
        color: Color,
        themes: [InsightTheme]
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                Image(systemName: icon).foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.bold())
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Divider().opacity(0.45)
            ForEach(themes) { theme in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(color).frame(width: 5, height: 5).padding(.top, 6)
                    Text(theme.title).font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
    }

    private func insightCard(_ theme: InsightTheme) -> some View {
        let color = categoryColor(theme.category)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: categoryIcon(theme.category))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 38, height: 38)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(theme.category.uppercased())
                        .font(.caption2.bold()).tracking(1.1).foregroundStyle(color)
                    Text(theme.title).font(.title3.weight(.semibold))
                }
                Spacer()
            }

            Text(theme.claim).font(.body).lineSpacing(3).textSelection(.enabled)

            HStack(spacing: 8) {
                insightBadge(theme.confidence.uppercased(), icon: "checkmark.seal", color: confidenceColor(theme.confidence))
                insightBadge(theme.trajectory.uppercased(), icon: trajectoryIcon(theme.trajectory), color: color)
                insightBadge(evidenceLevel(theme.evidence_strength).uppercased(), icon: "books.vertical", color: evidenceColor(theme.evidence_strength))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("EVIDENCE").font(.caption2.bold()).tracking(1).foregroundStyle(.secondary)
                ForEach(theme.evidence, id: \.self) { item in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "plus").font(.caption2.bold()).foregroundStyle(color).padding(.top, 3)
                        Text(item).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Label("Counterevidence", systemImage: "arrow.left.arrow.right")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                Text(theme.counterevidence).font(.callout).foregroundStyle(.secondary)
            }
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 5) {
                Text("WHY IT MATTERS").font(.caption2.bold()).tracking(1).foregroundStyle(color)
                Text(theme.why_it_matters).font(.callout.weight(.medium))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(color.opacity(0.16), lineWidth: 1))
    }

    private func insightBadge(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 9, weight: .bold)).tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(color.opacity(0.10), in: Capsule())
    }

    private func categoryColor(_ category: String) -> Color {
        switch category {
        case "relationships": return .pink
        case "decisions": return .orange
        case "support": return .teal
        case "self-perception": return .purple
        case "change": return .blue
        default: return accent
        }
    }

    private func categoryIcon(_ category: String) -> String {
        switch category {
        case "relationships": return "person.2.fill"
        case "decisions": return "arrow.triangle.branch"
        case "support": return "hands.and.sparkles.fill"
        case "self-perception": return "eye.fill"
        case "change": return "chart.line.uptrend.xyaxis"
        default: return "bubble.left.and.text.bubble.right.fill"
        }
    }

    private func confidenceColor(_ confidence: String) -> Color {
        switch confidence {
        case "high": return .green
        case "medium": return .orange
        default: return .secondary
        }
    }

    private func evidenceLevel(_ strength: Int) -> String {
        if strength >= 5 { return "Broad evidence" }
        if strength == 4 { return "Repeated evidence" }
        return "Early signal"
    }

    private func evidenceColor(_ strength: Int) -> Color {
        if strength >= 5 { return .green }
        if strength == 4 { return .blue }
        return .orange
    }

    private func trajectoryIcon(_ trajectory: String) -> String {
        switch trajectory {
        case "rising": return "arrow.up.right"
        case "declining": return "arrow.down.right"
        case "stable": return "arrow.right"
        case "mixed": return "arrow.up.arrow.down"
        default: return "questionmark"
        }
    }

    private var chatView: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.selectedChat?.title ?? "Conversation")
                        .font(.system(size: 28, weight: .medium, design: .serif)).lineLimit(1)
                }
                Spacer()
                reasoningToggle
                if let chat = model.selectedChat {
                    Button {
                        chatPendingDeletion = model.chats.first(where: { $0.id == chat.id })
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Delete conversation")
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
            Divider()
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            ForEach(model.selectedChat?.messages ?? []) { message in
                                messageRow(message)
                                    .id(message.id)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .opacity
                                    ))
                            }
                            if model.isSending {
                                Group {
                                    if let draft = model.chatActivity?.draft, !draft.isEmpty {
                                        streamingResponseRow(
                                            draft,
                                            messagesRead: model.chatActivity?.messages_read ?? 0
                                        )
                                    } else {
                                        activityRow(model.chatActivity)
                                    }
                                }
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                                .id("thinking")
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("chat-bottom")
                                .background {
                                    GeometryReader { marker in
                                        Color.clear.preference(
                                            key: ChatBottomPreferenceKey.self,
                                            value: marker.frame(in: .named("chat-scroll")).maxY
                                        )
                                    }
                                }
                        }
                        .padding(28)
                        .animation(.smooth(duration: 0.3), value: model.selectedChat?.messages.count)
                    }
                    .background(ChatScrollIntentMonitor {
                        chatIsNearBottom = false
                    })
                    .coordinateSpace(name: "chat-scroll")
                    .onPreferenceChange(ChatBottomPreferenceKey.self) { bottomY in
                        chatIsNearBottom = bottomY <= viewport.size.height + 72
                    }
                    .onChange(of: model.selection) { _, _ in
                        chatIsNearBottom = true
                    }
                    .onChange(of: model.selectedChat?.messages.count) { _, _ in
                        guard chatIsNearBottom else { return }
                        if let id = model.selectedChat?.messages.last?.id {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                    .onChange(of: model.isSending) { _, sending in
                        if sending {
                            chatIsNearBottom = true
                            withAnimation(.smooth(duration: 0.28)) {
                                proxy.scrollTo("chat-bottom", anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: model.chatActivity?.draft?.count) { _, _ in
                        guard model.isSending, chatIsNearBottom else { return }
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
            }
            composer
        }
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        let isOutgoing = message.role == "user"
        return HStack {
            if isOutgoing { Spacer(minLength: 90) }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(isOutgoing ? "YOU" : "ATLAS")
                        .font(.caption2.bold()).tracking(1.1).foregroundStyle(.secondary)
                    if !isOutgoing, let count = message.messages_read, count > 0 {
                        messagesReadBadge(count)
                    }
                }
                MarkdownText(message.content).textSelection(.enabled).lineSpacing(4)
                if !isOutgoing {
                    HStack {
                        Button {
                            copyResponse(message)
                        } label: {
                            Label(
                                copiedMessageID == message.id ? "Copied" : "Copy",
                                systemImage: copiedMessageID == message.id ? "checkmark" : "doc.on.doc"
                            )
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(copiedMessageID == message.id ? accent : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .help("Copy response")
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
            .frame(width: isOutgoing ? outgoingMessageWidth(message.content) : nil, alignment: .leading)
            .frame(maxWidth: isOutgoing ? nil : .infinity, alignment: .leading)
            .padding(isOutgoing ? 16 : 4)
            .background(isOutgoing ? AnyShapeStyle(accent.opacity(0.16)) : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: 17))
            if !isOutgoing { Spacer(minLength: 56) }
        }
    }

    private func outgoingMessageWidth(_ content: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let longestLine = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { (String($0) as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return min(480, max(38, ceil(longestLine + 2)))
    }

    private func copyResponse(_ message: ChatMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            message.content.replacingOccurrences(of: "==", with: ""),
            forType: .string
        )
        withAnimation(.smooth(duration: 0.2)) { copiedMessageID = message.id }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if copiedMessageID == message.id {
                withAnimation(.smooth(duration: 0.2)) { copiedMessageID = nil }
            }
        }
    }

    private func activityRow(_ activity: ChatActivity?) -> some View {
        let messagesRead = activity?.messages_read ?? 0
        let toolCalls = activity?.tool_calls ?? 0
        return HStack(spacing: 13) {
            AtlasThinkingPulse(color: accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(activity?.detail ?? "Understanding your question…")
                    .font(.callout.weight(.medium))
                    .contentTransition(.opacity)
                if messagesRead > 0 {
                    Text("\(messagesRead.formatted()) messages read")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                } else if toolCalls > 0 {
                    Text("\(toolCalls.formatted()) archive checks complete")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            Spacer()
        }
        .padding(14)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .animation(.smooth(duration: 0.3), value: activity)
    }

    private func streamingResponseRow(_ draft: String, messagesRead: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("ATLAS")
                        .font(.caption2.bold()).tracking(1.1).foregroundStyle(.secondary)
                    if messagesRead > 0 { messagesReadBadge(messagesRead) }
                    AtlasStreamingCursor(color: accent)
                }
                MarkdownText(draft)
                    .textSelection(.enabled)
                    .lineSpacing(4)
            }
            Spacer(minLength: 56)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func messagesReadBadge(_ count: Int) -> some View {
        Label("\(count.formatted()) \(count == 1 ? "message" : "messages") read", systemImage: "text.bubble")
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(accent.opacity(0.10), in: Capsule())
            .fixedSize()
    }

    private var newChatView: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack {
                Spacer()
                reasoningToggle
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text("What do you want to")
                Text("understand?").foregroundStyle(accent)
            }
            .font(.system(size: 50, weight: .regular, design: .serif)).tracking(-1.4)
            Text("Ask about a person, a promise, a recurring dynamic, or how you have changed. Atlas keeps your conversation history here.")
                .font(.title3).foregroundStyle(.secondary).frame(maxWidth: 680, alignment: .leading)
            suggestionChips
            composer
            Spacer()
        }
        .padding(42)
    }

    private var suggestionChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 260, maximum: 370), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(Array(model.suggestions.prefix(2).enumerated()), id: \.element) { index, suggestion in
                    let isHovered = hoveredSuggestion == suggestion
                    Button {
                        model.prompt = suggestion
                        Task { await model.send(responseProfile: responseProfile) }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(accent)
                                .symbolEffect(.pulse, value: isHovered)
                            Text(suggestion)
                                .font(.callout.weight(.medium))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 2)
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isHovered ? accent : Color.secondary.opacity(0.55))
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(
                            accent.opacity(isHovered ? 0.13 : 0.075),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(accent.opacity(isHovered ? 0.30 : 0.14), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .scaleEffect(isHovered ? 1.012 : 1)
                    .offset(y: isHovered ? -2 : 0)
                    .shadow(
                        color: .black.opacity(isHovered ? (colorScheme == .dark ? 0.24 : 0.10) : 0),
                        radius: isHovered ? 12 : 0,
                        y: isHovered ? 5 : 0
                    )
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.18)) {
                            hoveredSuggestion = hovering ? suggestion : nil
                        }
                    }
                    .transition(
                        .offset(y: 10)
                            .combined(with: .scale(scale: 0.97))
                            .combined(with: .opacity)
                    )
                    .animation(
                        .spring(response: 0.48, dampingFraction: 0.84)
                            .delay(Double(index) * 0.07),
                        value: model.suggestions
                    )
                    .disabled(model.isSending)
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Ask Atlas…", text: $model.prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .lineLimit(compactComposer ? 1...4 : 2...6)
                .padding(.vertical, compactComposer ? 2 : 6)
                .onKeyPress(.return, phases: .down) { keyPress in
                    if keyPress.modifiers.contains(.shift) {
                        return .ignored
                    }
                    guard !model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !model.isSending else { return .handled }
                    Task { await model.send(responseProfile: responseProfile) }
                    return .handled
                }
            HStack {
                Spacer()
                Button {
                    if model.isSending {
                        Task { await model.stopSending() }
                    } else {
                        Task { await model.send(responseProfile: responseProfile) }
                    }
                } label: {
                    Label(
                        model.isSending ? "Stop" : "Send",
                        systemImage: model.isSending ? "stop.fill" : "arrow.up"
                    )
                    .frame(minWidth: 62)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(model.isSending ? .red : accent)
                .disabled(model.isSending
                          ? model.sendingChatID == nil
                          : model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(compactComposer ? 12 : 18)
        .background(
            .regularMaterial,
            in: UnevenRoundedRectangle(
                cornerRadii: .init(
                    topLeading: 20,
                    bottomLeading: compactComposer ? 0 : 20,
                    bottomTrailing: compactComposer ? 0 : 20,
                    topTrailing: 20
                ),
                style: .continuous
            )
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.07), radius: 24, y: 8)
    }

    private var reasoningToggle: some View {
        HStack(spacing: 9) {
            Text("Reasoning")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                reasoningOption("Faster", value: "faster")
                reasoningOption("Deeper", value: "deeper")
            }
            .padding(3)
            .background(Color.secondary.opacity(0.10), in: Capsule())
        }
        .fixedSize()
        .disabled(model.isSending)
        .opacity(model.isSending ? 0.58 : 1)
        .help(responseProfile == "faster"
              ? "Prioritizes faster replies"
              : "Uses more time for a deeper read")
    }

    private func reasoningOption(_ title: String, value: String) -> some View {
        let isSelected = responseProfile == value
        return Button {
            withAnimation(.smooth(duration: 0.3)) { responseProfile = value }
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected
                                 ? (colorScheme == .dark ? Color.black.opacity(0.82) : Color.white)
                                 : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(accent)
                            .matchedGeometryEffect(id: "reasoning-selection", in: reasoningToggleAnimation)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var compactComposer: Bool {
        if case .chat = model.selection { return true }
        return false
    }
}

private struct AtlasSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AtlasModel
    @Binding var touchIDEnabled: Bool
    let accent: Color
    let showOnboarding: () -> Void
    @State private var confirmRemoval = false

    private var status: SemanticSearchStatus? { model.semanticSearch }

    private var downloadProgress: Double {
        guard let status, status.total_download_bytes > 0 else { return 0 }
        return min(1, Double(status.downloaded_bytes) / Double(status.total_download_bytes))
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings")
                        .font(.system(size: 30, weight: .medium, design: .serif))
                    Text("Privacy and on-device search")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image(systemName: "touchid")
                            .font(.title2).foregroundStyle(accent)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Require Touch ID").font(.headline)
                            Text("Lock Atlas whenever it leaves the foreground.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $touchIDEnabled)
                            .labelsHidden().toggleStyle(.switch)
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))

                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(.title2).foregroundStyle(accent)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Improve response quality").font(.headline)
                                Text("Help Atlas surface recurring themes, paraphrases, and related moments across years—even when they share no obvious keywords. Downloads 640 MB and runs privately on this Mac.")
                                    .font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        semanticStatusView

                        semanticActions
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))

                    Button("Show onboarding") { showOnboarding() }
                        .buttonStyle(.borderless)
                }
                .padding(24)
            }
        }
        .frame(width: 570, height: 590)
        .task {
            await model.loadSemanticStatus()
            while !Task.isCancelled {
                let active = model.semanticSearch?.text_index_phase == "indexing"
                    || ["downloading", "indexing", "embedding"].contains(model.semanticSearch?.phase ?? "")
                try? await Task.sleep(for: active ? .milliseconds(600) : .seconds(3))
                await model.loadSemanticStatus()
            }
        }
        .alert("Remove enhanced search?", isPresented: $confirmRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                Task { await model.removeSemanticSearch() }
            }
        } message: {
            Text("This deletes the downloaded component and semantic optimization data. Your Messages database is not changed.")
        }
    }

    @ViewBuilder
    private var semanticStatusView: some View {
        if let status {
            switch status.phase {
            case "downloading":
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Downloading…").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(byteCount(status.downloaded_bytes)) of 640 MB")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(value: downloadProgress).tint(accent)
                }
            case "indexing":
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Preparing your message history…")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if status.total_messages > 0 {
                            Text("\(status.indexed_messages.formatted()) of \(status.total_messages.formatted())")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ProgressView(
                        value: status.total_messages > 0
                            ? min(1, Double(status.indexed_messages) / Double(status.total_messages))
                            : 0
                    ).tint(accent)
                    Text("You can keep using Atlas while this finishes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case "embedding":
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Optimizing model…")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(status.eta_seconds.map { atlasETAText($0) } ?? "Computing ETA…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(
                        value: status.total_documents > 0
                            ? min(1, Double(status.embedded_documents) / Double(status.total_documents))
                            : 0
                    ).tint(accent)
                    Text("Fast text search is ready. Related-meaning results will improve as this finishes in the background.")
                        .font(.caption).foregroundStyle(.secondary)
                    if status.preventing_sleep {
                        Label("This Mac will stay awake on power; the display can still turn off.", systemImage: "moon.zzz")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            case "paused":
                VStack(alignment: .leading, spacing: 8) {
                    Label("Optimization paused", systemImage: "pause.circle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    ProgressView(
                        value: status.total_documents > 0
                            ? min(1, Double(status.embedded_documents) / Double(status.total_documents))
                            : 0
                    ).tint(accent)
                    Text(atlasPauseText(status.pause_reason))
                        .font(.caption).foregroundStyle(.secondary)
                }
            case "ready":
                Label("Enhanced search is on", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                Text("\(status.indexed_messages.formatted()) messages prepared · \(byteCount(status.index_bytes)) index")
                    .font(.caption).foregroundStyle(.secondary)
            case "error":
                Label("Enhanced search needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                if let error = status.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            default:
                Label(
                    status.installed ? "Downloaded and off" : "Not downloaded",
                    systemImage: status.installed ? "pause.circle" : "arrow.down.circle"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var semanticActions: some View {
        let isWorking = ["downloading", "indexing", "embedding", "paused"].contains(status?.phase ?? "")
        HStack {
            if status?.phase == "error" {
                Button("Retry") { Task { await model.enableSemanticSearch() } }
                    .buttonStyle(.borderedProminent).tint(accent)
                Button("Turn Off") { Task { await model.disableSemanticSearch() } }
                    .buttonStyle(.bordered)
            } else if status?.enabled == true || isWorking {
                Button("Turn Off") { Task { await model.disableSemanticSearch() } }
                    .buttonStyle(.bordered)
            } else {
                Button(status?.installed == true ? "Enable" : "Download & Enable") {
                    Task { await model.enableSemanticSearch() }
                }
                .buttonStyle(.borderedProminent).tint(accent)
            }
            Spacer()
            if status?.installed == true || (status?.index_bytes ?? 0) > 0 {
                Button("Remove Downloaded Data", role: .destructive) {
                    confirmRemoval = true
                }
                .buttonStyle(.borderless)
                .disabled(isWorking)
            }
        }
    }
}

private struct AtlasThinkingPulse: View {
    let color: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = (sin(time * 4.8 - Double(index) * 0.9) + 1) / 2
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                        .scaleEffect(0.68 + wave * 0.42)
                        .opacity(0.42 + wave * 0.58)
                }
            }
        }
        .frame(width: 30, height: 22)
        .accessibilityLabel("Atlas is working")
    }
}

private struct AtlasStreamingCursor: View {
    let color: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            let pulse = (sin(timeline.date.timeIntervalSinceReferenceDate * 4.4) + 1) / 2
            Capsule()
                .fill(color)
                .frame(width: 13, height: 5)
                .opacity(0.35 + pulse * 0.65)
        }
        .frame(width: 13, height: 7)
        .accessibilityHidden(true)
    }
}

private struct AtlasBrandMark: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let image = NSImage(named: NSImage.Name("AtlasLogo")) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "map.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.22)
                    .background(Color(red: 0.06, green: 0.14, blue: 0.13))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

private struct AtlasOnboardingView: View {
    @ObservedObject var model: AtlasModel
    @Binding var touchIDEnabled: Bool
    let onComplete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var page = 0
    @State private var acceptedDisclosure = false
    @State private var navigationDirection = 1

    private var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.48, green: 0.82, blue: 0.62)
            : Color(red: 0.10, green: 0.38, blue: 0.25)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AtlasBrandMark(size: 38)
                Text("Atlas").font(.system(size: 23, weight: .semibold, design: .serif))
                Spacer()
                Text("SETUP  \(page + 1) OF 5")
                    .font(.caption2.bold()).tracking(1).foregroundStyle(.secondary)
            }
            .padding(.bottom, 26)

            ZStack {
                Group {
                    switch page {
                    case 0: welcomePage
                    case 1: howItWorksPage
                    case 2: disclosurePage
                    case 3: localModelsPage
                    default: permissionsPage
                    }
                }
                .id(page)
                .transition(.asymmetric(
                    insertion: .move(edge: navigationDirection > 0 ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: navigationDirection > 0 ? .leading : .trailing).combined(with: .opacity)
                ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            HStack {
                HStack(spacing: 7) {
                    ForEach(0..<5, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? accent : Color.secondary.opacity(0.2))
                            .frame(width: index == page ? 24 : 7, height: 7)
                    }
                }
                Spacer()
                if page > 0 {
                    Button("Back") {
                        navigationDirection = -1
                        withAnimation(.smooth(duration: 0.36)) { page -= 1 }
                    }
                        .buttonStyle(.bordered).controlSize(.large)
                }
                Button(page == 4 ? (touchIDEnabled ? "Unlock Atlas" : "Open Atlas") : "Continue") {
                    if page < 4 {
                        navigationDirection = 1
                        withAnimation(.smooth(duration: 0.36)) { page += 1 }
                        if page == 4 { Task { await model.checkSetup() } }
                    } else {
                        onComplete()
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(accent)
                .disabled(!canContinue)
            }
            .padding(.top, 24)
        }
        .padding(34)
        .frame(maxWidth: 980, maxHeight: 760)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .padding(34)
        .task {
            async let setup: Void = model.checkSetup()
            async let semantic: Void = model.loadSemanticStatus()
            async let tone: Void = model.enableSentimentAnalysis()
            _ = await (setup, semantic, tone)
            while !Task.isCancelled {
                async let semanticRefresh: Void = model.loadSemanticStatus()
                async let toneRefresh: Void = model.loadSentimentStatus()
                _ = await (semanticRefresh, toneRefresh)
                let working = ["downloading", "preparing", "analyzing", "paused"]
                    .contains(model.sentiment?.phase ?? "")
                    || ["downloading", "indexing", "embedding", "paused"]
                    .contains(model.semanticSearch?.phase ?? "")
                try? await Task.sleep(for: working ? .milliseconds(650) : .seconds(3))
            }
        }
    }

    private var canContinue: Bool {
        if page == 2 { return acceptedDisclosure }
        if page == 3 { return model.sentiment?.installed == true }
        if page == 4 {
            return model.fullDiskAccessReady && model.codexInstalled && model.codexLoggedIn
        }
        return true
    }

    private var welcomePage: some View {
        VStack(spacing: 26) {
            Spacer()
            AtlasBrandMark(size: 92)
            VStack(spacing: 10) {
                Text("Understand the relationships\nin your message history")
                    .font(.system(size: 42, weight: .medium, design: .serif))
                    .multilineTextAlignment(.center)
                Text("Atlas combines a read-only view of Messages with private Codex threads, structured insights, and honest counterevidence.")
                    .font(.title3).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 700)
            }
            HStack(spacing: 14) {
                featureCard("Read-only", icon: "lock.shield", detail: "Cannot send, edit, or delete messages")
                featureCard("Longitudinal", icon: "clock.arrow.circlepath", detail: "Finds patterns across people and years")
                featureCard("Calibrated", icon: "checkmark.seal", detail: "Shows uncertainty and counterevidence")
            }
            Spacer()
        }
    }

    private var howItWorksPage: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 7) {
                Text("How Atlas works")
                    .font(.system(size: 38, weight: .medium, design: .serif))
                Text("Ask naturally. Atlas handles the searching and keeps the answer grounded in what was actually said.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 10) {
                flowNode("You ask", icon: "text.bubble.fill", detail: "A question about a person, promise, or pattern")
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                flowNode("Atlas looks", icon: "magnifyingglass", detail: "Finds the parts of your history that could answer it")
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                flowNode("AI reasons", icon: "sparkles", detail: "Compares evidence, alternatives, and uncertainty")
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                flowNode("You decide", icon: "checkmark.bubble.fill", detail: "Get a clear answer without changing any messages")
            }
            Spacer()
            Label(
                "Atlas can read relevant conversations, but it cannot message anyone, edit your history, or delete anything. The next screen explains what data is sent to OpenAI.",
                systemImage: "lock.shield"
            )
            .font(.callout).foregroundStyle(.secondary)
            .padding(16).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var disclosurePage: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Data disclosure")
                    .font(.system(size: 34, weight: .medium, design: .serif))
                Text("Atlas is local-first, but its analysis is not fully on-device.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "icloud.and.arrow.up.fill")
                    .font(.title3).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected message data is sent to OpenAI").font(.headline)
                    Text("Atlas locally removes common contact, financial, credential, and location identifiers before sending retrieved excerpts. Archive-wide insights can still send substantial redacted samples of private conversations.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 14))

            HStack(alignment: .top, spacing: 12) {
                disclosureColumn(
                    "Stays on this Mac",
                    icon: "internaldrive",
                    items: [
                        "Messages database and attachments",
                        "Atlas history and insight document",
                        "Local access token and original files",
                    ]
                )
                disclosureColumn(
                    "May be sent to OpenAI",
                    icon: "arrow.up.forward.app",
                    items: [
                        "Redacted text, names, dates, and attachment types",
                        "Search results, samples, and aggregates",
                        "Analysis context needed for follow-up questions",
                    ]
                )
            }

            Label {
                Text("Atlas does not upload chat.db or attachment contents. Typed redaction markers replace detected sensitive values, but automated redaction cannot guarantee that every identifying detail is removed.")
                    .font(.caption).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "person.2.shield").foregroundStyle(accent)
            }
            .padding(.horizontal, 2)

            Toggle(isOn: $acceptedDisclosure) {
                Text("I understand that selected private message data will be sent to OpenAI for analysis.")
                    .font(.caption.weight(.semibold))
            }
            .toggleStyle(.checkbox)
            .padding(13)
            .background(acceptedDisclosure ? accent.opacity(0.10) : Color.secondary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 13))
        }
    }

    private var localModelsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("On-device analysis")
                    .font(.system(size: 36, weight: .medium, design: .serif))
                Text("Atlas downloads private local components for better evidence. Message text stays on this Mac while they run.")
                    .font(.title3).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.title2).foregroundStyle(accent).frame(width: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Conversational tone").font(.headline)
                        Text("Measures positive, neutral, and negative tone across speaker turns and short exchanges. About 130 MB.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if model.sentiment?.installed == true {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                    }
                }

                if let tone = model.sentiment {
                    if tone.phase == "downloading" {
                        HStack {
                            Text("Downloading…").font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(onboardingByteCount(tone.downloaded_bytes)) of 130 MB")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ProgressView(
                            value: tone.total_download_bytes > 0
                                ? min(1, Double(tone.downloaded_bytes) / Double(tone.total_download_bytes))
                                : 0
                        ).tint(accent)
                    } else if tone.phase == "error" {
                        HStack {
                            Label(tone.error ?? "Download needs attention", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange).lineLimit(2)
                            Spacer()
                            Button("Retry") { Task { await model.enableSentimentAnalysis() } }
                                .buttonStyle(.bordered)
                        }
                    } else if tone.installed {
                        Text("Analysis starts after Atlas finishes preparing its private text index.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text("Preparing download…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(19)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))

            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.title2).foregroundStyle(accent).frame(width: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Improve response quality").font(.headline)
                        Text("Help Atlas surface recurring themes, paraphrases, and related moments across years—even when they share no obvious keywords. Downloads 640 MB and runs privately on this Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.semanticSearch?.enabled == true },
                        set: { enabled in
                            Task {
                                if enabled { await model.enableSemanticSearch() }
                                else { await model.disableSemanticSearch() }
                            }
                        }
                    ))
                    .labelsHidden().toggleStyle(.switch)
                }

                if let semantic = model.semanticSearch, semantic.enabled {
                    if semantic.phase == "downloading" {
                        HStack {
                            Text("Downloading…").font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(onboardingByteCount(semantic.downloaded_bytes)) of 640 MB")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ProgressView(
                            value: semantic.total_download_bytes > 0
                                ? min(1, Double(semantic.downloaded_bytes) / Double(semantic.total_download_bytes))
                                : 0
                        ).tint(accent)
                    } else if semantic.phase == "error" {
                        Text(semantic.error ?? "Enhanced retrieval needs attention")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Label(semantic.installed ? "Downloaded" : "Selected—download will continue in the background",
                              systemImage: semantic.installed ? "checkmark.circle" : "arrow.down.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Optional. You can enable this later in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(19)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))

            Label("Both components run locally. Atlas verifies every downloaded file before loading it.",
                  systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 3)
        }
    }

    private func onboardingByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Finish setup")
                    .font(.system(size: 38, weight: .medium, design: .serif))
                Text("Atlas needs local Messages access, Codex, and a signed-in OpenAI account.")
                    .font(.title3).foregroundStyle(.secondary)
            }

            setupRow(
                title: "Full Disk Access",
                detail: "Required for the background Node service to open ~/Library/Messages/chat.db read-only.",
                ready: model.fullDiskAccessReady,
                readyText: "Messages accessible",
                missingText: "Permission required"
            ) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            } actionLabel: {
                "Open Settings"
            }

            setupRow(
                title: "Codex CLI",
                detail: "Atlas uses the official Codex runtime with response profiles configured for this app.",
                ready: model.codexInstalled,
                readyText: "Installed",
                missingText: "Not found"
            ) {
                copyCommandAndOpenTerminal(model.codexInstallCommand)
            } actionLabel: {
                "Install in Terminal"
            }

            setupRow(
                title: "OpenAI sign-in",
                detail: "Codex opens a browser sign-in flow and uses the account or workspace you choose.",
                ready: model.codexLoggedIn,
                readyText: "Codex signed in",
                missingText: "Sign-in required"
            ) {
                copyCommandAndOpenTerminal(model.codexLoginCommand)
            } actionLabel: {
                "Sign in with Codex"
            }

            HStack(spacing: 14) {
                Image(systemName: "touchid").font(.title2).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Require Touch ID").font(.headline)
                    Text("When enabled, Atlas locks whenever it leaves the foreground. You can change this later in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $touchIDEnabled).labelsHidden().toggleStyle(.switch)
            }
            .padding(17).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

            HStack {
                Text(touchIDEnabled ? "Touch ID will be requested when setup finishes." : "Atlas will open without biometric authentication.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Recheck") { Task { await model.checkSetup() } }
                    .buttonStyle(.bordered)
            }

            if !canContinue {
                Text("Complete the checks above, then select Recheck.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func featureCard(_ title: String, icon: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: icon).font(.title2).foregroundStyle(accent)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(17).frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func flowNode(_ title: String, icon: String, detail: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.title2).foregroundStyle(accent)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(14).frame(maxWidth: .infinity, minHeight: 130)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func disclosureColumn(_ title: String, icon: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.subheadline.bold()).foregroundStyle(accent)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(accent.opacity(0.7)).frame(width: 4, height: 4).padding(.top, 5)
                    Text(item).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(13).frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
    }

    private func setupRow(
        title: String,
        detail: String,
        ready: Bool,
        readyText: String,
        missingText: String,
        action: @escaping () -> Void,
        actionLabel: () -> String
    ) -> some View {
        HStack(spacing: 15) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2).foregroundStyle(ready ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    Text(ready ? readyText.uppercased() : missingText.uppercased())
                        .font(.system(size: 8, weight: .bold)).tracking(0.7)
                        .foregroundStyle(ready ? .green : .orange)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background((ready ? Color.green : Color.orange).opacity(0.10), in: Capsule())
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ready {
                Button(actionLabel(), action: action).buttonStyle(.borderedProminent).tint(accent)
            }
        }
        .padding(17).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func copyCommandAndOpenTerminal(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(
            at: terminal,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }
}

private struct MarkdownText: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    init(_ source: String) { self.source = source }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let text, let level):
            inlineText(text)
                .font(level == 1 ? .title2.weight(.semibold) : .headline)
                .padding(.top, level == 1 ? 4 : 2)
        case .paragraph(let text):
            inlineText(text)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(Color.secondary.opacity(0.75))
                    .frame(width: 5, height: 5)
                inlineText(text)
            }
            .padding(.leading, 3)
        case .numbered(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(marker)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20, alignment: .trailing)
                inlineText(text)
            }
        }
    }

    private func inlineText(_ value: String) -> Text {
        let parts = value.components(separatedBy: "==")
        var combined = AttributedString()
        for (index, part) in parts.enumerated() {
            let isHighlight = index.isMultiple(of: 2) == false && index < parts.count - 1
            let visiblePart = index.isMultiple(of: 2) == false && !isHighlight
                ? "==\(part)"
                : part
            var attributed = (try? AttributedString(
                markdown: visiblePart,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(visiblePart)
            if isHighlight {
                attributed.backgroundColor = colorScheme == .dark
                    ? Color.yellow.opacity(0.24)
                    : Color.yellow.opacity(0.32)
                attributed.foregroundColor = colorScheme == .dark
                    ? Color.yellow.opacity(0.96)
                    : Color(red: 0.34, green: 0.24, blue: 0.02)
                attributed.font = .body.weight(.semibold)
            }
            combined.append(attributed)
        }
        return Text(combined)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll(keepingCapacity: true)
        }

        for rawLine in displaySource.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                continue
            }

            if line.hasPrefix("### ") {
                flushParagraph()
                result.append(.heading(String(line.dropFirst(4)), 3))
            } else if line.hasPrefix("## ") {
                flushParagraph()
                result.append(.heading(String(line.dropFirst(3)), 2))
            } else if line.hasPrefix("# ") {
                flushParagraph()
                result.append(.heading(String(line.dropFirst(2)), 1))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flushParagraph()
                result.append(.bullet(String(line.dropFirst(2))))
            } else if let numbered = numberedLine(line) {
                flushParagraph()
                result.append(.numbered(numbered.marker, numbered.text))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return result
    }

    private var displaySource: String {
        guard let expression = try? NSRegularExpression(pattern: "([.!?])(?=[A-Z][a-z])") else {
            return source
        }
        return expression.stringByReplacingMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source),
            withTemplate: "$1 "
        )
    }

    private func numberedLine(_ line: String) -> (marker: String, text: String)? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let number = line[..<dot]
        guard !number.isEmpty, number.allSatisfy({ $0.isNumber }) else { return nil }
        let afterDot = line.index(after: dot)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        let textStart = line.index(after: afterDot)
        return ("\(number).", String(line[textStart...]))
    }

    private enum Block {
        case heading(String, Int)
        case paragraph(String)
        case bullet(String)
        case numbered(String, String)
    }
}

private extension String {
    var atlasUpdatedLabel: String {
        guard let date = ISO8601DateFormatter().date(from: self) else { return "Updated recently" }
        if Calendar.current.isDateInToday(date) { return "Updated today" }
        if Calendar.current.isDateInYesterday(date) { return "Updated yesterday" }
        return "Updated \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }
}

@main
struct AtlasApp: App {
    var body: some Scene {
        WindowGroup { AtlasView() }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1080, height: 760)
    }
}
