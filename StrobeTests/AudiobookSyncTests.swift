import Testing
import Foundation
import SwiftData
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

    // MARK: - RSVPEngine playback controller seam

    @MainActor
    private final class ControllerSpy: RSVPPlaybackController {
        var playCalls = 0
        var pauseCalls = 0
        var seekCalls: [Int] = []
        func enginePlay() { playCalls += 1 }
        func enginePause() { pauseCalls += 1 }
        func engineSeek(toWordIndex index: Int) { seekCalls.append(index) }
    }

    @MainActor
    @Test func engineWithControllerNeverSchedulesTimer() async throws {
        let engine = RSVPEngine(words: ["a", "b", "c"], wordsPerMinute: 6000)
        let spy = ControllerSpy()
        engine.playbackController = spy
        engine.play()
        #expect(engine.isPlaying)
        #expect(spy.playCalls == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.currentIndex == 0)
        engine.pause()
        #expect(!engine.isPlaying)
        #expect(spy.pauseCalls == 1)
    }

    @MainActor
    @Test func engineSeekNotifiesControllerWithClampedIndex() {
        let engine = RSVPEngine(words: ["a", "b", "c"])
        let spy = ControllerSpy()
        engine.playbackController = spy
        engine.seek(to: 99)
        #expect(engine.currentIndex == 2)
        #expect(spy.seekCalls == [2])
    }

    @MainActor
    @Test func setIndexFromAudioDoesNotNotifyController() {
        let engine = RSVPEngine(words: ["a", "b", "c"])
        let spy = ControllerSpy()
        engine.playbackController = spy
        engine.setIndexFromAudio(1)
        #expect(engine.currentIndex == 1)
        #expect(spy.seekCalls.isEmpty)
        engine.setIndexFromAudio(99)
        #expect(engine.currentIndex == 2)
    }

    // MARK: - AudioSyncCoordinator (AC-U11, AC-I1 to I5, I9, I10, I13)

    @MainActor
    private func makeCoordinatorRig(
        starts: [Double] = [0.0, 0.5, 1.0, 2.0],
        boundaries: [Int] = [0],
        outputOffset: TimeInterval = 0
    ) -> (engine: RSVPEngine, clock: FakePlaybackClock, coordinator: AudioSyncCoordinator) {
        let words = (0..<starts.count).map { "w\($0)" }
        let engine = RSVPEngine(words: words, wordsPerMinute: 6000)
        let clock = FakePlaybackClock()
        let timeline = SegmentTimeline(wordTimeline: WordTimeline(starts: starts), segmentBoundaries: boundaries)
        let coordinator = AudioSyncCoordinator(clock: clock, timeline: timeline, engine: engine, outputOffset: outputOffset, rate: 1.0)
        return (engine, clock, coordinator)
    }

    @Test func effectiveTimeSubtractsOffsetClampedAtZero() {
        #expect(abs(AudioSyncCoordinator.effectiveTime(currentTime: 0.6, outputOffset: 0.2) - 0.4) < 1e-9)
        #expect(AudioSyncCoordinator.effectiveTime(currentTime: 0.1, outputOffset: 0.2) == 0.0)
    }

    @MainActor
    @Test func coordinatorTickSetsIndexMatchingCurrentTime() {
        let (engine, clock, coordinator) = makeCoordinatorRig()
        _ = coordinator
        clock.tick(at: 0.6)
        #expect(engine.currentIndex == 1)
        clock.tick(at: 2.0)
        #expect(engine.currentIndex == 3)
    }

    @MainActor
    @Test func coordinatorAppliesOutputOffsetOnTicks() {
        let (engine, clock, coordinator) = makeCoordinatorRig(outputOffset: 0.2)
        _ = coordinator
        clock.tick(at: 0.6)
        #expect(engine.currentIndex == 0)
        clock.tick(at: 0.71)
        #expect(engine.currentIndex == 1)
    }

    @MainActor
    @Test func uiSeekDrivesClockViaWordIndex() {
        let (engine, clock, coordinator) = makeCoordinatorRig()
        _ = coordinator
        engine.seek(to: 2)
        #expect(clock.seekTargets == [1.0])
        #expect(engine.currentIndex == 2)
    }

    @MainActor
    @Test func playPauseDelegateToClock() {
        let (engine, clock, coordinator) = makeCoordinatorRig()
        _ = coordinator
        engine.play()
        #expect(clock.playCallCount == 1)
        engine.pause()
        #expect(clock.pauseCallCount == 1)
    }

    @MainActor
    @Test func rateIsClampedAndForwarded() {
        let (_, clock, coordinator) = makeCoordinatorRig()
        coordinator.setRate(5.0)
        #expect(clock.rate == 3.0)
        #expect(coordinator.rate == 3.0)
        coordinator.setRate(0.1)
        #expect(clock.rate == 0.5)
    }

    @MainActor
    @Test func interruptionPausesAndReportsIndex() {
        let (engine, clock, coordinator) = makeCoordinatorRig()
        var reportedIndex: Int?
        coordinator.onExternalPause = { reportedIndex = $0 }
        engine.play()
        clock.tick(at: 0.6)
        clock.onDidInterrupt?()
        #expect(clock.pauseCallCount >= 1)
        #expect(!engine.isPlaying)
        #expect(reportedIndex == 1)
    }

    @MainActor
    @Test func failedSeekRestoresLastGoodIndexAndSurfacesError() {
        let (engine, clock, coordinator) = makeCoordinatorRig()
        clock.tick(at: 0.6)
        #expect(engine.currentIndex == 1)
        clock.seekBehavior = .fail
        engine.seek(to: 3)
        #expect(engine.currentIndex == 1)
        #expect(coordinator.transientError != nil)
    }

    @MainActor
    @Test func delayedSeekIgnoresStaleTicksUntilCompletion() {
        let (engine, clock, coordinator) = makeCoordinatorRig()
        _ = coordinator
        clock.seekBehavior = .delayed
        engine.seek(to: 3)
        #expect(engine.currentIndex == 3)
        clock.tick(at: 0.0)
        #expect(engine.currentIndex == 3)
        clock.completeNextSeek(success: true)
        clock.tick(at: 2.0)
        #expect(engine.currentIndex == 3)
        clock.tick(at: 0.6)
        #expect(engine.currentIndex == 1)
    }

    @MainActor
    @Test func staleSeekCompletionIsIgnoredAfterNewerSeek() {
        let (engine, clock, coordinator) = makeCoordinatorRig()
        clock.seekBehavior = .delayed
        engine.seek(to: 1)
        engine.seek(to: 3)
        clock.completeNextSeek(success: false)
        #expect(coordinator.transientError == nil)
        #expect(engine.currentIndex == 3)
        clock.completeNextSeek(success: true)
        #expect(engine.currentIndex == 3)
    }

    @MainActor
    @Test func coordinatorReanchorsAcrossSegmentBoundary() {
        let (engine, clock, coordinator) = makeCoordinatorRig(
            starts: [0.0, 9.0, 9.0, 5.0, 5.5, 6.0],
            boundaries: [0, 3]
        )
        _ = coordinator
        for t in stride(from: 0.0, through: 4.9, by: 0.35) {
            clock.tick(at: t)
            #expect(engine.currentIndex >= 0 && engine.currentIndex < 3)
        }
        clock.tick(at: 5.2)
        #expect(engine.currentIndex == 3)
    }

    @MainActor
    @Test func endOfItemPausesAtLastWord() {
        let (engine, clock, coordinator) = makeCoordinatorRig()
        _ = coordinator
        engine.play()
        clock.onDidReachEnd?()
        #expect(engine.currentIndex == 3)
        #expect(engine.isAtEnd)
        #expect(!engine.isPlaying)
    }

    @MainActor
    @Test func outputOffsetIsClamped() {
        let (_, _, coordinator) = makeCoordinatorRig()
        coordinator.outputOffset = 5.0
        #expect(coordinator.outputOffset == 1.0)
        coordinator.outputOffset = -0.5
        #expect(coordinator.outputOffset == 0.0)
    }

    // MARK: - Import fixtures

    private func makeWAVFile(duration: TimeInterval = 2.0) throws -> URL {
        let sampleRate = 8000
        let frameCount = Int(duration * Double(sampleRate))
        let dataSize = frameCount * 2
        var bytes = Data()
        func ascii(_ s: String) { bytes.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36 + dataSize)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        ascii("data"); u32(UInt32(dataSize))
        bytes.append(Data(count: dataSize))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("strobe-test-\(UUID().uuidString).wav")
        try bytes.write(to: url)
        return url
    }

    private func writeTimingFile(_ json: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("strobe-test-\(UUID().uuidString).json")
        try json.write(to: url)
        return url
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("strobe-audio-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func makeInMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Document.self, configurations: config)
    }

    // MARK: - AudiobookImporter (AC-I6, I7, I8, I11, I12)

    @Test func classifyPairIsOrderIndependent() throws {
        let wav = try makeWAVFile()
        let timing = try writeTimingFile(Self.exampleTimingJSON)
        let a = try AudiobookImporter.classifyPair([wav, timing])
        #expect(a.audio == wav && a.timing == timing)
        let b = try AudiobookImporter.classifyPair([timing, wav])
        #expect(b.audio == wav && b.timing == timing)
        #expect(throws: DocumentImportError.audiobookPairRequired) {
            try AudiobookImporter.classifyPair([wav])
        }
        #expect(throws: DocumentImportError.audiobookPairRequired) {
            try AudiobookImporter.classifyPair([wav, wav])
        }
    }

    @MainActor
    @Test func prepareBuildsPreviewFromValidPair() async throws {
        let wav = try makeWAVFile(duration: 2.0)
        let timing = try writeTimingFile(Self.exampleTimingJSON)
        let preview = try await AudiobookImporter.prepare(audioURL: wav, timingURL: timing)
        #expect(preview.wordCount == 6)
        #expect(preview.segmentCount == 2)
        #expect(preview.previewWords == ["In", "a", "hole", "in", "the", "ground"])
        #expect(abs(preview.audioDuration - 2.0) < 0.1)
        #expect(!preview.contentHash.isEmpty)
        #expect(WordStorage.decode(preview.wordsBlob) == ["In", "a", "hole", "in", "the", "ground"])
    }

    @MainActor
    @Test func prepareRejectsCorruptAudio() async throws {
        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("strobe-test-\(UUID().uuidString).mp3")
        try Data(repeating: 0xAB, count: 4096).write(to: corrupt)
        let timing = try writeTimingFile(Self.exampleTimingJSON)
        await #expect(throws: DocumentImportError.audioCorrupt) {
            _ = try await AudiobookImporter.prepare(audioURL: corrupt, timingURL: timing)
        }
    }

    @MainActor
    @Test func invalidTimingRejectedInPrepare() async throws {
        let wav = try makeWAVFile()
        let badTiming = try writeTimingFile("{\"version\": 3, \"segments\": []}".data(using: .utf8)!)
        await #expect(throws: DocumentImportError.unsupportedTimingVersion) {
            _ = try await AudiobookImporter.prepare(audioURL: wav, timingURL: badTiming)
        }
    }

    @MainActor
    @Test func commitCreatesOneSelfContainedDocument() async throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let baseDir = try makeTempDirectory()
        let wav = try makeWAVFile()
        let timing = try writeTimingFile(Self.exampleTimingJSON)
        let preview = try await AudiobookImporter.prepare(audioURL: wav, timingURL: timing)
        let doc = try AudiobookImporter.commit(preview: preview, defaultWPM: 300, baseDirectory: baseDir) {
            context.insert($0)
            try context.save()
        }
        let all = try context.fetch(FetchDescriptor<Document>())
        #expect(all.count == 1)
        #expect(doc.sourceType == .audiobook)
        #expect(doc.wordCount == 6)
        #expect(doc.playbackRate == 1.0)
        #expect(abs(doc.audioDuration - 2.0) < 0.1)
        #expect(doc.audioOutputOffset >= 0 && doc.audioOutputOffset <= 1.0)
        #expect(WordTimingStorage.decode(doc.wordTimingsBlob ?? Data()) == [0.42, 0.55, 0.61, 0.94, 1.02, 1.10])
        #expect(SegmentBoundaryStorage.decode(doc.segmentBoundariesBlob ?? Data()) == [0, 3])
        let audioFile = AudiobookLibrary.audioURL(fileName: doc.audioFileName ?? "", in: baseDir)
        #expect(FileManager.default.fileExists(atPath: audioFile.path))
    }

    @MainActor
    @Test func failedInsertRemovesPartialCopyAndCreatesNothing() async throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let baseDir = try makeTempDirectory()
        let wav = try makeWAVFile()
        let timing = try writeTimingFile(Self.exampleTimingJSON)
        let preview = try await AudiobookImporter.prepare(audioURL: wav, timingURL: timing)
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try AudiobookImporter.commit(preview: preview, defaultWPM: 300, baseDirectory: baseDir) { _ in
                throw Boom()
            }
        }
        let all = try context.fetch(FetchDescriptor<Document>())
        #expect(all.isEmpty)
        let contents = try FileManager.default.contentsOfDirectory(atPath: baseDir.path)
        #expect(contents.isEmpty)
    }

    @MainActor
    @Test func duplicateContentHashIsDetectableAcrossImports() async throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let baseDir = try makeTempDirectory()
        let wav = try makeWAVFile()
        let timing = try writeTimingFile(Self.exampleTimingJSON)
        let first = try await AudiobookImporter.prepare(audioURL: wav, timingURL: timing)
        _ = try AudiobookImporter.commit(preview: first, defaultWPM: 300, baseDirectory: baseDir) {
            context.insert($0)
            try context.save()
        }
        let second = try await AudiobookImporter.prepare(audioURL: wav, timingURL: timing)
        #expect(second.contentHash == first.contentHash)
        let existing = try context.fetch(FetchDescriptor<Document>())
        #expect(existing.contains { $0.audioContentHash == second.contentHash })
        _ = try AudiobookImporter.commit(preview: second, defaultWPM: 300, baseDirectory: baseDir) {
            context.insert($0)
            try context.save()
        }
        let all = try context.fetch(FetchDescriptor<Document>())
        #expect(all.count == 2)
        let audioFiles = Set(all.compactMap(\.audioFileName))
        #expect(audioFiles.count == 2)
    }

    @MainActor
    @Test func removeAudioDeletesCopiedFile() async throws {
        let baseDir = try makeTempDirectory()
        let wav = try makeWAVFile()
        let docID = UUID()
        let name = try AudiobookLibrary.copyAudio(from: wav, documentID: docID, into: baseDir)
        let copied = AudiobookLibrary.audioURL(fileName: name, in: baseDir)
        #expect(FileManager.default.fileExists(atPath: copied.path))
        AudiobookLibrary.removeAudio(fileName: name, from: baseDir)
        #expect(!FileManager.default.fileExists(atPath: copied.path))
    }
}

