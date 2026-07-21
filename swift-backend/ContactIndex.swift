import Foundation

struct ContactProfile: Sendable {
    let name: String?
    let nickname: String?
    let company: String?
    let jobTitle: String?
    let department: String?

    var searchableValues: [String] { [name, nickname, company, jobTitle, department].compactMap { $0 } }
}

final class ContactIndex: @unchecked Sendable {
    private var profiles: [String: ContactProfile] = [:]
    private let lock = NSLock()

    init(home: URL) {
        load(root: home.appending(path: "Library/Application Support/AddressBook", directoryHint: .isDirectory))
    }

    func profile(for identifier: String) -> ContactProfile? {
        lock.withLock { profiles[normalize(identifier)] }
    }

    func matches(_ identifier: String, query: String) -> Bool {
        guard let profile = profile(for: identifier) else { return false }
        let needle = query.lowercased()
        return profile.searchableValues.contains { $0.lowercased().contains(needle) }
    }

    private func load(root: URL) {
        var paths = [root.appending(path: "AddressBook-v22.abcddb")]
        let sources = root.appending(path: "Sources", directoryHint: .isDirectory)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: sources,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            paths += entries.map { $0.appending(path: "AddressBook-v22.abcddb") }
        }
        for path in paths where FileManager.default.fileExists(atPath: path.path) {
            load(databasePath: path.path)
        }
    }

    private func load(databasePath: String) {
        do {
            let database = try SQLiteDatabase(path: databasePath, readOnly: true)
            let recordColumns = Set(try database.query("PRAGMA table_info(ZABCDRECORD)").compactMap { $0["name"]?.string })
            func optional(_ column: String, _ alias: String) -> String {
                recordColumns.contains(column) ? "\(column) AS \(alias)" : "NULL AS \(alias)"
            }
            var people: [Int: ContactProfile] = [:]
            for row in try database.query("""
            SELECT Z_PK AS id, ZFIRSTNAME AS first_name, ZLASTNAME AS last_name,
                   \(optional("ZNICKNAME", "nickname")),
                   \(optional("ZORGANIZATION", "organization")),
                   \(optional("ZJOBTITLE", "job_title")),
                   \(optional("ZDEPARTMENT", "department"))
            FROM ZABCDRECORD
            """) {
                guard let id = row["id"]?.int else { continue }
                let fullName = [row["first_name"]?.string, row["last_name"]?.string]
                    .compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                let nickname = row["nickname"]?.string
                let organization = row["organization"]?.string
                people[id] = .init(
                    name: fullName.isEmpty ? nickname ?? organization : fullName,
                    nickname: nickname,
                    company: organization,
                    jobTitle: row["job_title"]?.string,
                    department: row["department"]?.string
                )
            }
            for (table, valueColumn) in [("ZABCDPHONENUMBER", "ZFULLNUMBER"), ("ZABCDEMAILADDRESS", "ZADDRESS")] {
                let columns = Set(try database.query("PRAGMA table_info(\(table))").compactMap { $0["name"]?.string })
                let owner: String?
                if columns.contains("ZOWNER") && columns.contains("Z22_OWNER") {
                    owner = "COALESCE(v.ZOWNER, v.Z22_OWNER)"
                } else if columns.contains("ZOWNER") { owner = "v.ZOWNER" }
                else if columns.contains("Z22_OWNER") { owner = "v.Z22_OWNER" }
                else { owner = nil }
                guard let owner, columns.contains(valueColumn) else { continue }
                for row in try database.query("""
                SELECT \(owner) AS owner_id, v.\(valueColumn) AS value FROM \(table) v
                WHERE v.\(valueColumn) IS NOT NULL
                """) {
                    guard let ownerID = row["owner_id"]?.int,
                          let value = row["value"]?.string,
                          let profile = people[ownerID], profile.name != nil else { continue }
                    let key = normalize(value)
                    guard !key.isEmpty else { continue }
                    lock.withLock { if profiles[key] == nil { profiles[key] = profile } }
                }
            }
        } catch {
            // Contacts enrich results but never block read-only Messages access.
        }
    }

    private func normalize(_ value: String) -> String {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.contains("@") else { return raw }
        let digits = raw.filter(\.isNumber)
        return digits.count == 10 ? "1\(digits)" : digits
    }
}
