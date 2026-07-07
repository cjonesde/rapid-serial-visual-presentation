import Foundation
import AVFoundation
import CryptoKit
internal import UniformTypeIdentifiers

struct AudiobookImportPreview: Identifiable, Sendable {
    let id: UUID
    let title: String
    let previewWords: [String]
    let audioDuration: TimeInterval
    let wordCount: Int
    let segmentCount: Int
    let audioURL: URL
    let contentHash: String
    let suggestedOutputOffset: TimeInterval
    let wordsBlob: Data
    let wordTimingsBlob: Data
    let segmentBoundariesBlob: Data
}

enum AudiobookImporter {

    nonisolated static func classifyPair(_ urls: [URL]) throws -> (audio: URL, timing: URL) {
        guard urls.count == 2 else { throw DocumentImportError.audiobookPairRequired }
        let timingFlags = urls.map(looksLikeTimingJSON(_:))
        switch (timingFlags[0], timingFlags[1]) {
        case (true, false): return (audio: urls[1], timing: urls[0])
        case (false, true): return (audio: urls[0], timing: urls[1])
        default: throw DocumentImportError.audiobookPairRequired
        }
    }

    nonisolated private static func looksLikeTimingJSON(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096),
              let text = String(data: head, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
    }

    static func prepare(audioURL: URL, timingURL: URL) async throws -> AudiobookImportPreview {
        let asset = AVURLAsset(url: audioURL)
        let isPlayable: Bool
        let hasProtectedContent: Bool
        let duration: CMTime
        do {
            (isPlayable, hasProtectedContent, duration) = try await asset.load(.isPlayable, .hasProtectedContent, .duration)
        } catch {
            throw audioFailure(for: audioURL)
        }
        if hasProtectedContent { throw DocumentImportError.audioProtected }
        guard isPlayable, duration.seconds.isFinite, duration.seconds > 0 else {
            throw audioFailure(for: audioURL)
        }
        try Task.checkCancellation()

        let audioDuration = duration.seconds
        let timingData = try readTimingData(from: timingURL)
        let localAudioURL = audioURL
        let (parsed, wordsBlob, timingsBlob, boundariesBlob, hash) = try await Task.detached(priority: .userInitiated) {
            () -> (ParsedAudiobookTiming, Data, Data, Data, String) in
            let parsed = try AudiobookTimingParser.parse(timingData, audioDuration: audioDuration)
            try Task.checkCancellation()
            let audioData = try Data(contentsOf: localAudioURL, options: .mappedIfSafe)
            let hash = SHA256.hash(data: audioData).map { String(format: "%02x", $0) }.joined()
            try Task.checkCancellation()
            return (
                parsed,
                WordStorage.encode(parsed.words),
                WordTimingStorage.encode(parsed.wordStarts),
                SegmentBoundaryStorage.encode(parsed.segmentBoundaries),
                hash
            )
        }.value

        let metadataTitle = try? await loadMetadataTitle(from: asset)
        let title = DocumentImportPipeline.resolveTitle(
            metadataTitle: metadataTitle ?? nil,
            fileName: audioURL.lastPathComponent
        )

        return AudiobookImportPreview(
            id: UUID(),
            title: title,
            previewWords: Array(parsed.words.prefix(20)),
            audioDuration: audioDuration,
            wordCount: parsed.words.count,
            segmentCount: parsed.segmentBoundaries.count,
            audioURL: audioURL,
            contentHash: hash,
            suggestedOutputOffset: seededOutputOffset(),
            wordsBlob: wordsBlob,
            wordTimingsBlob: timingsBlob,
            segmentBoundariesBlob: boundariesBlob
        )
    }

    static func commit(
        preview: AudiobookImportPreview,
        defaultWPM: Int,
        baseDirectory: URL,
        insert: (Document) throws -> Void
    ) throws -> Document {
        let documentID = UUID()
        let copiedFileName = try AudiobookLibrary.copyAudio(
            from: preview.audioURL,
            documentID: documentID,
            into: baseDirectory
        )
        do {
            try Task.checkCancellation()
            let document = Document(
                id: documentID,
                audiobookTitle: preview.title,
                fileName: preview.audioURL.lastPathComponent,
                wordsBlob: preview.wordsBlob,
                wordCount: preview.wordCount,
                wordsPerMinute: defaultWPM,
                audioFileName: copiedFileName,
                wordTimingsBlob: preview.wordTimingsBlob,
                segmentBoundariesBlob: preview.segmentBoundariesBlob,
                audioDuration: preview.audioDuration,
                audioOutputOffset: preview.suggestedOutputOffset,
                audioContentHash: preview.contentHash
            )
            try insert(document)
            return document
        } catch {
            AudiobookLibrary.removeAudio(fileName: copiedFileName, from: baseDirectory)
            throw error
        }
    }

    nonisolated static func seededOutputOffset() -> TimeInterval {
        #if os(iOS)
        return AudioSyncCoordinator.clampOffset(AVAudioSession.sharedInstance().outputLatency)
        #else
        return 0
        #endif
    }

    nonisolated private static func readTimingData(from url: URL) throws -> Data {
        guard let data = try? Data(contentsOf: url) else {
            throw DocumentImportError.malformedTimings
        }
        guard data.count <= AudiobookTimingParser.maxTimingFileBytes else {
            throw DocumentImportError.malformedTimings
        }
        return data
    }

    nonisolated private static func audioFailure(for url: URL) -> DocumentImportError {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audio) {
            return .audioCorrupt
        }
        return .audioUnsupported
    }

    private static func loadMetadataTitle(from asset: AVURLAsset) async throws -> String? {
        let metadata = try await asset.load(.commonMetadata)
        let titleItems = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: .commonIdentifierTitle
        )
        guard let item = titleItems.first else { return nil }
        return try await item.load(.stringValue)
    }
}
