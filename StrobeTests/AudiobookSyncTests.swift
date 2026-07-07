import Testing
import Foundation
@testable import Strobe

struct AudiobookSyncTests {

    // MARK: - Timing storage (AC-U4)

    @Test func wordTimingStorageRoundTripsExactly() {
        let times = [0.0, 0.5, 1.0, 3600.25]
        #expect(WordTimingStorage.decode(WordTimingStorage.encode(times)) == times)
    }

    @Test func wordTimingStorageHandlesEmpty() {
        #expect(WordTimingStorage.encode([]).isEmpty)
        #expect(WordTimingStorage.decode(Data()) == [])
    }

    @Test func segmentBoundaryStorageRoundTrips() {
        let boundaries = [0, 3, 17, 100_000]
        #expect(SegmentBoundaryStorage.decode(SegmentBoundaryStorage.encode(boundaries)) == boundaries)
        #expect(SegmentBoundaryStorage.decode(Data()) == [])
    }

    // MARK: - WordTimeline (AC-U1, AC-U2, AC-U3)

    @Test func wordTimelineResolvesIndexByTimeClamped() {
        let timeline = WordTimeline(starts: [0.0, 0.5, 1.0, 2.0])
        #expect(timeline.index(at: -0.1) == 0)
        #expect(timeline.index(at: 0.0) == 0)
        #expect(timeline.index(at: 0.49) == 0)
        #expect(timeline.index(at: 0.5) == 1)
        #expect(timeline.index(at: 1.99) == 2)
        #expect(timeline.index(at: 2.0) == 3)
        #expect(timeline.index(at: 100) == 3)
    }

    @Test func wordTimelineSingleWordAlwaysZero() {
        let single = WordTimeline(starts: [0.0])
        #expect(single.index(at: -5) == 0)
        #expect(single.index(at: 0) == 0)
        #expect(single.index(at: 999) == 0)
    }

    @Test func wordTimelineEqualTimestampsLaterIndexWins() {
        let timeline = WordTimeline(starts: [0.0, 0.5, 0.5, 1.0])
        #expect(timeline.index(at: 0.5) == 2)
    }

    @Test func wordTimelineTimeLookupIsInverse() {
        let timeline = WordTimeline(starts: [0.0, 0.5, 1.0, 2.0])
        #expect(timeline.time(ofWordAt: 2) == 1.0)
        #expect(timeline.time(ofWordAt: -1) == 0.0)
        #expect(timeline.time(ofWordAt: 99) == 2.0)
    }

    @Test func wordTimelineRateAndWPMMath() {
        let timeline = WordTimeline(starts: (0..<9000).map { Double($0) })
        #expect(timeline.averageWPM(duration: 3600) == 150)
        #expect(timeline.displayedWPM(rate: 1.5, duration: 3600) == 225)
        #expect(WordTimeline.clampRate(0.1) == 0.5)
        #expect(WordTimeline.clampRate(5.0) == 3.0)
        #expect(WordTimeline.clampRate(1.25) == 1.25)
        #expect(timeline.averageWPM(duration: 0) == 0)
    }

    // MARK: - SegmentTimeline (AC-U10)

    @Test func segmentTimelineResolvesLikeWordTimelineWhenSingleSegment() {
        let timeline = SegmentTimeline(
            wordTimeline: WordTimeline(starts: [0.0, 0.5, 1.0, 2.0]),
            segmentBoundaries: [0]
        )
        #expect(timeline.index(at: 0.6) == 1)
        #expect(timeline.index(at: 2.5) == 3)
        #expect(timeline.time(ofWordAt: 2) == 1.0)
    }

    @Test func segmentReanchoringBoundsWithinSegmentError() {
        let timeline = SegmentTimeline(
            wordTimeline: WordTimeline(starts: [0.0, 0.0, 0.0, 5.0, 5.5, 6.0]),
            segmentBoundaries: [0, 3]
        )
        let before = timeline.index(at: 4.9)
        #expect(before >= 0 && before < 3)
        #expect(timeline.index(at: 5.0) == 3)
        #expect(timeline.index(at: 5.6) == 4)
    }

