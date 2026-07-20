import Foundation

private struct DecodeRequest: Decodable {
    let bodies: [String?]
}

private struct DecodeResponse: Encodable {
    let texts: [String?]
}

private func decodeBody(_ encoded: String?) -> String? {
    guard let encoded, let data = Data(base64Encoded: encoded), !data.isEmpty else {
        return nil
    }

    let object = NSUnarchiver.unarchiveObject(with: data)

    if let attributed = object as? NSAttributedString {
        return attributed.string
    }
    if let string = object as? NSString {
        return string as String
    }
    return nil
}

do {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let request = try JSONDecoder().decode(DecodeRequest.self, from: input)
    let response = DecodeResponse(texts: request.bodies.map(decodeBody))
    let output = try JSONEncoder().encode(response)
    FileHandle.standardOutput.write(output)
} catch {
    let message = "AttributedBody decoder failed: \(error)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}
