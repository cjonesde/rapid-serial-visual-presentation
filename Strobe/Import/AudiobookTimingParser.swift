import Foundation

struct ParsedAudiobookTiming: Equatable {
    let words: [String]
    let wordStarts: [Double]
    let segmentBoundaries: [Int]
    let language: String?
}

enum AudiobookTimingParser {

    nonisolated static let maxTimingFileBytes = 64 << 20
    nonisolated static let durationTolerance: TimeInterval = 2.0

    private struct VersionProbe: Decodable {
        let version: Int
    }

    private struct TimingFile: Decodable {
        let version: Int
        let language: String?
        let segments: [TimingSegment]
    }

    private struct TimingSegment: Decodable {
        let s: Double
        let words: [TimingWord]
    }

    private struct TimingWord: Decodable {
        let w: String
        let s: Double
    }

    nonisolated static func parse(
        _ data: Data,
        audioDuration: TimeInterval,
        tolerance: TimeInterval = durationTolerance
    ) throws -> ParsedAudiobookTiming {
        guard data.count <= maxTimingFileBytes else {
            throw DocumentImportError.malformedTimings
        }
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else {
            throw DocumentImportError.malformedTimings
        }
        guard probe.version == 2 else {
            throw DocumentImportError.unsupportedTimingVersion
        }
        guard let file = try? decoder.decode(TimingFile.self, from: data) else {
            throw DocumentImportError.malformedTimings
        }
        guard !file.segments.isEmpty else {
            throw DocumentImportError.malformedTimings
        }

        var words: [String] = []
        var wordStarts: [Double] = []
        var segmentBoundaries: [Int] = []
        var previousSegmentStart = -Double.infinity
        var previousWordStart = -Double.infinity

        for segment in file.segments {
            guard !segment.words.isEmpty else {
                throw DocumentImportError.malformedTimings
            }
            guard segment.s >= 0, segment.s >= previousSegmentStart else {
                throw DocumentImportError.nonMonotonicTimings
            }
            previousSegmentStart = segment.s
            segmentBoundaries.append(words.count)
            for word in segment.words {
                guard !word.w.isEmpty, !word.w.contains("\n") else {
                    throw DocumentImportError.malformedTimings
                }
                guard word.s >= 0, word.s >= previousWordStart else {
                    throw DocumentImportError.nonMonotonicTimings
                }
                previousWordStart = word.s
                words.append(word.w)
                wordStarts.append(word.s)
            }
        }

        if let last = wordStarts.last, last > audioDuration + tolerance {
            throw DocumentImportError.timingsExceedAudio
        }

        return ParsedAudiobookTiming(
            words: words,
            wordStarts: wordStarts,
            segmentBoundaries: segmentBoundaries,
            language: file.language
        )
    }
}
