import Foundation
import llama

final class EmbeddingEngine: @unchecked Sendable {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var dimensions = 0
    private let lock = NSLock()
    private let cancellation: EmbeddingCancellation

    init(modelPath: URL, cancellation: EmbeddingCancellation = EmbeddingCancellation()) throws {
        self.cancellation = cancellation
        llama_backend_init()
        var modelParameters = llama_model_default_params()
        modelParameters.n_gpu_layers = -1
        let cancellationPointer = Unmanaged.passUnretained(cancellation).toOpaque()
        modelParameters.progress_callback = { _, pointer in
            guard let pointer else { return true }
            return !Unmanaged<EmbeddingCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled
        }
        modelParameters.progress_callback_user_data = cancellationPointer
        guard let model = modelPath.path.withCString({ llama_model_load_from_file($0, modelParameters) }) else {
            if cancellation.isCancelled { throw CancellationError() }
            throw EmbeddingError.loadModel
        }
        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = 2_048
        contextParameters.n_batch = 2_048
        contextParameters.n_ubatch = 2_048
        contextParameters.n_seq_max = 1
        contextParameters.embeddings = true
        contextParameters.pooling_type = LLAMA_POOLING_TYPE_LAST
        guard let context = llama_init_from_model(model, contextParameters) else {
            llama_model_free(model)
            throw EmbeddingError.createContext
        }
        self.model = model
        self.context = context
        llama_set_abort_callback(context, { pointer in
            guard let pointer else { return false }
            return Unmanaged<EmbeddingCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled
        }, cancellationPointer)
        dimensions = Int(llama_model_n_embd(model))
        cancellation.reset()
    }

    deinit {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    func embedding(for text: String, query: Bool = false) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        cancellation.reset()
        guard let model, let context, let vocabulary = llama_model_get_vocab(model) else { throw EmbeddingError.closed }
        let input = query ? "Instruct: Retrieve messages that answer or relate to this question\nQuery: \(text)" : text
        var tokens: [llama_token] = try input.withCString { pointer in
            let length = Int32(strlen(pointer))
            let needed = llama_tokenize(vocabulary, pointer, length, nil, 0, true, true)
            guard needed < 0, needed != Int32.min else { throw EmbeddingError.tokenize }
            var tokens = [llama_token](repeating: 0, count: Int(-needed))
            let count = llama_tokenize(vocabulary, pointer, length, &tokens, Int32(tokens.count), true, true)
            guard count > 0 else { throw EmbeddingError.tokenize }
            return Array(tokens.prefix(Int(count)).prefix(2_040))
        }
        let result = tokens.withUnsafeMutableBufferPointer { pointer -> Int32 in
            let batch = llama_batch_get_one(pointer.baseAddress, Int32(pointer.count))
            return llama_encode(context, batch)
        }
        if cancellation.isCancelled { throw CancellationError() }
        guard result == 0, let raw = llama_get_embeddings_seq(context, 0) ?? llama_get_embeddings(context) else {
            throw EmbeddingError.inference
        }
        let count = min(384, dimensions)
        var values = Array(UnsafeBufferPointer(start: raw, count: count))
        let length = sqrt(values.reduce(0) { $0 + $1 * $1 })
        if length > 0 { for index in values.indices { values[index] /= length } }
        if values.count < 384 { values += [Float](repeating: 0, count: 384 - values.count) }
        return values.withUnsafeBytes { Data($0) }
    }

    func cancelActiveWork() { cancellation.cancel() }
}

final class EmbeddingCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func reset() { lock.withLock { cancelled = false } }
}

enum EmbeddingError: Error, LocalizedError {
    case loadModel, createContext, tokenize, inference, closed
    var errorDescription: String? {
        switch self {
        case .loadModel: return "Atlas couldn't load the local search model"
        case .createContext: return "Atlas couldn't prepare the local search model"
        case .tokenize: return "Atlas couldn't tokenize text for local search"
        case .inference: return "Atlas couldn't compute a local embedding"
        case .closed: return "The local embedding engine is closed"
        }
    }
}