@MainActor
final class FakePlaybackClock: PlaybackClock {
    var currentTime: TimeInterval = 0
    var rate: Double = 1.0
    var onTick: ((TimeInterval) -> Void)?
    var onDidReachEnd: (() -> Void)?
    var onDidFail: ((String) -> Void)?
    var onDidInterrupt: (() -> Void)?

    enum SeekBehavior { case succeed, fail, delayed }
    var seekBehavior: SeekBehavior = .succeed

    private(set) var playCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var seekTargets: [TimeInterval] = []
    private var pendingSeeks: [(target: TimeInterval, completion: (Bool) -> Void)] = []

    func play() { playCallCount += 1 }
    func pause() { pauseCallCount += 1 }

    func seek(to time: TimeInterval, completion: @escaping (Bool) -> Void) {
        seekTargets.append(time)
        switch seekBehavior {
        case .succeed:
            currentTime = time
            completion(true)
        case .fail:
            completion(false)
        case .delayed:
            pendingSeeks.append((time, completion))
        }
    }

    func completeNextSeek(success: Bool) {
        guard !pendingSeeks.isEmpty else { return }
        let pending = pendingSeeks.removeFirst()
        if success { currentTime = pending.target }
        pending.completion(success)
    }

    func tick(at time: TimeInterval) {
        currentTime = time
        onTick?(time)
    }
}
