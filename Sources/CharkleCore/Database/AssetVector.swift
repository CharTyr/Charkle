import Foundation

public nonisolated enum EmbeddingPrecision: Int, Codable, Sendable {
    case float16 = 16
    case float32 = 32

    func encode(_ values: [Float]) -> Data {
        switch self {
        case .float16:
            let bits = values.map { Float16($0).bitPattern.littleEndian }
            return bits.withUnsafeBytes { Data($0) }
        case .float32:
            let bits = values.map { $0.bitPattern.littleEndian }
            return bits.withUnsafeBytes { Data($0) }
        }
    }

    func decode(_ bytes: Data) -> [Float] {
        bytes.withUnsafeBytes { raw in
            let count = raw.count / (rawValue / 8)
            return switch self {
            case .float16:
                (0..<count).map { Float(Float16(bitPattern: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)))) }
            case .float32:
                (0..<count).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
            }
        }
    }
}

public nonisolated struct AssetVector: Codable, Hashable, Sendable {
    public var featurePrint: Data?
    public var embedding: [Float]?
    public var embeddingModel: String?
    public var precision: EmbeddingPrecision

    public init(featurePrint: Data? = nil, embedding: [Float]? = nil, embeddingModel: String? = nil,
                precision: EmbeddingPrecision = .float16) {
        self.featurePrint = featurePrint
        self.embedding = embedding
        self.embeddingModel = embeddingModel
        self.precision = precision
    }
}
