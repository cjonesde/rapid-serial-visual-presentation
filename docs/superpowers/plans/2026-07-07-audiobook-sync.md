# Audiobook Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read word-by-word in Strobe while an MP3/m4a audiobook plays, with the on-screen word locked to the spoken word via a companion timing file, self-correcting at segment boundaries.

**Origin:** `docs/audiobook-sync-prd.md`

**Architecture:** Invert the playback clock. In audio mode the audio player's position is the source of truth: an `AudioSyncCoordinator` watches ticks from a `PlaybackClock` (protocol seam over `AVPlayer`) and sets `RSVPEngine.currentIndex` through a two-level `SegmentTimeline` lookup (segment first, then word), re-anchoring at every segment boundary. All UI seeks route through the word index. Pure core (`WordTimeline`, `SegmentTimeline`, `AudiobookTimingParser`, storage helpers) is fully unit-tested; the AVFoundation shell is thin and verified manually per the PRD.

**Tech Stack:** Swift, SwiftUI, SwiftData, AVFoundation, CryptoKit, Swift Testing (`@Test`/`#expect`).

## Global Constraints

- Targets iOS 17.0 / macOS 14.0; scheme `Strobe`; Xcode project uses `PBXFileSystemSynchronizedRootGroup` (new files on disk are picked up automatically, both targets).
- App target has `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; the test target does NOT. Mark pure logic members `nonisolated`; mark tests touching engine/coordinator/clock `@MainActor`.
- Swift Testing framework only (`@Test`, `#expect`, `Issue.record`) in `StrobeTests/`.
- No code comments in new code (user rule). No em dashes in prose or strings.
- Settings keys only via `ReaderSettings.Keys` (no new global keys needed; rate and offset are per-document).
- Dark theme via `StrobeTheme`; body text `StrobeTheme.bodyFont`, display numerals `titleFont`.
- Platform conditionals: `#if os(iOS)` for AVAudioSession; `HapticManager` is already a no-op on macOS.
- Test command: `xcodebuild test -project Strobe.xcodeproj -scheme Strobe -destination 'platform=macOS' -quiet` (run from repo root).
- Timing schema v2 (PRD): `{"version":2,"audio":"...","language":"en","segments":[{"s":0.42,"words":[{"w":"In","s":0.42},...]},...]}`. `w` = display token verbatim (never re-tokenized), `s` = onset seconds, monotonic non-decreasing; segment `s` equals its first word's `s`.

**Evals (from PRD acceptance criteria):**
- [ ] AC-U1 to AC-U11 pass (pure core: timelines, parser, storage, offset math)
- [ ] AC-I1 to AC-I13 pass (coordinator with FakePlaybackClock; import with in-memory SwiftData)
- [ ] Existing test suite still green (regression)
- [ ] AC-M1 to AC-M6 documented as manual device checks (not automated)

**Decisions taken on PRD open questions (autonomous, revisit if wrong):**
- Output offset: per-document (Data Model section wins over "global" wording), seeded from `AVAudioSession.outputLatency` (0 on macOS), manual nudge control included (25 ms steps, clamp 0 to 1.0 s).
- Rate: free 0.5x to 3x slider, 0.05 step.
- Chapters: out of v1 (audiobook documents import with `chapters: []`).
- Library badge: audiobook cards show a `headphones` icon instead of the book icon.
- Duplicate import: detect by SHA-256 content hash; alert offers Replace or Keep Both; importer API takes an explicit policy so both paths are testable.

---

### Task 1: Timing storage helpers

**Files:**
- Create: `Strobe/Models/WordTimingStorage.swift`
- Create: `Strobe/Models/SegmentBoundaryStorage.swift`
- Create: `StrobeTests/AudiobookSyncTests.swift` (new test file, grows across tasks)

**Interfaces:**
- Produces: `WordTimingStorage.encode(_: [Double]) -> Data`, `WordTimingStorage.decode(_: Data) -> [Double]`, `SegmentBoundaryStorage.encode(_: [Int]) -> Data`, `SegmentBoundaryStorage.decode(_: Data) -> [Int]` (all `nonisolated static`).

- [ ] **Step 1: Write the failing tests (AC-U4)**

```swift
import Testing
import Foundation
@testable import Strobe

struct AudiobookSyncTests {

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
}
```

- [ ] **Step 2: Run tests, expect FAIL** (types not defined)
- [ ] **Step 3: Implement**

`Strobe/Models/WordTimingStorage.swift`:
```swift
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
```

`Strobe/Models/SegmentBoundaryStorage.swift`:
```swift
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
```

- [ ] **Step 4: Run tests, expect PASS**
- [ ] **Step 5: Commit** `feat: add Float64 word timing and Int32 segment boundary storage`

---

### Task 2: WordTimeline (pure)

**Files:**
- Create: `Strobe/Engine/WordTimeline.swift`
- Test: `StrobeTests/AudiobookSyncTests.swift`

**Interfaces:**
- Produces: `struct WordTimeline { let starts: [Double] }` with `nonisolated` members: `wordCount: Int`, `index(at: TimeInterval) -> Int`, `time(ofWordAt: Int) -> TimeInterval`, `averageWPM(duration: TimeInterval) -> Double`, `displayedWPM(rate: Double, duration: TimeInterval) -> Int`, `static clampRate(_: Double) -> Double`, `static displayedWPM(wordCount: Int, duration: TimeInterval, rate: Double) -> Int`, `static minRate = 0.5`, `static maxRate = 3.0`.

- [ ] **Step 1: Write failing tests (AC-U1, AC-U2, AC-U3)**

```swift
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
        let timeline = WordTimeline(starts: Array(repeating: 0, count: 9000).enumerated().map { Double($0.offset) })
        #expect(timeline.averageWPM(duration: 3600) == 150)
        #expect(timeline.displayedWPM(rate: 1.5, duration: 3600) == 225)
        #expect(WordTimeline.clampRate(0.1) == 0.5)
        #expect(WordTimeline.clampRate(5.0) == 3.0)
        #expect(WordTimeline.clampRate(1.25) == 1.25)
        #expect(timeline.averageWPM(duration: 0) == 0)
    }
```

- [ ] **Step 2: Run tests, expect FAIL**
- [ ] **Step 3: Implement**

