import Foundation

public nonisolated enum EmbeddingPrecision: Int, Codable, Sendable {
    case float16 = 16
    case float32 = 32

    func encode(_ values: [Float]) -> Data {
        let count = values.count
        guard count > 0 else { return Data() }
        switch self {
        case .float16:
            let byteCount = count * MemoryLayout<UInt16>.stride
            let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<UInt16>.alignment)
            let dst = raw.bindMemory(to: UInt16.self, capacity: count)
            values.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                for idx in 0..<count {
                    dst[idx] = Float16(base[idx]).bitPattern.littleEndian
                }
            }
            return Data(bytesNoCopy: raw, count: byteCount, deallocator: .custom({ ptr, _ in ptr.deallocate() }))
        case .float32:
            #if _endian(little)
            return values.withUnsafeBytes { Data($0) }
            #else
            let byteCount = count * MemoryLayout<UInt32>.stride
            let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<UInt32>.alignment)
            let dst = raw.bindMemory(to: UInt32.self, capacity: count)
            values.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                for idx in 0..<count {
                    dst[idx] = base[idx].bitPattern.littleEndian
                }
            }
            return Data(bytesNoCopy: raw, count: byteCount, deallocator: .custom({ ptr, _ in ptr.deallocate() }))
            #endif
        }
    }

    func decode(_ bytes: Data) -> [Float] {
        bytes.withUnsafeBytes { raw in
            let elemSize = rawValue / 8
            let count = raw.count / elemSize
            guard count > 0, let base = raw.baseAddress else { return [] }
            return Array<Float>(unsafeUninitializedCapacity: count) { buffer, initializedCount in
                guard let dst = buffer.baseAddress else {
                    initializedCount = 0
                    return
                }
                switch self {
                case .float16:
                    if Int(bitPattern: base) & (MemoryLayout<UInt16>.alignment - 1) == 0 {
                        let src = base.assumingMemoryBound(to: UInt16.self)
                        for idx in 0..<count {
                            dst[idx] = Float(Float16(bitPattern: UInt16(littleEndian: src[idx])))
                        }
                    } else {
                        for idx in 0..<count {
                            let bits = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: idx * 2, as: UInt16.self))
                            dst[idx] = Float(Float16(bitPattern: bits))
                        }
                    }
                case .float32:
                    #if _endian(little)
                    UnsafeMutableRawPointer(dst).copyMemory(from: base, byteCount: count * MemoryLayout<Float>.stride)
                    #else
                    for idx in 0..<count {
                        let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: idx * 4, as: UInt32.self))
                        dst[idx] = Float(bitPattern: bits)
                    }
                    #endif
                }
                initializedCount = count
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
