import Foundation
import NaturalLanguage

enum KnowledgeEmbedder {
    static func embed(_ text: String) -> [Float]? {
        guard let model = NLEmbedding.sentenceEmbedding(for: .english) else {
            return nil
        }
        guard let vector = model.vector(for: text) else {
            return nil
        }
        return vector.map { Float($0) }
    }

    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Float = 0
        var lNorm: Float = 0
        var rNorm: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lNorm += lhs[index] * lhs[index]
            rNorm += rhs[index] * rhs[index]
        }
        let denom = (lNorm.squareRoot() * rNorm.squareRoot())
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    static func embeddingData(from vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    static func vector(from data: Data) -> [Float]? {
        guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Float>.size) else {
            return nil
        }
        return data.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: Float.self)
            return Array(buffer)
        }
    }
}