`Strobe/Engine/WordTimeline.swift`:
```swift
import Foundation

struct WordTimeline: Equatable {
    let starts: [Double]

    nonisolated static let minRate = 0.5
    nonisolated static let maxRate = 3.0

    nonisolated var wordCount: Int { starts.count }

    nonisolated func index(at time: TimeInterval) -> Int {
        guard !starts.isEmpty else { return 0 }
        var low = 0
        var high = starts.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    nonisolated func time(ofWordAt index: Int) -> TimeInterval {
        guard !starts.isEmpty else { return 0 }
        return starts[max(0, min(index, starts.count - 1))]
    }

    nonisolated func averageWPM(duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return Double(starts.count) / duration * 60
    }

    nonisolated func displayedWPM(rate: Double, duration: TimeInterval) -> Int {
        Self.displayedWPM(wordCount: starts.count, duration: duration, rate: rate)
    }

    nonisolated static func displayedWPM(wordCount: Int, duration: TimeInterval, rate: Double) -> Int {
        guard duration > 0 else { return 0 }
        return Int((Double(wordCount) / duration * 60 * rate).rounded())
    }

    nonisolated static func clampRate(_ rate: Double) -> Double {
        max(minRate, min(rate, maxRate))
    }
}
```

Note: `index(at:)` returns the last index whose start is `<= time`, so equal adjacent timestamps naturally resolve to the later index (AC-U1/AC-U8 "later index wins").

- [ ] **Step 4: Run tests, expect PASS**
- [ ] **Step 5: Commit** `feat: add WordTimeline time-to-index core`

---

### Task 3: SegmentTimeline (pure, re-anchoring)

**Files:**
- Create: `Strobe/Engine/SegmentTimeline.swift`
- Test: `StrobeTests/AudiobookSyncTests.swift`

**Interfaces:**
- Consumes: `WordTimeline`.
- Produces: `struct SegmentTimeline { let wordTimeline: WordTimeline; let segmentBoundaries: [Int] }` with `nonisolated` members `wordCount: Int`, `index(at: TimeInterval) -> Int`, `time(ofWordAt: Int) -> TimeInterval`. Boundaries are each segment's first-word index; segment start times derive as `starts[boundary]`.

- [ ] **Step 1: Write failing tests (AC-U10 plus basics)**

```swift
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
```

- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement**

`Strobe/Engine/SegmentTimeline.swift`:
```swift
import Foundation

struct SegmentTimeline: Equatable {
    let wordTimeline: WordTimeline
    let segmentBoundaries: [Int]

    nonisolated var wordCount: Int { wordTimeline.wordCount }

    nonisolated func index(at time: TimeInterval) -> Int {
        let starts = wordTimeline.starts
        guard !starts.isEmpty else { return 0 }
        let boundaries = segmentBoundaries.isEmpty ? [0] : segmentBoundaries

        var segment = 0
        var low = 0
        var high = boundaries.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let boundary = boundaries[mid]
            if boundary < starts.count && starts[boundary] <= time {
                segment = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        let rangeStart = min(boundaries[segment], starts.count - 1)
        let rangeEnd = segment + 1 < boundaries.count
            ? min(boundaries[segment + 1], starts.count)
            : starts.count

        var result = rangeStart
        for i in rangeStart..<rangeEnd where starts[i] <= time {
            result = i
        }
        return result
    }

    nonisolated func time(ofWordAt index: Int) -> TimeInterval {
        wordTimeline.time(ofWordAt: index)
    }
}
```

Note: the within-segment scan is linear over one segment (a sentence, tens of words at most), which is simpler than a range-bounded binary search and fast enough at 20 Hz.

- [ ] **Step 4: Run, expect PASS**
- [ ] **Step 5: Commit** `feat: add SegmentTimeline two-level lookup with boundary re-anchoring`

---

### Task 4: Import errors, source type, Document model fields

**Files:**
- Modify: `Strobe/Import/DocumentImportError.swift`
- Modify: `Strobe/Import/DocumentImportPipeline.swift` (add `audiobook` case to `DocumentSourceType`)
- Modify: `Strobe/Models/Document.swift`
- Test: `StrobeTests/AudiobookSyncTests.swift`

**Interfaces:**
- Produces error cases: `.unsupportedTimingVersion`, `.malformedTimings`, `.nonMonotonicTimings`, `.timingsExceedAudio`, `.audioProtected`, `.audioCorrupt`, `.audioUnsupported`, `.audioCopyFailed`, `.audiobookPairRequired`.
- Produces `DocumentSourceType.audiobook`.
- Produces on `Document`: `sourceTypeRaw: String?`, `audioFileName: String?`, `wordTimingsBlob: Data?` (external), `segmentBoundariesBlob: Data?` (external), `audioDuration: Double = 0`, `playbackRate: Double = 1.0`, `audioOutputOffset: Double = 0`, `audioContentHash: String?`, computed `sourceType: DocumentSourceType`, `isAudiobook: Bool`, `loadWordTimingsAsync() async -> [Double]?`, `loadSegmentBoundariesAsync() async -> [Int]?`, and a designated audiobook init `Document(id:audiobookTitle:fileName:wordsBlob:wordCount:wordsPerMinute:audioFileName:wordTimingsBlob:segmentBoundariesBlob:audioDuration:audioOutputOffset:audioContentHash:)`.

- [ ] **Step 1: Write failing test**

```swift
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
```

- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement**

`DocumentImportError.swift`: add cases and descriptions inside the enum:
```swift
    case unsupportedTimingVersion
    case malformedTimings
    case nonMonotonicTimings
    case timingsExceedAudio
    case audioProtected
    case audioCorrupt
    case audioUnsupported
    case audioCopyFailed
    case audiobookPairRequired
```
and in `errorDescription`:
```swift
        case .unsupportedTimingVersion:
            return "This timing file uses an unsupported format version. Strobe supports version 2."
        case .malformedTimings:
            return "Could not read this timing file. It may be corrupted or not a Strobe timing file."
        case .nonMonotonicTimings:
            return "This timing file has out-of-order or negative timestamps and can't be used."
        case .timingsExceedAudio:
            return "The timing file is longer than the audio. Check that both files belong to the same book."
        case .audioProtected:
            return "This audio file is DRM-protected and can't be imported. Only DRM-free audio is supported."
        case .audioCorrupt:
            return "Could not decode this audio file. It may be corrupted."
        case .audioUnsupported:
            return "Unsupported audio format. Import an MP3, M4A, or other standard audio file."
        case .audioCopyFailed:
            return "Could not copy the audio into the library. Check available disk space and try again."
        case .audiobookPairRequired:
            return "Select exactly one audio file and one timing file together."
```

`DocumentImportPipeline.swift`: add `case audiobook` to `DocumentSourceType`.

