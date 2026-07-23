import Foundation

struct AtlasPaths: Sendable {
    let home: URL
    let support: URL
    let codexHome: URL
    let codexWorkspace: URL
    let token: URL
    let identityKey: URL
    let consent: URL
    let calendarSnapshot: URL
    let starterSuggestions: URL
    let historyDatabase: URL
    let messagesDatabase: URL
    let semanticDirectory: URL
    let toneDirectory: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        support = home.appending(path: "Library/Application Support/Atlas", directoryHint: .isDirectory)
        codexHome = support.appending(path: "CodexHome", directoryHint: .isDirectory)
        codexWorkspace = support.appending(path: "CodexWorkspace", directoryHint: .isDirectory)
        token = support.appending(path: "mcp-token")
        identityKey = support.appending(path: "identity-key")
        consent = support.appending(path: "consent.json")
        calendarSnapshot = support.appending(path: "calendar-events.json")
        starterSuggestions = support.appending(path: "starter-suggestions.json")
        historyDatabase = support.appending(path: "atlas.sqlite")
        messagesDatabase = home.appending(path: "Library/Messages/chat.db")
        semanticDirectory = support.appending(path: "SemanticSearch", directoryHint: .isDirectory)
        toneDirectory = support.appending(path: "Sentiment", directoryHint: .isDirectory)
    }

    func prepare() throws {
        for directory in [support, codexHome, codexWorkspace, semanticDirectory, toneDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let retiredEmptyHistory = support.appending(path: "history.sqlite")
        if ((try? FileManager.default.attributesOfItem(atPath: retiredEmptyHistory.path)[.size] as? NSNumber)?.int64Value ?? -1) == 0 {
            try? FileManager.default.removeItem(at: retiredEmptyHistory)
        }
    }
}
