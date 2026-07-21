import Foundation
import Security

enum AtlasSecurity {
    static let disclosureVersion = 1

    static func loadOrCreateSecret(at url: URL) throws -> String {
        if let value = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        let value = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try writePrivate(Data("\(value)\n".utf8), to: url)
        return value
    }

    static func consentAccepted(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONDecoder().decode(JSONValue.self, from: data),
              object["accepted"]?.boolValue == true,
              object["disclosure_version"]?.intValue == disclosureVersion else { return false }
        return true
    }

    static func saveConsent(at url: URL) throws {
        let value: JSONValue = .object([
            "accepted": .bool(true),
            "disclosure_version": .number(Double(disclosureVersion)),
            "accepted_at": .string(atlasNow()),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0a)
        try writePrivate(data, to: url)
    }

    static func constantTimeEquals(_ left: String, _ right: String) -> Bool {
        let lhs = Array(left.utf8)
        let rhs = Array(right.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
