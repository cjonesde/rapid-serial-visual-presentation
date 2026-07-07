import Foundation

enum WordTimingStorage {

    nonisolated static func encode(_ times: [Double]) -> Data {
        times.withUnsafeBytes { Data($0) }
    }

    nonisolated static func decode(_ data: Data) -> [Double] {
        guard !data.isEmpty else { return [] }
        let count = data.count / MemoryLayout<Double>.size
        return data.withUnsafeBytes { buffer in
            (0..<count).map { i in
                buffer.loadUnaligned(fromByteOffset: i * MemoryLayout<Double>.size, as: Double.self)
            }
        }
    }
}