`Document.swift`: add stored properties after `wordsPerMinute`:
```swift
    var sourceTypeRaw: String?
    var audioFileName: String?
    @Attribute(.externalStorage) var wordTimingsBlob: Data?
    @Attribute(.externalStorage) var segmentBoundariesBlob: Data?
    var audioDuration: Double = 0
    var playbackRate: Double = 1.0
    var audioOutputOffset: Double = 0
    var audioContentHash: String?

    @Transient private var cachedWordTimings: [Double]?
    @Transient private var cachedSegmentBoundaries: [Int]?
```
computed properties and loaders (mirror `loadComplexityScoresAsync` pattern):
```swift
    var sourceType: DocumentSourceType {
        sourceTypeRaw.flatMap(DocumentSourceType.init(rawValue:)) ?? .unknown
    }

    var isAudiobook: Bool { sourceType == .audiobook }

    func loadWordTimingsAsync() async -> [Double]? {
        if let cachedWordTimings { return cachedWordTimings }
        guard let wordTimingsBlob, !wordTimingsBlob.isEmpty else { return nil }
        let blob = wordTimingsBlob
        let decoded = await Task.detached(priority: .userInitiated) {
            WordTimingStorage.decode(blob)
        }.value
        cachedWordTimings = decoded
        return decoded
    }

    func loadSegmentBoundariesAsync() async -> [Int]? {
        if let cachedSegmentBoundaries { return cachedSegmentBoundaries }
        guard let segmentBoundariesBlob, !segmentBoundariesBlob.isEmpty else { return nil }
        let blob = segmentBoundariesBlob
        let decoded = await Task.detached(priority: .userInitiated) {
            SegmentBoundaryStorage.decode(blob)
        }.value
        cachedSegmentBoundaries = decoded
        return decoded
    }
```
audiobook init (existing inits stay untouched; their `sourceTypeRaw` stays nil):
```swift
    init(
        id: UUID,
        audiobookTitle: String,
        fileName: String,
        wordsBlob: Data,
        wordCount: Int,
        wordsPerMinute: Int,
        audioFileName: String,
        wordTimingsBlob: Data,
        segmentBoundariesBlob: Data,
        audioDuration: Double,
        audioOutputOffset: Double,
        audioContentHash: String
    ) {
        self.id = id
        self.title = audiobookTitle
        self.fileName = fileName
        self.bookmarkData = Data()
        self.wordsBlob = wordsBlob
        self.complexityBlob = nil
        self.words = []
        self.chapters = []
        self.wordCount = wordCount
        self.currentWordIndex = 0
        self.furthestWordIndex = 0
        self.wordsPerMinute = wordsPerMinute
        self.dateAdded = Date()
        self.sourceTypeRaw = DocumentSourceType.audiobook.rawValue
        self.audioFileName = audioFileName
        self.wordTimingsBlob = wordTimingsBlob
        self.segmentBoundariesBlob = segmentBoundariesBlob
        self.audioDuration = audioDuration
        self.playbackRate = 1.0
        self.audioOutputOffset = audioOutputOffset
        self.audioContentHash = audioContentHash
    }
```

- [ ] **Step 4: Run, expect PASS (all existing tests too, lightweight migration relies on defaults/optionals)**
- [ ] **Step 5: Commit** `feat: audiobook document model fields, source type, import error cases`

---

### Task 5: AudiobookTimingParser (pure)

**Files:**
- Create: `Strobe/Import/AudiobookTimingParser.swift`
- Test: `StrobeTests/AudiobookSyncTests.swift`

**Interfaces:**
- Consumes: `DocumentImportError` cases from Task 4.
- Produces:
```swift
struct ParsedAudiobookTiming: Equatable {
    let words: [String]
    let wordStarts: [Double]
    let segmentBoundaries: [Int]
    let language: String?
}
enum AudiobookTimingParser {
    nonisolated static let maxTimingFileBytes: Int
    nonisolated static let durationTolerance: TimeInterval  // 2.0
    nonisolated static func parse(_ data: Data, audioDuration: TimeInterval, tolerance: TimeInterval) throws -> ParsedAudiobookTiming
}
```

- [ ] **Step 1: Write failing tests (AC-U5 to AC-U9)**

```swift
    private static let exampleTimingJSON = """
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
```

- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement**

`Strobe/Import/AudiobookTimingParser.swift`:
```swift
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
```

- [ ] **Step 4: Run, expect PASS**
- [ ] **Step 5: Commit** `feat: add v2 timing file parser with validation`

---

### Task 6: RSVPEngine playback-controller seam

**Files:**
- Modify: `Strobe/Engine/RSVPEngine.swift`
- Test: `StrobeTests/AudiobookSyncTests.swift`

**Interfaces:**
- Produces:
```swift
protocol RSVPPlaybackController: AnyObject {
    func enginePlay()
    func enginePause()
    func engineSeek(toWordIndex index: Int)
}
```
- On `RSVPEngine`: `weak var playbackController: (any RSVPPlaybackController)?`, `func setIndexFromAudio(_ index: Int)`. `play()` skips the timer and calls `enginePlay()` when a controller is set; `pause()` additionally calls `enginePause()`; `seek(to:)` additionally calls `engineSeek(toWordIndex:)` with the clamped index. `setIndexFromAudio` clamps and sets `currentIndex` without notifying the controller.

- [ ] **Step 1: Write failing tests**

```swift
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
```

- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement**

In `RSVPEngine.swift`, add above the class:
```swift
protocol RSVPPlaybackController: AnyObject {
    func enginePlay()
    func enginePause()
    func engineSeek(toWordIndex index: Int)
}
```
Add property near `complexityScores`:
```swift
    weak var playbackController: (any RSVPPlaybackController)?
```
Replace `play()`, `pause()`, `seek(to:)` bodies:
```swift
    func play() {
        guard !isPlaying, !words.isEmpty, !isAtEnd else { return }
        isPlaying = true
        if let playbackController {
            playbackController.enginePlay()
        } else {
            scheduleNextWord()
        }
    }

    func pause() {
        isPlaying = false
        stopTimer()
        playbackController?.enginePause()
    }

    func seek(to index: Int) {
        currentIndex = max(0, min(index, words.count - 1))
        playbackController?.engineSeek(toWordIndex: currentIndex)
    }

    func setIndexFromAudio(_ index: Int) {
        guard !words.isEmpty else { return }
        currentIndex = max(0, min(index, words.count - 1))
    }
```
Also guard `onPlaybackSettingChanged()` so the WPM-slider reschedule path can never start a timer in audio mode:
```swift
    private func onPlaybackSettingChanged() {
        guard isPlaying, playbackController == nil else { return }
        ...
    }
```

