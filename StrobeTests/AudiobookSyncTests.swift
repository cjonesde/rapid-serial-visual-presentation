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
}
