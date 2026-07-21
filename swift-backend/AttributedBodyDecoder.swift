import Foundation

enum AttributedBodyDecoder {
    static func decode(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        let object = NSUnarchiver.unarchiveObject(with: data)
        if let attributed = object as? NSAttributedString { return attributed.string }
        if let string = object as? String { return string }
        if let dictionary = object as? [AnyHashable: Any] {
            return firstText(in: dictionary)
        }
        return nil
    }

    private static func firstText(in value: Any) -> String? {
        if let attributed = value as? NSAttributedString { return attributed.string }
        if let string = value as? String, !string.isEmpty { return string }
        if let array = value as? [Any] {
            return array.lazy.compactMap(firstText).first
        }
        if let dictionary = value as? [AnyHashable: Any] {
            return dictionary.values.lazy.compactMap(firstText).first
        }
        return nil
    }
}