    @Test func segmentTimelineCorruptTimesCannotEscapeSegment() {
        let timeline = SegmentTimeline(
            wordTimeline: WordTimeline(starts: [0.0, 9.0, 9.0, 5.0, 5.5, 6.0]),
            segmentBoundaries: [0, 3]
        )
        for t in stride(from: 0.0, through: 4.9, by: 0.7) {
            let idx = timeline.index(at: t)
            #expect(idx >= 0 && idx < 3)
        }
        #expect(timeline.index(at: 5.1) == 3)
    }

    @Test func segmentTimelineEmptyBoundariesActsAsSingleSegment() {
        let timeline = SegmentTimeline(
            wordTimeline: WordTimeline(starts: [0.0, 1.0]),
            segmentBoundaries: []
        )
        #expect(timeline.index(at: 1.5) == 1)
    }

    // MARK: - Document audiobook fields

    @MainActor
    @Test func audiobookDocumentInitStoresAudioFields() {
        let timings = [0.0, 0.5, 1.0]
        let doc = Document(
            id: UUID(),
            audiobookTitle: "The Hobbit",
            fileName: "the-hobbit.mp3",
            wordsBlob: WordStorage.encode(["In", "a", "hole"]),
            wordCount: 3,
            wordsPerMinute: 300,
            audioFileName: "abc.mp3",
            wordTimingsBlob: WordTimingStorage.encode(timings),
            segmentBoundariesBlob: SegmentBoundaryStorage.encode([0]),
            audioDuration: 120,
            audioOutputOffset: 0.1,
            audioContentHash: "hash"
        )
        #expect(doc.sourceType == .audiobook)
        #expect(doc.isAudiobook)
        #expect(doc.playbackRate == 1.0)
        #expect(doc.audioDuration == 120)
        #expect(doc.readingWords == ["In", "a", "hole"])
        #expect(WordTimingStorage.decode(doc.wordTimingsBlob ?? Data()) == timings)
    }

    @MainActor
    @Test func legacyDocumentIsNotAudiobook() {
        let doc = Document(title: "T", fileName: "t.txt", bookmarkData: Data(), words: ["a"])
        #expect(!doc.isAudiobook)
        #expect(doc.sourceType == .unknown)
    }

    // MARK: - AudiobookTimingParser (AC-U5 to AC-U9)

    static let exampleTimingJSON = """
    {
      "version": 2,
      "audio": "the-hobbit.mp3",
      "language": "en",
      "segments": [
        { "s": 0.42, "words": [
          { "w": "In", "s": 0.42 }, { "w": "a", "s": 0.55 }, { "w": "hole", "s": 0.61 } ] },
        { "s": 0.94, "words": [
          { "w": "in", "s": 0.94 }, { "w": "the", "s": 1.02 }, { "w": "ground", "s": 1.10 } ] }
      ]
    }
    """.data(using: .utf8)!

    @Test func parserAcceptsValidV2File() throws {
        let parsed = try AudiobookTimingParser.parse(Self.exampleTimingJSON, audioDuration: 100)
        #expect(parsed.words == ["In", "a", "hole", "in", "the", "ground"])
        #expect(parsed.segmentBoundaries == [0, 3])
        #expect(parsed.wordStarts == [0.42, 0.55, 0.61, 0.94, 1.02, 1.10])
        #expect(parsed.language == "en")
    }

