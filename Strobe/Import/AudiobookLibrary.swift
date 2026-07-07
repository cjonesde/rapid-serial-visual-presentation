import Foundation

enum AudiobookLibrary {

    nonisolated static func defaultBaseDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func audioURL(fileName: String, in baseDirectory: URL) -> URL {
        baseDirectory.appendingPathComponent(fileName)
    }

    nonisolated static func copyAudio(from source: URL, documentID: UUID, into baseDirectory: URL) throws -> String {
        let ext = source.pathExtension.isEmpty ? "audio" : source.pathExtension.lowercased()
        let fileName = "\(documentID.uuidString).\(ext)"
        let destination = baseDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw DocumentImportError.audioCopyFailed
        }
        return fileName
    }

    nonisolated static func removeAudio(fileName: String, from baseDirectory: URL) {
        try? FileManager.default.removeItem(at: baseDirectory.appendingPathComponent(fileName))
    }
}
