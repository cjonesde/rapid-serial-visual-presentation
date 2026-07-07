import Foundation

enum SegmentBoundaryStorage {

    nonisolated static func encode(_ boundaries: [Int]) -> Data {
        boundaries.map(Int32.init).withUnsafeBytes { Data($0) }
    }

    nonisolated static func decode(_ data: Data) -> [Int] {
        guard !data.isEmpty else { return [] }
        let count = data.count / MemoryLayout<Int32>.size
        return data.withUnsafeBytes { buffer in
            (0..<count).map { i in
                Int(buffer.loadUnaligned(fromByteOffset: i * MemoryLayout<Int32>.size, as: Int32.self))
            }
        }
    }
}
