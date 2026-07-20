import CoreML
import Foundation

private struct Request: Decodable {
    let input_ids: [Int32]
    let attention_mask: [Int32]
}

private struct Response: Encodable {
    let embedding: [Double]?
    let error: String?
}

@main
private enum EmbeddingCoreMLBenchmarkRunner {
    static func emit(_ response: Response, encoder: JSONEncoder) {
        guard let data = try? encoder.encode(response),
              let line = String(data: data, encoding: .utf8) else { return }
        FileHandle.standardOutput.write(Data("\(line)\n".utf8))
    }

    static func main() {
        let encoder = JSONEncoder()
        guard CommandLine.arguments.count == 2 else {
            emit(Response(embedding: nil, error: "Expected a compiled Core ML model path"), encoder: encoder)
            return
        }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let model = try MLModel(
                contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]),
                configuration: configuration
            )
            emit(Response(embedding: [], error: nil), encoder: encoder)
            while let line = readLine() {
                autoreleasepool {
                    do {
                        let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
                        guard request.input_ids.count == 512, request.attention_mask.count == 512 else {
                            throw NSError(domain: "AtlasEmbeddingCoreML", code: 1, userInfo: [
                                NSLocalizedDescriptionKey: "Invalid embedding tensor shape",
                            ])
                        }
                        let shape = [NSNumber(value: 1), NSNumber(value: 512)]
                        let ids = try MLMultiArray(shape: shape, dataType: .int32)
                        let mask = try MLMultiArray(shape: shape, dataType: .int32)
                        request.input_ids.withUnsafeBufferPointer { source in
                            ids.dataPointer.bindMemory(to: Int32.self, capacity: 512)
                                .update(from: source.baseAddress!, count: 512)
                        }
                        request.attention_mask.withUnsafeBufferPointer { source in
                            mask.dataPointer.bindMemory(to: Int32.self, capacity: 512)
                                .update(from: source.baseAddress!, count: 512)
                        }
                        let provider = try MLDictionaryFeatureProvider(dictionary: [
                            "input_ids": MLFeatureValue(multiArray: ids),
                            "attention_mask": MLFeatureValue(multiArray: mask),
                        ])
                        let output = try model.prediction(from: provider)
                        guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue else {
                            throw NSError(domain: "AtlasEmbeddingCoreML", code: 2, userInfo: [
                                NSLocalizedDescriptionKey: "Embedding model returned no vector",
                            ])
                        }
                        var values: [Double] = []
                        values.reserveCapacity(embedding.count)
                        for index in 0..<embedding.count { values.append(embedding[index].doubleValue) }
                        emit(Response(embedding: values, error: nil), encoder: encoder)
                    } catch {
                        emit(Response(embedding: nil, error: error.localizedDescription), encoder: encoder)
                    }
                }
            }
        } catch {
            emit(Response(embedding: nil, error: error.localizedDescription), encoder: encoder)
        }
    }
}
