import Foundation

struct CodexSetup: Sendable {
    let path: String?
    let loggedIn: Bool
}

enum CodexDiscovery {
    static func status(checkLogin: Bool) -> CodexSetup {
        guard let path = resolve() else { return .init(path: nil, loggedIn: false) }
        return .init(path: path, loggedIn: checkLogin && run(path, arguments: ["login", "status"], timeout: 5))
    }

    static func resolve() -> String? {
        var candidates: [String] = []
        if let configured = ProcessInfo.processInfo.environment["CODEX_CLI_PATH"], !configured.isEmpty {
            candidates.append(configured)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += path.split(separator: ":").map { "\($0)/codex" }
        candidates += [
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.volta/bin/codex",
            "\(home)/.asdf/shims/codex",
            "\(home)/.local/share/mise/shims/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            candidates += versions.sorted(by: >).map { "\(nvmRoot)/\($0)/bin/codex" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }
}