    @Test func parserRejectsUnknownVersion() {
        for version in [1, 3] {
            let json = "{\"version\": \(version), \"segments\": [{\"s\": 0, \"words\": [{\"w\": \"a\", \"s\": 0}]}]}".data(using: .utf8)!
            #expect(throws: DocumentImportError.unsupportedTimingVersion) {
                try AudiobookTimingParser.parse(json, audioDuration: 100)
            }
        }
    }

    @Test func parserRejectsMalformedInput() {
        let cases: [Data] = [
            "not json".data(using: .utf8)!,
            "{\"version\": 2, \"segments\": []}".data(using: .utf8)!,
            "{\"version\": 2, \"segments\": [{\"s\": 0, \"words\": []}]}".data(using: .utf8)!,
            "{\"version\": 2, \"segments\": [{\"s\": 0, \"words\": [{\"s\": 0}]}]}".data(using: .utf8)!,
            "{\"version\": 2, \"segments\": [{\"s\": 0, \"words\": [{\"w\": \"a\"}]}]}".data(using: .utf8)!
        ]
        for data in cases {
            #expect(throws: DocumentImportError.malformedTimings) {
                try AudiobookTimingParser.parse(data, audioDuration: 100)
            }
        }
    }

    @Test func parserRejectsNonMonotonicAllowsEqual() throws {
        let decreasing = "{\"version\": 2, \"segments\": [{\"s\": 0, \"words\": [{\"w\": \"a\", \"s\": 0.0}, {\"w\": \"b\", \"s\": 0.5}, {\"w\": \"c\", \"s\": 0.4}]}]}".data(using: .utf8)!
        #expect(throws: DocumentImportError.nonMonotonicTimings) {
            try AudiobookTimingParser.parse(decreasing, audioDuration: 100)
        }
        let outOfOrderSegments = "{\"version\": 2, \"segments\": [{\"s\": 5.0, \"words\": [{\"w\": \"a\", \"s\": 5.0}]}, {\"s\": 1.0, \"words\": [{\"w\": \"b\", \"s\": 1.0}]}]}".data(using: .utf8)!
        #expect(throws: DocumentImportError.nonMonotonicTimings) {
            try AudiobookTimingParser.parse(outOfOrderSegments, audioDuration: 100)
        }
        let equal = "{\"version\": 2, \"segments\": [{\"s\": 0, \"words\": [{\"w\": \"a\", \"s\": 0.0}, {\"w\": \"b\", \"s\": 0.5}, {\"w\": \"c\", \"s\": 0.5}]}]}".data(using: .utf8)!
        let parsed = try AudiobookTimingParser.parse(equal, audioDuration: 100)
        #expect(parsed.wordStarts == [0.0, 0.5, 0.5])
    }

    @Test func parserRejectsNegativeAndOverlongTimings() throws {
        let negative = "{\"version\": 2, \"segments\": [{\"s\": -1.0, \"words\": [{\"w\": \"a\", \"s\": -1.0}]}]}".data(using: .utf8)!
        #expect(throws: DocumentImportError.nonMonotonicTimings) {
            try AudiobookTimingParser.parse(negative, audioDuration: 100)
        }
        let overlong = "{\"version\": 2, \"segments\": [{\"s\": 0, \"words\": [{\"w\": \"a\", \"s\": 0.0}, {\"w\": \"b\", \"s\": 103.0}]}]}".data(using: .utf8)!
        #expect(throws: DocumentImportError.timingsExceedAudio) {
            try AudiobookTimingParser.parse(overlong, audioDuration: 100.0, tolerance: 2.0)
        }
        let withinTolerance = "{\"version\": 2, \"segments\": [{\"s\": 0, \"words\": [{\"w\": \"a\", \"s\": 0.0}, {\"w\": \"b\", \"s\": 101.5}]}]}".data(using: .utf8)!
        let parsed = try AudiobookTimingParser.parse(withinTolerance, audioDuration: 100.0, tolerance: 2.0)
        #expect(parsed.wordStarts.last == 101.5)
    }

    @Test func parserRejectsWordsContainingNewlines() {
        let newline = "{\"version\": 2, \"segments\": [{\"s\": 0, \"words\": [{\"w\": \"a\\nb\", \"s\": 0.0}]}]}".data(using: .utf8)!
        #expect(throws: DocumentImportError.malformedTimings) {
            try AudiobookTimingParser.parse(newline, audioDuration: 100)
        }
    }
}