- [ ] **Step 4: Run new tests AND full existing suite, expect PASS (timer path unchanged when controller nil)**
- [ ] **Step 5: Commit** `feat: RSVPEngine playback controller seam for audio-driven mode`

---

### Task 7: PlaybackClock protocol, FakePlaybackClock, AudioSyncCoordinator

**Files:**
- Create: `Strobe/Engine/PlaybackClock.swift`
- Create: `Strobe/Engine/AudioSyncCoordinator.swift`
- Test: `StrobeTests/AudiobookSyncTests.swift` (includes `FakePlaybackClock`)

**Interfaces:**
- Produces `PlaybackClock` (MainActor by app default isolation):
```swift
protocol PlaybackClock: AnyObject {
    var currentTime: TimeInterval { get }
    var rate: Double { get set }
    var onTick: ((TimeInterval) -> Void)? { get set }
    var onDidReachEnd: (() -> Void)? { get set }
    var onDidFail: ((String) -> Void)? { get set }
    var onDidInterrupt: (() -> Void)? { get set }
    func play()
    func pause()
    func seek(to time: TimeInterval, completion: @escaping (Bool) -> Void)
}
```
- Produces `AudioSyncCoordinator` (`@Observable`, conforms `RSVPPlaybackController`): `init(clock:timeline:engine:outputOffset:rate:)` (sets `engine.playbackController = self`, wires clock callbacks, clamps and applies rate), `var outputOffset: TimeInterval` (clamped 0 to 1.0), `private(set) var rate: Double`, `private(set) var transientError: String?`, `var onExternalPause: ((Int) -> Void)?`, `func setRate(_:)`, `func seekAudio(toWordIndex:)`, `func clearTransientError()`, `nonisolated static func effectiveTime(currentTime:outputOffset:) -> TimeInterval`, `nonisolated static func clampOffset(_:) -> TimeInterval`, `static let maxOutputOffset: TimeInterval = 1.0`.

- [ ] **Step 1: Write failing tests (AC-U11, AC-I1 to I5, I9, I10, I13)**

Add `FakePlaybackClock` to the test file:
```swift
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
```
Tests (helper builds the standard rig):
```swift
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
        #expect(AudioSyncCoordinator.effectiveTime(currentTime: 0.6, outputOffset: 0.2) == 0.4)
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
```

- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement**

`Strobe/Engine/PlaybackClock.swift`:
```swift
import Foundation

protocol PlaybackClock: AnyObject {
    var currentTime: TimeInterval { get }
    var rate: Double { get set }
    var onTick: ((TimeInterval) -> Void)? { get set }
    var onDidReachEnd: (() -> Void)? { get set }
    var onDidFail: ((String) -> Void)? { get set }
    var onDidInterrupt: (() -> Void)? { get set }
    func play()
    func pause()
    func seek(to time: TimeInterval, completion: @escaping (Bool) -> Void)
}
```

`Strobe/Engine/AudioSyncCoordinator.swift`:
```swift
import Foundation
import os

@Observable
final class AudioSyncCoordinator: RSVPPlaybackController {

    static let maxOutputOffset: TimeInterval = 1.0

    private let clock: any PlaybackClock
    private let timeline: SegmentTimeline
    private let engine: RSVPEngine
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.abdeen.strobe",
        category: "AudioSync"
    )

    var outputOffset: TimeInterval {
        didSet {
            let clamped = Self.clampOffset(outputOffset)
            if clamped != outputOffset { outputOffset = clamped }
        }
    }

    private(set) var rate: Double
    private(set) var transientError: String?
    var onExternalPause: ((Int) -> Void)?

    private var lastConfirmedIndex = 0
    private var isSeekPending = false
    private var seekGeneration = 0

    init(
        clock: any PlaybackClock,
        timeline: SegmentTimeline,
        engine: RSVPEngine,
        outputOffset: TimeInterval,
        rate: Double
    ) {
        self.clock = clock
        self.timeline = timeline
        self.engine = engine
        self.outputOffset = Self.clampOffset(outputOffset)
        self.rate = WordTimeline.clampRate(rate)
        clock.rate = self.rate
        engine.playbackController = self
        clock.onTick = { [weak self] time in self?.handleTick(at: time) }
        clock.onDidReachEnd = { [weak self] in self?.handleEnd() }
        clock.onDidFail = { [weak self] message in self?.handleFailure(message) }
        clock.onDidInterrupt = { [weak self] in self?.handleInterruption() }
    }

    nonisolated static func effectiveTime(currentTime: TimeInterval, outputOffset: TimeInterval) -> TimeInterval {
        max(0, currentTime - outputOffset)
    }

    nonisolated static func clampOffset(_ offset: TimeInterval) -> TimeInterval {
        max(0, min(offset, maxOutputOffset))
    }

    func enginePlay() {
        transientError = nil
        clock.play()
    }

    func enginePause() {
        clock.pause()
    }

    func engineSeek(toWordIndex index: Int) {
        seekAudio(toWordIndex: index)
    }

    func seekAudio(toWordIndex index: Int) {
        seekGeneration += 1
        let generation = seekGeneration
        isSeekPending = true
        clock.seek(to: timeline.time(ofWordAt: index)) { [weak self] success in
            guard let self, generation == self.seekGeneration else { return }
            self.isSeekPending = false
            if success {
                self.lastConfirmedIndex = index
            } else {
                self.transientError = "Couldn't move the audio position. Restored the last synced word."
                self.engine.setIndexFromAudio(self.lastConfirmedIndex)
            }
        }
    }

    func setRate(_ newRate: Double) {
        rate = WordTimeline.clampRate(newRate)
        clock.rate = rate
    }

    func clearTransientError() {
        transientError = nil
    }

    private func handleTick(at time: TimeInterval) {
        guard !isSeekPending else { return }
        let effective = Self.effectiveTime(currentTime: time, outputOffset: outputOffset)
        let index = timeline.index(at: effective)
        lastConfirmedIndex = index
        if index != engine.currentIndex {
            engine.setIndexFromAudio(index)
        }
        #if DEBUG
        logger.debug("tick wall=\(Date().timeIntervalSince1970, format: .fixed(precision: 3)) audio=\(time, format: .fixed(precision: 3)) index=\(index)")
        #endif
    }

    private func handleEnd() {
        let last = max(0, timeline.wordCount - 1)
        engine.setIndexFromAudio(last)
        lastConfirmedIndex = last
        engine.pause()
    }

    private func handleInterruption() {
        engine.pause()
        onExternalPause?(engine.currentIndex)
    }

    private func handleFailure(_ message: String) {
        transientError = message
        engine.pause()
        onExternalPause?(engine.currentIndex)
    }
}
```

