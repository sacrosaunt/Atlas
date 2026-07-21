import Foundation

enum PrivacyRedaction {
    struct Summary: Codable, Sendable {
        let total: Int
        let categories: [String]
    }

    struct Sanitized: Sendable {
        let value: JSONValue
        let summary: Summary
    }

    private struct Pattern: @unchecked Sendable {
        let expression: NSRegularExpression
        let category: String
        let validator: (@Sendable (String) -> Bool)?
    }

    private static let patterns: [Pattern] = [
        pattern(#"\b(?:https?://|www\.)[^\s<>\"']+"#, "link"),
        pattern(#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "email address", insensitive: true),
        pattern(#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#, "access token"),
        pattern(#"\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[A-Z0-9]{16})\b"#, "access token"),
        pattern(#"\b(?:password|passcode|verification\s+code|one[- ]time\s+(?:password|code)|otp|security\s+code|pin)\s*(?:is|:|=)\s*[\"']?[^\s,\"']{4,128}[\"']?"#, "credential", insensitive: true),
        pattern(#"\b\d{3}-\d{2}-\d{4}\b"#, "government identifier"),
        pattern(#"\b(?:passport|driver'?s?\s+license|license|tax\s+id)\s*(?:number|no\.?|#)?\s*(?:is|:|=)?\s*[A-Z0-9-]{5,24}\b"#, "government identifier", insensitive: true),
        pattern(#"\b(?:\d[ -]?){12,18}\d\b"#, "payment card", validator: luhnValid),
        pattern(#"\b(?:routing|aba)\s*(?:number|no\.?|#)?\s*(?:is|:|=)?\s*\d{9}\b"#, "bank identifier", insensitive: true),
        pattern(#"\b(?:account|acct)\s*(?:number|no\.?|#)\s*(?:is|:|=)?\s*[A-Z0-9-]{6,24}\b"#, "bank identifier", insensitive: true),
        pattern(#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "IP address", validator: validIPv4),
        pattern(#"(?<![\d.])-?(?:[1-8]?\d(?:\.\d{4,})|90(?:\.0+)?)[,\s]+-?(?:1[0-7]\d(?:\.\d{4,})|(?:\d?\d)(?:\.\d{4,})|180(?:\.0+)?)(?![\d.])"#, "precise location"),
        pattern(#"\bP\.?\s*O\.?\s+Box\s+\d+[A-Z]?\b"#, "postal address", insensitive: true),
        pattern(#"\b\d{1,6}\s+(?:(?:N|S|E|W|NE|NW|SE|SW)\.?\s+)?(?:[\p{L}0-9.'’-]+\s+){1,7}(?:Street|St\.?|Road|Rd\.?|Avenue|Ave\.?|Boulevard|Blvd\.?|Lane|Ln\.?|Drive|Dr\.?|Court|Ct\.?|Circle|Cir\.?|Highway|Hwy\.?|Parkway|Pkwy\.?|Place|Pl\.?|Terrace|Ter\.?)(?:\s+(?:Apt\.?|Apartment|Unit|Suite|Ste\.?)\s*[A-Z0-9-]+)?\b"#, "street address", insensitive: true),
        pattern(#"\b(?:date\s+of\s+birth|dob)\s*(?:is|:|=)?\s*(?:\d{1,2}[\/-]){2}\d{2,4}\b"#, "birth date", insensitive: true),
        pattern(#"(?:\+?\d[\d().\-\s]{5,}\d)"#, "phone number", validator: validPhoneCandidate),
    ]

    static func redact(_ text: String, counts: inout [String: Int]) -> String {
        var output = text
        for item in patterns {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            let matches = item.expression.matches(in: output, range: range).reversed()
            for match in matches {
                guard let swiftRange = Range(match.range, in: output) else { continue }
                let candidate = String(output[swiftRange])
                if let validator = item.validator, !validator(candidate) { continue }
                output.replaceSubrange(swiftRange, with: token(item.category))
                counts[item.category, default: 0] += 1
            }
        }
        return output
    }

    static func redact(_ text: String) -> String {
        var counts: [String: Int] = [:]
        return redact(text, counts: &counts)
    }

    static func sanitize(_ value: JSONValue) -> Sanitized {
        var counts: [String: Int] = [:]
        func walk(_ value: JSONValue) -> JSONValue {
            switch value {
            case .string(let string): return .string(redact(string, counts: &counts))
            case .array(let values): return .array(values.map(walk))
            case .object(let object): return .object(object.mapValues(walk))
            default: return value
            }
        }
        return .init(
            value: walk(value),
            summary: .init(total: counts.values.reduce(0, +), categories: counts.keys.sorted())
        )
    }

    static func privateAttachmentName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let extensionPattern = try! NSRegularExpression(pattern: #"\.[A-Za-z0-9]{1,10}$"#)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = extensionPattern.firstMatch(in: value, range: range),
              let swiftRange = Range(match.range, in: value) else { return "[attachment]" }
        return "[attachment]\(value[swiftRange].lowercased())"
    }

    private static func token(_ category: String) -> String { "[redacted: \(category)]" }

    private static func pattern(
        _ value: String,
        _ category: String,
        insensitive: Bool = false,
        validator: (@Sendable (String) -> Bool)? = nil
    ) -> Pattern {
        Pattern(
            expression: try! NSRegularExpression(
                pattern: value,
                options: insensitive ? [.caseInsensitive] : []
            ),
            category: category,
            validator: validator
        )
    }

    private static func validIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts.allSatisfy { (0...255).contains($0) }
    }

    private static func validPhoneCandidate(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return false }
        return trimmed.filter(\.isNumber).count >= 7
    }

    private static func luhnValid(_ value: String) -> Bool {
        let digits = value.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count), Set(digits).count > 1 else { return false }
        var sum = 0
        for (offset, original) in digits.reversed().enumerated() {
            var digit = original
            if offset % 2 == 1 { digit *= 2; if digit > 9 { digit -= 9 } }
            sum += digit
        }
        return sum % 10 == 0
    }
}
