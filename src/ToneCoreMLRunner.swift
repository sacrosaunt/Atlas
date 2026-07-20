import CoreML
import Foundation

private struct Request: Decodable {
    let sequence_length: Int
    let batch_count: Int
    let input_ids: [Int32]
    let attention_mask: [Int32]
}

private struct Response: Encodable {
    let logits: [Double]?
    let batch_count: Int?
    let error: String?
}

private final class Runner {
    private let compiledURL: URL
    private var models: [Int: MLModel] = [:]

    init(packagePath: String) throws {
        compiledURL = try MLModel.compileModel(at: URL(fileURLWithPath: packagePath))
    }

    private func model(sequenceLength: Int) throws -> MLModel {
        if let existing = models[sequenceLength] { return existing }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        configuration.functionName = "tone_b8_s\(sequenceLength)"
        let loaded = try MLModel(contentsOf: compiledURL, configuration: configuration)
        models[sequenceLength] = loaded
        return loaded
    }

    func predict(_ request: Request) throws -> Response {
        let requestBatchSize = 24
        let modelBatchSize = 8
        let elementCount = requestBatchSize * request.sequence_length
        guard [32, 64, 128, 256, 512].contains(request.sequence_length),
              request.batch_count > 0,
              request.batch_count <= requestBatchSize,
              request.input_ids.count == elementCount,
              request.attention_mask.count == elementCount else {
            throw NSError(domain: "AtlasToneCoreML", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid tone inference tensor shape",
            ])
        }

        var logits: [Double] = []
        logits.reserveCapacity(request.batch_count * 3)
        let shape = [NSNumber(value: modelBatchSize), NSNumber(value: request.sequence_length)]
        for batchOffset in stride(from: 0, to: request.batch_count, by: modelBatchSize) {
            let ids = try MLMultiArray(shape: shape, dataType: .int32)
            let mask = try MLMultiArray(shape: shape, dataType: .int32)
            let sourceOffset = batchOffset * request.sequence_length
            let chunkElements = modelBatchSize * request.sequence_length
            request.input_ids.withUnsafeBufferPointer { source in
                ids.dataPointer.bindMemory(to: Int32.self, capacity: chunkElements)
                    .update(from: source.baseAddress!.advanced(by: sourceOffset), count: chunkElements)
            }
            request.attention_mask.withUnsafeBufferPointer { source in
                mask.dataPointer.bindMemory(to: Int32.self, capacity: chunkElements)
                    .update(from: source.baseAddress!.advanced(by: sourceOffset), count: chunkElements)
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: ids),
                "attention_mask": MLFeatureValue(multiArray: mask),
            ])
            let prediction = try model(sequenceLength: request.sequence_length).prediction(from: provider)
            guard let output = prediction.featureValue(for: "logits")?.multiArrayValue else {
                throw NSError(domain: "AtlasToneCoreML", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Tone model did not return logits",
                ])
            }
            let rows = min(modelBatchSize, request.batch_count - batchOffset)
            for index in 0..<(rows * 3) {
                logits.append(output[index].doubleValue)
            }
        }
        return Response(logits: logits, batch_count: request.batch_count, error: nil)
    }
}

private func emit(_ response: Response, encoder: JSONEncoder) {
    guard let data = try? encoder.encode(response),
          let line = String(data: data, encoding: .utf8) else { return }
    FileHandle.standardOutput.write(Data("\(line)\n".utf8))
}

@main
private enum ToneCoreMLRunner {
    static func main() {
        let encoder = JSONEncoder()
        guard CommandLine.arguments.count == 2 else {
            emit(Response(logits: nil, batch_count: nil, error: "Expected a Core ML package path"), encoder: encoder)
            return
        }
        do {
            let runner = try Runner(packagePath: CommandLine.arguments[1])
            emit(Response(logits: [], batch_count: 0, error: nil), encoder: encoder)
            while let line = readLine() {
                autoreleasepool {
                    do {
                        let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
                        emit(try runner.predict(request), encoder: encoder)
                    } catch {
                        emit(Response(logits: nil, batch_count: nil, error: error.localizedDescription), encoder: encoder)
                    }
                }
            }
        } catch {
            emit(Response(logits: nil, batch_count: nil, error: error.localizedDescription), encoder: encoder)
        }
    }
}