Notes:
- The `#if DEBUG` tick log IS the AC-M5 latency instrumentation harness required by the PRD ops checklist (wall clock, audio time, displayed index per tick, filterable by the `AudioSync` category).
- `seekGeneration` makes rapid scrubbing safe: stale completions (including AVPlayer's cancelled-seek `false`) are ignored.
- `handleEnd` pauses via `engine.pause()`, so ReaderView's existing `onChange(of: engine.isPlaying)` + `isAtEnd` path shows the completion overlay (AC-I13, Feature Parity "Completion overlay").

- [ ] **Step 4: Run, expect PASS**
- [ ] **Step 5: Commit** `feat: AudioSyncCoordinator with clock seam, re-anchoring, seek robustness`

---

### Task 8: AudiobookLibrary + AudiobookImporter

**Files:**
- Create: `Strobe/Import/AudiobookLibrary.swift`
- Create: `Strobe/Import/AudiobookImporter.swift`
- Test: `StrobeTests/AudiobookSyncTests.swift`

**Interfaces:**
- Consumes: `AudiobookTimingParser`, storage helpers, `Document` audiobook init, error cases.
- Produces:
```swift
enum AudiobookLibrary {
    nonisolated static func defaultBaseDirectory() throws -> URL
    nonisolated static func copyAudio(from source: URL, documentID: UUID, into baseDirectory: URL) throws -> String
    nonisolated static func removeAudio(fileName: String, from baseDirectory: URL)
    nonisolated static func audioURL(fileName: String, in baseDirectory: URL) -> URL
}

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
    static func classifyPair(_ urls: [URL]) throws -> (audio: URL, timing: URL)
    static func prepare(audioURL: URL, timingURL: URL) async throws -> AudiobookImportPreview
    static func commit(preview: AudiobookImportPreview, defaultWPM: Int, baseDirectory: URL, insert: (Document) throws -> Void) throws -> Document
}
```

- [ ] **Step 1: Write failing tests (AC-I6, I7, I8, I11, I12)**

Test fixtures and helpers added to the test file:
```swift
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
```
(add `import SwiftData` to the test file imports.)

Tests:
```swift
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

    @Test func invalidTimingRejectedBeforeAnyCopy() async throws {
        let wav = try makeWAVFile()
        let badTiming = try writeTimingFile("{\"version\": 3, \"segments\": []}".data(using: .utf8)!)
        await #expect(throws: DocumentImportError.unsupportedTimingVersion) {
            _ = try await AudiobookImporter.prepare(audioURL: wav, timingURL: badTiming)
        }
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
```

- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement**

`Strobe/Import/AudiobookLibrary.swift`:
```swift
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
```

`Strobe/Import/AudiobookImporter.swift`:
```swift
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
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 4096) else { return false }
        try? handle.close()
        guard let text = String(data: head, encoding: .utf8) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{")
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
            suggestedOutputOffset: AudiobookImporter.seededOutputOffset(),
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
```

- [ ] **Step 4: Run, expect PASS**
- [ ] **Step 5: Commit** `feat: audiobook import pipeline (validate, preview, atomic commit, cleanup)`

---

### Task 9: AVPlaybackClock (AVFoundation shell)

**Files:**
- Create: `Strobe/Engine/AVPlaybackClock.swift`

**Interfaces:**
- Consumes: `PlaybackClock`.
- Produces: `final class AVPlaybackClock: PlaybackClock` with `init(url: URL)` and `func invalidate()` (removes observers; ReaderView calls it on disappear). Manual verification layer per PRD (AC-M1 to AC-M6); no automated tests beyond compiling.

- [ ] **Step 1: Implement**

`Strobe/Engine/AVPlaybackClock.swift`:
```swift
import Foundation
import AVFoundation

final class AVPlaybackClock: PlaybackClock {

    private let player: AVPlayer
    private let item: AVPlayerItem
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    #if os(iOS)
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    #endif

    private var wantsPlayback = false

    var rate: Double = 1.0 {
        didSet {
            if wantsPlayback {
                player.rate = Float(rate)
            }
        }
    }

    var onTick: ((TimeInterval) -> Void)?
    var onDidReachEnd: (() -> Void)?
    var onDidFail: ((String) -> Void)?
    var onDidInterrupt: (() -> Void)?

    var currentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    init(url: URL) {
        item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral
        player = AVPlayer(playerItem: item)

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                self.onTick?(time.seconds)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.wantsPlayback = false
                self.onDidReachEnd?()
            }
        }

        statusObservation = item.observe(\.status) { [weak self] observedItem, _ in
            guard observedItem.status == .failed else { return }
            let message = observedItem.error?.localizedDescription ?? "Audio playback failed."
            Task { @MainActor [weak self] in
                self?.wantsPlayback = false
                self?.onDidFail?(message)
            }
        }

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                self.wantsPlayback = false
                self.onDidInterrupt?()
            }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
                self.wantsPlayback = false
                self.onDidInterrupt?()
            }
        }
        #endif
    }

    func play() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        wantsPlayback = true
        player.playImmediately(atRate: Float(rate))
    }

    func pause() {
        wantsPlayback = false
        player.pause()
    }

    func seek(to time: TimeInterval, completion: @escaping (Bool) -> Void) {
        let target = CMTime(seconds: max(0, time), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in
                completion(finished)
            }
        }
    }

    func invalidate() {
        pause()
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        #if os(iOS)
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
            self.routeChangeObserver = nil
        }
        #endif
    }
}
```

Notes:
- `.spectral` preserves pitch across 0.5x to 3x (AC-M1 verifies audibly on device).
- Rate is applied only while playing; `AVPlayer.rate` assignment while paused would otherwise start playback.
- Interruption-began and route-loss both funnel to `onDidInterrupt` (coordinator pauses, stays paused per PRD resume policy). Interruption-ended is deliberately ignored.
- `invalidate()` is the explicit teardown because deinit of a MainActor class cannot touch isolated state.

- [ ] **Step 2: Build both platforms compile: run full test suite (compiles app target), expect PASS**
- [ ] **Step 3: Commit** `feat: AVPlaybackClock AVFoundation shell`

---

### Task 10: ReaderView audio mode

**Files:**
- Modify: `Strobe/Views/ReaderView.swift`

**Interfaces:**
- Consumes: `AudioSyncCoordinator`, `AVPlaybackClock`, `SegmentTimeline`, `WordTimeline`, `AudiobookLibrary`, `Document` audio fields.
- Produces: audio-driven reader with rate slider, offset nudge, media-missing state, audio-aware persistence. Verified by build + existing tests + manual flows (Flow B, C, D, E).

- [ ] **Step 1: Add state and init support**

Add to ReaderView state block:
```swift
    @State private var coordinator: AudioSyncCoordinator?
    @State private var audioClock: AVPlaybackClock?
    @State private var audioTimeline: SegmentTimeline?
    @State private var isAudioUnavailable = false
    @State private var rateSliderValue: Double
    @State private var isAdjustingRate = false
```
In `init`, after `_wpmSliderValue`:
```swift
        self._rateSliderValue = State(initialValue: WordTimeline.clampRate(document.playbackRate))
```

- [ ] **Step 2: Audio configuration in load path**

In `loadDocumentIfNeeded()`, change the backfill condition and add the audio branch. Replace:
```swift
        if scores == nil && complexityTimingEnabled {
            backfillComplexityScores()
        }
```
with:
```swift
        if document.isAudiobook {
            await configureAudioPlayback()
        } else if scores == nil && complexityTimingEnabled {
            backfillComplexityScores()
        }
```
Add method:
```swift
    private func configureAudioPlayback() async {
        guard let fileName = document.audioFileName,
              let baseDirectory = try? AudiobookLibrary.defaultBaseDirectory() else {
            isAudioUnavailable = true
            return
        }
        let url = AudiobookLibrary.audioURL(fileName: fileName, in: baseDirectory)
        guard FileManager.default.fileExists(atPath: url.path),
              let timings = await document.loadWordTimingsAsync(),
              let boundaries = await document.loadSegmentBoundariesAsync(),
              !timings.isEmpty,
              timings.count == engine.words.count else {
            isAudioUnavailable = true
            return
        }
        let timeline = SegmentTimeline(
            wordTimeline: WordTimeline(starts: timings),
            segmentBoundaries: boundaries
        )
        let clock = AVPlaybackClock(url: url)
        let syncCoordinator = AudioSyncCoordinator(
            clock: clock,
            timeline: timeline,
            engine: engine,
            outputOffset: document.audioOutputOffset,
            rate: document.playbackRate
        )
        syncCoordinator.onExternalPause = { _ in
            persistState(pauseEngine: false, touchLastReadDate: false)
        }
        audioClock = clock
        audioTimeline = timeline
        coordinator = syncCoordinator
        rateSliderValue = syncCoordinator.rate
        syncCoordinator.seekAudio(toWordIndex: engine.currentIndex)
    }
```

- [ ] **Step 3: Gate playback when audio is unavailable**

In `schedulePlayIntent`'s work item guard, `togglePlayback()`, and the gesture `.onEnded` tap-to-toggle branch, add `!isAudioUnavailable` alongside the existing conditions (an audiobook without its media must not silently play as a text document). Concretely:
- `schedulePlayIntent` work item: `guard isTouching, touchMode == .undecided, !showCompletion, !isAudioUnavailable else { return }`
- `togglePlayback()`: first line `guard !isAudioUnavailable else { return }`
- gesture `.onEnded`: wrap the tap-toggle block in `if !isAudioUnavailable { ... }` (scrubbing may stay enabled).

- [ ] **Step 4: Media-missing card**

In `body`, replace the word view branch:
```swift
                if showCompletion {
                    completionView...
                } else {
                    CurrentWordView(...)
                }
```
with an extra branch before the word view:
```swift
                if showCompletion {
                    completionView
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                } else if isAudioUnavailable {
                    audioUnavailableView
                } else {
                    CurrentWordView(engine: engine, fontSize: CGFloat(fontSize))
                    ...
                }
```
Add:
```swift
    private var audioUnavailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "headphones.slash")
                .font(.system(size: 40))
                .foregroundStyle(StrobeTheme.accent)
            Text("Audio Missing")
                .font(StrobeTheme.titleFont(size: 24))
                .foregroundStyle(StrobeTheme.textPrimary)
            Text("The audio file for this book could not be found. Delete the document and import it again.")
                .font(StrobeTheme.bodyFont(size: 15))
                .foregroundStyle(StrobeTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .background(StrobeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 24)
    }
```

- [ ] **Step 5: Rate control replacing the WPM slider in audio mode**

In `topBarContent`, wrap the existing WPM HStack:
```swift
            if document.isAudiobook {
                audioRateControl
            } else {
                // existing WPM HStack unchanged
            }
```
Add:
```swift
    private var audioRateControl: some View {
        HStack {
            Text("\(audioDisplayedWPM)")
                .font(StrobeTheme.bodyFont(size: 24, bold: true))
                .foregroundStyle(StrobeTheme.accent)
                .frame(width: 80)

            VStack(alignment: .leading, spacing: 0) {
                Text("wpm")
                    .font(StrobeTheme.bodyFont(size: 14))
                    .foregroundStyle(StrobeTheme.textSecondary)
                Text(String(format: "%.2fx", rateSliderValue))
                    .font(StrobeTheme.bodyFont(size: 11))
                    .foregroundStyle(StrobeTheme.textSecondary)
            }

            Slider(value: $rateSliderValue, in: WordTimeline.minRate...WordTimeline.maxRate, step: 0.05) { editing in
                isAdjustingRate = editing
                if !editing {
                    applyRate(rateSliderValue, withHaptic: true)
                }
            }
            .tint(StrobeTheme.accent)
            .frame(minHeight: 44)
            .accessibilityLabel("Playback speed")
            .accessibilityValue("\(audioDisplayedWPM) words per minute at \(String(format: "%.2f", rateSliderValue)) times speed")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(StrobeTheme.surface.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .opacity(engine.isPlaying ? 0.0 : 1.0)
        .allowsHitTesting(!engine.isPlaying)
    }

    private var audioDisplayedWPM: Int {
        WordTimeline.displayedWPM(
            wordCount: document.wordCount,
            duration: document.audioDuration,
            rate: rateSliderValue
        )
    }

    private func applyRate(_ value: Double, withHaptic: Bool) {
        guard let coordinator else { return }
        coordinator.setRate(value)
        rateSliderValue = coordinator.rate
        document.playbackRate = coordinator.rate
        if withHaptic {
            HapticManager.shared.selectionTick()
        }
    }
```

- [ ] **Step 6: Offset nudge in the bottom bar (audio only)**

In `bottomBar`, after `ProgressScrubberView`, add:
```swift
            if document.isAudiobook, coordinator != nil {
                audioSyncNudge
            }
```
Add:
```swift
    private var audioSyncNudge: some View {
        HStack(spacing: 12) {
            Text("Audio sync")
                .font(StrobeTheme.bodyFont(size: 13))
                .foregroundStyle(StrobeTheme.textSecondary)
            Spacer()
            CircleIconButton(systemImage: "minus", accessibilityLabel: "Decrease audio offset") {
                adjustOutputOffset(by: -0.025)
            }
            Text("\(Int(((coordinator?.outputOffset ?? 0) * 1000).rounded())) ms")
                .font(StrobeTheme.bodyFont(size: 13, bold: true))
                .foregroundStyle(StrobeTheme.textPrimary)
                .frame(width: 64)
            CircleIconButton(systemImage: "plus", accessibilityLabel: "Increase audio offset") {
                adjustOutputOffset(by: 0.025)
            }
        }
    }

    private func adjustOutputOffset(by delta: TimeInterval) {
        guard let coordinator else { return }
        coordinator.outputOffset += delta
        document.audioOutputOffset = coordinator.outputOffset
        HapticManager.shared.selectionTick()
    }
```

- [ ] **Step 7: Persistence, teardown, error alert, backfill guard**

In `persistState`, after the `isAdjustingWPM` block add:
```swift
        if isAdjustingRate {
            isAdjustingRate = false
            applyRate(rateSliderValue, withHaptic: false)
        }
        if document.isAudiobook, let coordinator {
            document.playbackRate = coordinator.rate
            document.audioOutputOffset = coordinator.outputOffset
        }
```
In `.onDisappear`, before `persistState`:
```swift
        .onDisappear {
            persistState(pauseEngine: true, touchLastReadDate: true)
            audioClock?.invalidate()
            engine.playbackController = nil
        }
```
(order: persist first pauses the engine which pauses the clock; then invalidate.)

Add an alert for the coordinator's transient error after the existing Save Error alert:
```swift
        .alert("Audio Error", isPresented: Binding(
            get: { coordinator?.transientError != nil },
            set: { if !$0 { coordinator?.clearTransientError() } }
        )) {
            Button("OK") { coordinator?.clearTransientError() }
        } message: {
            Text(coordinator?.transientError ?? "")
        }
```
In `.onChange(of: complexityTimingEnabled)` add `&& !document.isAudiobook` to the backfill condition.

- [ ] **Step 8: Run full test suite, expect PASS. Commit** `feat: audio-driven reader mode (rate control, offset nudge, media-missing state)`

---

### Task 11: ContentView import flow, preview sheet, delete cleanup, card badge

**Files:**
- Create: `Strobe/Views/AudiobookImportPreviewView.swift`
- Modify: `Strobe/Views/ContentView.swift`

**Interfaces:**
- Consumes: `AudiobookImporter`, `AudiobookLibrary`, `AudiobookImportPreview`.
- Produces: "Import Audiobook" action, two-file picker, preview confirmation, duplicate alert (Replace / Keep Both), audio cleanup on delete, headphones card badge. Verified by build + manual Flow A; logic paths (commit policies, cleanup) are covered by Task 8 tests.

- [ ] **Step 1: Preview sheet view**

`Strobe/Views/AudiobookImportPreviewView.swift`:
```swift
import SwiftUI

struct AudiobookImportPreviewView: View {
    let preview: AudiobookImportPreview
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var formattedDuration: String {
        let total = Int(preview.audioDuration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(StrobeTheme.accent.opacity(0.1))
                    .frame(width: 72, height: 72)
                Image(systemName: "headphones")
                    .font(.system(size: 32))
                    .foregroundStyle(StrobeTheme.accent)
            }
            .padding(.top, 32)

            VStack(spacing: 8) {
                Text(preview.title)
                    .font(StrobeTheme.titleFont(size: 24))
                    .foregroundStyle(StrobeTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Text("\(formattedDuration) · \(preview.wordCount) words · \(preview.segmentCount) segments")
                    .font(StrobeTheme.bodyFont(size: 14))
                    .foregroundStyle(StrobeTheme.textSecondary)
            }

            Text(preview.previewWords.joined(separator: " ") + (preview.wordCount > preview.previewWords.count ? " ..." : ""))
                .font(StrobeTheme.bodyFont(size: 16))
                .foregroundStyle(StrobeTheme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(StrobeTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 24)

            Text("Check that these opening words match the audiobook before importing.")
                .font(StrobeTheme.bodyFont(size: 13))
                .foregroundStyle(StrobeTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(StrobeTheme.bodyFont(size: 16, bold: true))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 16)
                        .background(Color.white.opacity(0.08))
                        .foregroundStyle(StrobeTheme.textPrimary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: onConfirm) {
                    Text("Import")
                        .font(StrobeTheme.bodyFont(size: 16, bold: true))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 16)
                        .background(StrobeTheme.accent)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrobeTheme.Gradients.mainBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
```

- [ ] **Step 2: ContentView state + menu + picker**

Add state:
```swift
    @State private var isImportingAudiobook = false
    @State private var audiobookPreview: AudiobookImportPreview?
    @State private var audiobookDuplicate: Document?
    @State private var audiobookScopedURLs: [URL] = []
```
Add to the FAB `Menu` after "Import File":
```swift
            Button {
                isImportingAudiobook = true
            } label: {
                Label("Import Audiobook", systemImage: "headphones")
            }
```
Attach a second file importer via background (a view supports only one `.fileImporter` per node):
```swift
            .background(
                Color.clear
                    .fileImporter(
                        isPresented: $isImportingAudiobook,
                        allowedContentTypes: [.audio, .json],
                        allowsMultipleSelection: true
                    ) { result in
                        handleAudiobookImport(result)
                    }
            )
```
placed on the same `ZStack` the existing `.fileImporter` hangs off.

Add sheet + duplicate alert:
```swift
            .sheet(item: $audiobookPreview) { preview in
                AudiobookImportPreviewView(
                    preview: preview,
                    onConfirm: { confirmAudiobookImport(preview) },
                    onCancel: { cancelAudiobookImport() }
                )
                #if os(macOS)
                .frame(minWidth: 500, minHeight: 560)
                #endif
            }
            .alert(
                "Already in Library",
                isPresented: .init(isPresent: $audiobookDuplicate),
                presenting: audiobookDuplicate
            ) { existing in
                Button("Replace") {
                    if let preview = pendingDuplicatePreview {
                        commitAudiobook(preview, replacing: existing)
                    }
                    audiobookDuplicate = nil
                }
                Button("Keep Both") {
                    if let preview = pendingDuplicatePreview {
                        commitAudiobook(preview, replacing: nil)
                    }
                    audiobookDuplicate = nil
                }
                Button("Cancel", role: .cancel) {
                    audiobookDuplicate = nil
                    pendingDuplicatePreview = nil
                    stopAudiobookScopes()
                }
            } message: { existing in
                Text("This audio matches \"\(existing.title)\". Replace it or keep both?")
            }
```
with one more state var:
```swift
    @State private var pendingDuplicatePreview: AudiobookImportPreview?
```

- [ ] **Step 3: Import logic in the ContentView extension**

```swift
    private func handleAudiobookImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            beginAudiobookImport(urls: urls)
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func beginAudiobookImport(urls: [URL]) {
        guard !isProcessingImport else {
            importError = "Another import is still in progress. Wait for it to finish or cancel it first."
            return
        }
        audiobookScopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        isProcessingImport = true
        importFileName = urls.first?.lastPathComponent ?? "audiobook"
        importTask = Task(priority: .userInitiated) {
            defer {
                isProcessingImport = false
                importFileName = ""
                importTask = nil
            }
            do {
                let pair = try AudiobookImporter.classifyPair(urls)
                let preview = try await AudiobookImporter.prepare(
                    audioURL: pair.audio,
                    timingURL: pair.timing
                )
                audiobookPreview = preview
            } catch is CancellationError {
                stopAudiobookScopes()
            } catch {
                stopAudiobookScopes()
                if let localizedError = error as? LocalizedError,
                   let message = localizedError.errorDescription {
                    importError = message
                } else {
                    importError = error.localizedDescription
                }
            }
        }
    }

    private func confirmAudiobookImport(_ preview: AudiobookImportPreview) {
        audiobookPreview = nil
        if let existing = documents.first(where: { $0.audioContentHash == preview.contentHash }) {
            pendingDuplicatePreview = preview
            audiobookDuplicate = existing
            return
        }
        commitAudiobook(preview, replacing: nil)
    }

    private func cancelAudiobookImport() {
        audiobookPreview = nil
        stopAudiobookScopes()
    }

    private func commitAudiobook(_ preview: AudiobookImportPreview, replacing existing: Document?) {
        pendingDuplicatePreview = nil
        do {
            let baseDirectory = try AudiobookLibrary.defaultBaseDirectory()
            if let existing {
                let oldAudio = existing.audioFileName
                modelContext.delete(existing)
                if let oldAudio {
                    AudiobookLibrary.removeAudio(fileName: oldAudio, from: baseDirectory)
                }
            }
            _ = try AudiobookImporter.commit(
                preview: preview,
                defaultWPM: defaultWPM,
                baseDirectory: baseDirectory
            ) { document in
                modelContext.insert(document)
                try modelContext.save()
            }
        } catch {
            if let localizedError = error as? LocalizedError,
               let message = localizedError.errorDescription {
                importError = message
            } else {
                importError = error.localizedDescription
            }
        }
        stopAudiobookScopes()
    }

    private func stopAudiobookScopes() {
        for url in audiobookScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        audiobookScopedURLs = []
    }
```

- [ ] **Step 4: Delete cleanup + card badge**

Change `saveOrReport` to report success:
```swift
    @discardableResult
    private func saveOrReport(_ what: String) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            persistenceError = "\(what): \(error.localizedDescription)"
            return false
        }
    }
```
In the delete alert action:
```swift
                Button("Delete", role: .destructive) {
                    let audioFileName = doc.audioFileName
                    modelContext.delete(doc)
                    if saveOrReport("Could not delete the document"),
                       let audioFileName,
                       let baseDirectory = try? AudiobookLibrary.defaultBaseDirectory() {
                        AudiobookLibrary.removeAudio(fileName: audioFileName, from: baseDirectory)
                    }
                    documentPendingDeletion = nil
                }
```
In `DocumentCard`, swap the icon:
```swift
                Image(systemName: document.isAudiobook ? "headphones" : "text.book.closed.fill")
```

- [ ] **Step 5: Run full test suite, expect PASS. Commit** `feat: audiobook import flow with preview, duplicate handling, delete cleanup`

---

### Task 12: Docs and final verification

**Files:**
- Create: `docs/audiobook-timing-format.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Write `docs/audiobook-timing-format.md`** covering: schema v2 (the PRD example JSON), field semantics (`w` verbatim token, `s` monotonic onset seconds, segment `s` equals first word's `s`), validation rules the app enforces (version 2, monotonic, non-negative, last start within duration + 2 s, 64 MB cap), and the generation guidance from the PRD (forced alignment: WhisperX / Montreal Forced Aligner / aeneas; word-level ASR fallback: WhisperX / faster-whisper; prefer CBR MP3 or m4a for seek accuracy; sentence-level segments).
- [ ] **Step 2: Update `CLAUDE.md`**: architecture section gains the audio pipeline (import: audio + timing pair -> `AudiobookTimingParser` -> blobs; playback: `AVPlaybackClock` -> `AudioSyncCoordinator` -> `SegmentTimeline` -> `RSVPEngine.setIndexFromAudio`), the folder additions, the audiobook `Document` fields, and the manual-verification note (AC-M1 to AC-M6 are device-only).
- [ ] **Step 3: Run the FULL suite** on macOS destination; fix anything red.
- [ ] **Step 4: Manual acceptance checklist** (document as remaining device work, do not claim automated): AC-M1 pitch, AC-M2 call, AC-M3 unplug, AC-M4 background/sleep, AC-M5 latency log sampling via the `AudioSync` debug category, AC-M6 Bluetooth offset.
- [ ] **Step 5: Commit** `docs: audiobook timing format guide and architecture notes`

---

## Self-Review Notes

- Spec coverage: Flow A -> Tasks 8+11; Flow B/C/D/E -> Tasks 6+7+10; parity matrix rows all route through the engine seam (Task 6) plus rate control (Task 10); AC-U* -> Tasks 1-5+7; AC-I* -> Tasks 7-8; AC-M* -> manual, Task 12 checklist; PRD ops checklist (latency harness -> coordinator debug log; docs -> Task 12; DRM gating -> Task 8 `prepare`).
- Consciously omitted from v1 (PRD open questions resolved above): chapter derivation, lock-screen audio, WebVTT fallback parser.
- Types cross-checked: `SegmentTimeline(wordTimeline:segmentBoundaries:)`, `AudioSyncCoordinator(clock:timeline:engine:outputOffset:rate:)`, `AudiobookImporter.commit(preview:defaultWPM:baseDirectory:insert:)`, `Document(id:audiobookTitle:...)` used consistently in Tasks 7, 8, 10, 11.
