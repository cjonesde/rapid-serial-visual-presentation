# Audiobook Sync
## Read word-by-word in Strobe while an MP3 audiobook plays, with the on-screen word locked to the spoken word and self-correcting when the timing file drifts.

Team: Strobe (solo)
Contributors: Product/Eng (owner)
Status: Draft (Problem Review pending)

---

# Problem Alignment

## Problem Statement

Strobe presents text one word at a time (RSVP) at a reader-controlled pace. Audiobooks present the same text as speech at the narrator's pace. Today these are two separate experiences: you either read with your eyes or listen with your ears, and there is no way to do both in lockstep. The goal is a single mode where an MP3 audiobook plays and the RSVP display shows the word currently being spoken, so the reader can follow the narration visually while listening. (Motivation, not a measured claim: read-along pairing is widely used to aid focus and pacing. This PRD sets a sync-accuracy metric, not a comprehension metric.)

## Evidence

- Direct owner request: pair a known MP3 audiobook with a companion timing file produced elsewhere, then read along in Strobe with existing controls (WPM, hold-to-read) intact but synced to the audio.
- Established prior art for value: EPUB 3 Media Overlays, Amazon Whispersync for Voice, and karaoke-style read-along apps all pair text with audio at a word or phrase granularity.
- The app already owns every visual primitive this needs (word rendering, ORP highlight, scrubbing, chapters, passage view). The missing capability is a clock that comes from audio instead of a timer, plus a recovery mechanism for imperfect timing data.

## High-Level Approach

Invert the clock. In normal reading, `RSVPEngine` advances the word index on a timer whose interval is derived from WPM. In audio mode, the audio player's playback position becomes the source of truth: a coordinator watches the player's current time and sets the word index by looking up a timing table. The word shown follows the audio. The existing WPM control is repurposed as a playback-rate control (0.5x to 3x); the number displayed is the narrator's average pace multiplied by the current rate.

The companion file carries hierarchical timing: segments (sentences) each with a start time, containing words each with a start time. Segments are the recovery mechanism. The coordinator resolves position in two levels, segment first then word within it, and re-anchors at every segment boundary. So a local word-level misalignment (a dropped word, a narrator ad-lib, a chapter intro) self-corrects by the end of its segment instead of drifting for the rest of the book. Producing the file (speech-to-text or forced alignment) happens on a separate device and is out of scope. The app is player only: import, pair, store, play back in sync, and re-anchor.

## Goals

1. **Exact word sync (primary, measurable):** at 1.0x on wired or built-in output, the displayed word matches the spoken word within 150 ms of its spoken onset, with drift bounded and self-correcting per Goal 5. Measured per AC-M5.
2. **Feature parity (measurable per feature):** every row of the Feature Parity Matrix maps to a named acceptance criterion. "Works" means that criterion passes, not an assertion.
3. **Speed control preserves sync (measurable):** at 0.5x, 1x, 2x, and 3x, the shown word matches the spoken word to the same tolerance as Goal 1, verified at each rate (AC-M5).
4. **Robust real-world playback (measurable rules):** on interruption, route loss, or backgrounding, audio and text pause within one run loop and the persisted index equals the shown index. Failed or delayed seeks, end-of-item, and stale persisted positions have defined handling (AC-I5, AC-I9, AC-M2 to AC-M4).
5. **Graceful misalignment recovery (measurable):** a single dropped or extra word in the timing file self-corrects by the end of its segment; the visible word error is bounded to at most one segment (AC-U10, AC-I10).

## Non-Goals

1. **Creating the timing file (speech-to-text / forced alignment)** — done on a separate device. The app never transcribes or aligns. It only consumes a supplied file. Recommended generation setup is documented below as guidance only.
2. **Lock-screen / background audio playback** — RSVP requires eyes on the screen, so audio auto-pauses when the app backgrounds. No Now Playing controls or background audio mode in this version.
3. **Manual per-word timing editing** — the app never lets the reader hand-edit individual word times. It does auto-recover from local drift (segment re-anchoring), does expose a single global audio-output offset for latency compensation (see Key Features), and does support re-importing a corrected file. It does not become a caption editor.
4. **Playing DRM-protected audio** — the app must not defeat or circumvent DRM. Only non-protected, user-supplied audio (for example DRM-free MP3) plays. Detecting protection and rejecting it cleanly is a real feature with platform-specific edge cases; it lives in Key Features and Key Logic, not here.
5. **Independent WPM in audio mode** — excluded because it breaks the exact-word-sync requirement. Speed is always a rate applied to the audio clock.

🛑 **Checkpoint:** Confirm problem framing and non-goals before solution sign-off.

---

# Solution Alignment

## Key Features (Plan of Record)

1. **Audiobook import flow.** A dedicated "Import audiobook" action lets the reader pick an audio file and its companion timing file together in one step, shows a confirmation preview (title, first ~20 words, audio duration, segment/word counts) so a wrong-book pairing is caught before commit, then validates the pair, copies the audio into its own library, stores words + segment boundaries + timings, and creates a synced document.
2. **Audio-driven playback clock.** A coordinator binds the audio player's position to `RSVPEngine.currentIndex` via a two-level (segment then word) timing lookup, replacing the internal timer while an audio document is open.
3. **Segment-anchored re-sync.** The coordinator re-anchors the word index at each segment boundary, bounding any word-level misalignment to a single segment (Goal 5).
4. **Audio-output offset calibration.** A single global offset compensates output latency (notably Bluetooth, which adds ~150 to 200 ms). Seeded from `AVAudioSession.outputLatency` and adjustable by the reader with a small nudge control. This is latency compensation, not timing editing.
5. **Rate control repurposing the WPM slider.** The slider sets playback rate (0.5x to 3x) with preserved pitch. The displayed number is derived (average narrator WPM times rate).
6. **Synced transport controls.** Play/pause (hold-to-read and tap-to-read), scrubbing, the progress bar, chapter navigation, and arrow keys all move audio and text together.
7. **Protection / format gating.** On import, detect DRM-protected or undecodable audio and reject it with a specific, distinct error (protected vs corrupt vs unsupported).
8. **Robust audio session handling.** Correct pause/resume on interruptions, headphone unplug, and route changes; auto-pause of both audio and text on backgrounding; position persisted and restored on reopen.

## Future Considerations

- Lock-screen / background audio with Now Playing controls (deferred; builds on the same coordinator).
- Deriving chapter marks from segment structure or m4b chapter metadata.
- A companion "align on device" helper or shortcut, still outside the app binary.

## Companion File Format (Recommendation)

**Recommended: hierarchical segment-and-word JSON (schema v2).** Segments (sentences) each carry a start time and a list of words, each with its own start time. Rationale:

- RSVP shows one word at a time, so every word needs its own timestamp. Subtitle formats (SRT, WebVTT) are cue-based: a cue spans a whole phrase with one start/end, so per-word timing would have to be interpolated. That produces visible drift within a sentence.
- Flat word-only JSON (the earlier proposal) was rejected: it loses sentence provenance, which is exactly what the recovery mechanism needs. Without segment boundaries there is nothing to re-anchor to, so a single bad word time drifts unbounded (the failure mode this PRD is built to prevent).
- Hierarchical JSON still flattens trivially to the app's `[String]` word array (concatenate segment words in order), while retaining the boundaries the coordinator re-anchors on.

Proposed schema (versioned so the parser can reject unknown shapes):

```json
{
  "version": 2,
  "audio": "the-hobbit.mp3",
  "language": "en",
  "segments": [
    {
      "s": 0.42,
      "words": [
        { "w": "In",   "s": 0.42 },
        { "w": "a",     "s": 0.55 },
        { "w": "hole",  "s": 0.61 }
      ]
    },
    {
      "s": 0.94,
      "words": [
        { "w": "in",     "s": 0.94 },
        { "w": "the",    "s": 1.02 },
        { "w": "ground", "s": 1.10 }
      ]
    }
  ]
}
```

- `w` is the display token exactly as it should appear on screen (the app does not re-tokenize in audio mode; see Key Logic).
- `s` is the spoken onset in seconds from the start of the audio (required, monotonic non-decreasing across all words and across all segment starts).
- A segment's `s` equals its first word's `s`.
- Word `e` (offset) may be added later for optional highlight refinements; not required for sync.
- Internally the app stores flattened word start times (Float64 seconds) plus segment boundaries (the first-word index of each segment).

**Acceptable fallback:** WebVTT/SRT with genuine per-word cues grouped by cue-as-segment. More verbose, poorly emitted by tooling, and still needs the segment grouping. Documented only as a fallback; hierarchical JSON is the target.

## Generation Setup (out of app scope, guidance only)

The app never generates timings. Recommended pipeline on the separate device, in order of accuracy:

1. **Forced alignment (best when you have the exact book text).** Align the known transcript to the audio for accurate word onsets, and segment by sentence. Tools: WhisperX (alignment stage plus its segment output), Montreal Forced Aligner, or aeneas (fragment-level; good for the segment layer). Highest accuracy because the words are known and only their times are estimated.
2. **Word-level ASR (when you only have audio).** WhisperX or faster-whisper emit both segments and word timestamps in one pass. Slightly looser token boundaries than forced alignment.

Both routes emit segments plus per-word start times; a small script serializes them into the v2 schema. **Audio caveat:** VBR MP3 seek/time accuracy depends on a valid Xing/VBRI header; for the tightest seek behavior prefer CBR MP3 or m4a/aac. This guidance ships in the repo docs, not in the app.

## Data Model Changes

- **`DocumentSourceType`**: add a case `audiobook` (alongside `pdf`, `epub`, `plainText`).
- **`Document`**: add
  - `audioFileName: String?` and a copy resolved under Application Support (for example `audio/<document-uuid>.<ext>`), so the file is self-contained and survives the original being moved or deleted.
  - `wordTimingsBlob: Data?` (`@Attribute(.externalStorage)`) — flattened word start times as Float64 binary, decoded off-main like `complexityBlob`.
  - `segmentBoundariesBlob: Data?` (`@Attribute(.externalStorage)`) — Int32 array of the first-word index of each segment; segment start times derive as `wordStarts[boundary]`. This is all `SegmentTimeline` needs.
  - `audioDuration: Double` — for average WPM and seek bounds.
  - `playbackRate: Double` (default 1.0) — the audio-mode analog of `wordsPerMinute`.
  - `audioOutputOffset: Double` (default seeded from `AVAudioSession.outputLatency`) — latency compensation.
- **New `WordTimingStorage`** helper mirroring `WordStorage`/`ComplexityStorage`: encode/decode `[Double]` (Float64 seconds) exactly (AC-U4). Storage cost is negligible (~800 KB for a 100k-word book).
- **Cleanup:** deleting an audiobook document must delete its copied audio file (SwiftData external storage handles the blobs; the copied media file needs an explicit delete hook). Import that is cancelled or fails after the copy starts must remove the partial copy (AC-I12).

## Sync Architecture (clock inversion + re-anchoring)

- **Player:** `AVPlayer` with an `AVPlayerItem`, `audioTimePitchAlgorithm` set to a pitch-preserving mode so 0.5x to 3x sounds natural. `AVPlayer.addPeriodicTimeObserver` (~20 Hz) drives sync.
- **Two-level lookup (`SegmentTimeline`, pure):** given `effectiveTime = max(0, currentTime - audioOutputOffset)`, first binary-search the segment start times for the current segment, then resolve the word within that segment's word range. Returns a global word index. This is the re-anchoring: the segment index constrains the word index, so a wrong within-segment word time cannot push the display outside the current segment, and the next boundary resets it.
- **Coordinator (`AudioSyncCoordinator`, new):** owns a `PlaybackClock`, a `SegmentTimeline`, and the `RSVPEngine`. On each tick it computes `SegmentTimeline.index(at: effectiveTime)` and, if it differs from `engine.currentIndex`, calls `engine.seek(to:)`.
- **Engine mode:** in audio mode the `DispatchSourceTimer` is not scheduled; `play()`/`pause()` delegate to the coordinator. Smart-timing, sentence-pause, and complexity-timing multipliers are inert (per-word duration is fixed by audio) and are hidden in the audio-mode UI.
- **Scrub semantics (single source of truth):** all seek gestures operate on the **word index**, then map to audio time via `SegmentTimeline.time(ofWordAt:)`. The progress bar represents percentage of words (consistent with text mode), not percentage of audio time. This removes the ambiguity between word-index, audio-time, percentage, and chapter-relative scrubbing: everything routes through word index.
- **Rate:** the slider writes `clock.rate` (mapped to 0.5x to 3x). Displayed WPM equals average narrator WPM (wordCount / audioDuration * 60) times the current rate.
- **Persistence:** on background, disappear, and terminate, persist `currentWordIndex`, `playbackRate`, and `audioOutputOffset`; on reopen, seek the player to the stored word's start time. Word index (not raw audio time) is the single persisted source of truth.

### Latency / tolerance model

The 150 ms target is a budget, not a guarantee. Contributions:

- Observer cadence: ~50 ms at 20 Hz.
- Main-thread scheduling and render: tens of ms under load.
- Seek latency: `AVPlayer.seek` is asynchronous; the completion signal must gate "we are actually there."
- Output latency: wired/built-in is small; Bluetooth adds ~150 to 200 ms. This is compensated by `audioOutputOffset`, not absorbed by the budget.

Measurement (AC-M5): log `(wallClock, currentTime, displayedIndex)` on each tick and compare the displayed word's onset to `effectiveTime`; sample across rates and output routes. If the wired-output budget cannot be held at a given rate, that is a finding, not a silent pass.

## Testability Architecture (pure core / thin shell)

TDD is only possible if the sync logic does not require a running audio device. The design splits into a pure, fully unit-testable core and a thin AVFoundation shell.

- **`WordTimeline` (pure):** flat word start times. `index(at:)`, `time(ofWordAt:)`, `averageWPM(duration:)`, `displayedWPM(rate:duration:)`, `clampRate(_:)`. No AVFoundation.
- **`SegmentTimeline` (pure):** composes segment boundaries over a `WordTimeline`; `index(at:)` does the two-level lookup and re-anchoring; `time(ofWordAt:)` for seeks. This is what the coordinator uses. No AVFoundation. Bulk of red-green-refactor lives here and in `WordTimeline`.
- **`PlaybackClock` (protocol):** the seam, modeling AVPlayer reality, not an idealized clock. Declares `currentTime`, `rate`, `play()`, `pause()`, `seek(to:completion:)` (async completion), and callbacks for tick, `didReachEnd`, `didFail(error)`, and `didInterrupt`. Production `AVPlaybackClock` wraps `AVPlayer` (periodic observer, item-did-play-to-end, error KVO, `AVAudioSession` interruption/route notifications) and manages observer lifecycle/removal. Test `FakePlaybackClock` sets `currentTime` by hand and can simulate delayed seeks, failed seeks, end-of-item, and interruptions.
- **`AudioSyncCoordinator`:** depends only on `PlaybackClock` (protocol) and `SegmentTimeline` (pure), plus `RSVPEngine`. Never names `AVPlayer`, so advance-on-tick, seek-on-UI-change, re-anchoring, offset application, play/pause delegation, rate clamping, and pause-on-interruption/end/failure are all unit-testable with `FakePlaybackClock`.
- **`AudiobookTimingParser` (pure):** parses/validates v2 JSON into flattened words, segment boundaries, and start times, or throws a specific `DocumentImportError`. Tests feed it `Data` plus a duration.
- **`WordTimingStorage` (pure):** exact Float64 round-trip.

What stays manual (real-device acceptance, not unit tests): audible pitch preservation, `AVAudioSession` interruption/route/background behavior, and end-to-end onset latency including Bluetooth. Called out explicitly in Acceptance Criteria so they are never mistaken for automated coverage.

## Key Flows (CRISP)

Each Postcondition is the acceptance test for that flow. Automated coverage is specified per-postcondition in Acceptance Criteria.

### Flow A: Import an audiobook

**Context:** Reader is in the library with an "Import audiobook" action. A DRM-free audio file and its v2 timing file are reachable via the file picker.
**Role:** Reader (app owner; no auth model).
**Intent:** Turn a matching audio + timing pair into one playable synced document, and catch a wrong pairing before committing.
**Steps:**
1. Reader invokes "Import audiobook" and selects one audio file and one timing file (order-independent; either slot accepts either type by content, not just extension).
2. System validates the pair (schema version 2, well-formed entries, monotonic non-decreasing word and segment start times, non-negative, last start within `audioDuration + tolerance`, audio decodable and unprotected).
3. System shows a preview (resolved title, first ~20 words, audio duration, segment and word counts). Reader confirms or cancels.
4. On confirm, system copies the audio into app storage, stores words + segment boundaries + timings, computes average WPM, seeds `audioOutputOffset`, and inserts one `.audiobook` document.
5. On cancel or any failure, system removes any partial copy and creates nothing.
**Postcondition (observable):**
- Success: exactly one `Document` with `sourceType == .audiobook`, `wordCount == flattened word count`, `wordTimingsBlob`/`segmentBoundariesBlob` decoding to the file's data, `playbackRate == 1.0`, `audioDuration` set, `audioOutputOffset` seeded, and the copied audio present at its resolved path.
- Failure/cancel: zero new `Document` rows, no orphaned partial copy on disk, and (on failure) the thrown `DocumentImportError` matches the specific cause (AC-U5 to AC-U9, AC-I8, AC-I12).

### Flow B: Read along (hold-to-read)

**Context:** A synced `.audiobook` document is open, paused, at word index `k`.
**Role:** Reader.
**Intent:** Follow the narration visually for as long as they hold.
**Steps:**
1. Reader holds; audio plays.
2. As audio advances, the displayed word tracks the narration (segment-anchored).
3. Reader releases; audio and text pause together.
**Postcondition (observable):** while playing, after each tick the displayed word equals `words[SegmentTimeline.index(at: effectiveTime)]`; on release, `clock.pause()` was called and `engine.isPlaying == false`.

### Flow C: Change speed

**Context:** A synced document is open, paused at word `k`, rate 1.0x.
**Role:** Reader.
**Intent:** Speed up or slow down without losing alignment.
**Steps:**
1. Reader drags the WPM/rate slider to 1.5x.
2. Reader resumes; audio plays faster with preserved pitch, text tracking.
**Postcondition (observable):** `clock.rate == 1.5`; displayed number equals `round(averageWPM * 1.5)`; for any `effectiveTime`, the shown word is identical to the word shown at 1.0x for the same `effectiveTime` (rate changes cadence, never the time-to-word mapping).

### Flow D: Scrub / seek

**Context:** A synced document is open (playing or paused).
**Role:** Reader.
**Intent:** Jump to a chosen word and have audio and text agree.
**Steps:**
1. Reader scrubs by swipe, drags the progress bar (percentage of words), taps a chapter, presses an arrow, or taps a word in the passage view. Each resolves to a target word index `j`.
2. System seeks audio to `SegmentTimeline.time(ofWordAt: j)`.
**Postcondition (observable):** `clock.seek(to:completion:)` was called with `SegmentTimeline.time(ofWordAt: j)`; `engine.currentIndex == j`; after seek completion, subsequent ticks resolve from that time.

### Flow E: Interruption, end, and background

**Context:** A synced document is playing.
**Role:** Reader.
**Intent:** Never have narration advance past words they did not see.
**Steps:**
1. A phone call begins, headphones are unplugged, the app backgrounds, or the item reaches its end.
2. System pauses audio and text (or shows completion at end) and persists position.
3. Reader returns and resumes.
**Postcondition (observable):** on interruption/route-loss/background, `clock.pause()` was called, `engine.isPlaying == false`, and persisted `currentWordIndex` equals the shown index; on `didReachEnd`, the completion overlay shows. Interruption/route/background/end triggers are verified manually on device; the coordinator's reaction to each signal is unit-tested via `FakePlaybackClock`.

## Key Logic (rules and edge cases)

- **No re-tokenization in audio mode.** Words come verbatim from the file's `w` fields (flattened across segments). The app never re-splits them with `Tokenizer`.
- **Segment re-anchoring** bounds word error to one segment; see Sync Architecture. Word times within a segment refine position but cannot escape the segment's word range.
- **Timings-versus-audio mismatch:** if the last start time exceeds `audioDuration + tolerance`, reject with `timingsExceedAudio`.
- **Non-monotonic or negative start times (word or segment):** reject (`nonMonotonicTimings`). No silent clamping.
- **Equal adjacent timestamps:** permitted; the later index wins at that instant, meaning a zero-duration word may not get its own rendered frame. Acceptable.
- **Silence gaps:** the current word holds until the next word's start. No special handling.
- **End of audio:** the final word holds until end; `didReachEnd` triggers the completion overlay.
- **Corrupt or unparseable timing file:** reject (`malformedTimings`).
- **DRM / undecodable audio:** detect via `AVAsset` `isPlayable`/`hasProtectedContent` and decode probing; map to distinct errors: `audioProtected`, `audioCorrupt`, `audioUnsupported`. (Promoted from a non-goal because the detection has real edge cases.)
- **Wrong-book pairing:** the app cannot know the "right" book, so it shows the import preview (Flow A step 3) for the reader to catch gross mismatches. Not auto-detectable beyond that.
- **Large / VBR audio:** accept AVFoundation-decodable formats; VBR MP3 seek accuracy depends on a valid header (guidance recommends CBR or m4a). Bound companion JSON size (reject files beyond a sane cap, analogous to `maxPlainTextBytes`).
- **Disk full / copy failure:** import fails cleanly, removes the partial copy, creates no document.
- **Duplicate import:** detected by audio content identity; offer replace-in-place versus create-new (default: ask; if unattended, create-new). Never silently double-store.
- **Audio moved/deleted after import:** the copy is inside app storage, so this cannot happen to the copy; if the copy is ever missing (corruption, external tampering), opening shows a "media missing, re-import" state rather than crashing.
- **Seek completion failure or delay:** the coordinator waits for `seek` completion before trusting position; a failed seek surfaces a transient error and leaves the last good index.
- **Interruption resume policy:** after an interruption ends, stay paused; words advancing while unobserved are words the reader never saw.
- **Rate bounds:** clamp to 0.5x to 3x; guard zero/negative.
- **Output offset bounds:** clamp to a sane range (for example 0 to 1.0 s); `effectiveTime` never goes negative.
- **System sleep / macOS app suspension:** treated like backgrounding (pause + persist).

## Feature Parity Matrix

Each row names the criterion that defines "works."

| Existing feature | Audio mode behavior | Verified by |
|---|---|---|
| Hold-to-read | Hold plays audio+text; release pauses both | AC-I3, Flow B |
| Tap-to-read | Toggles audio+text | AC-I3 |
| WPM slider | Repurposed as 0.5x-3x rate; number derived | AC-U3, AC-I4, Flow C |
| Scrubbing (swipe) | Resolves to word index, seeks audio | AC-I2, Flow D |
| Progress bar | Percentage of words; seeks audio | AC-I2, Flow D |
| Chapter navigation | Seeks to chapter's first word's time | AC-I2 |
| Arrow keys (macOS/iPad) | Seek by one word plus audio seek | AC-I2 |
| Passage view | Tapping a word seeks audio+text | AC-I2 |
| ORP highlight, fonts, text size | Purely visual; unchanged | existing tests |
| Smart / sentence / complexity timing | Inert; hidden in audio-mode UI | AC-I3 |
| Completion overlay | Triggered on `didReachEnd` | AC-I13, Flow E |
| Position persistence | Persist/restore index, rate, offset via word index | AC-I6, AC-I5 |

## Acceptance Criteria (TDD)

Each criterion is written to become a failing test first, with concrete fixtures. Grouped by layer; only the Manual layer lacks automated coverage, stated so it is never mistaken for a gap. Framework: Swift Testing (`@Test` / `#expect`).

### Layer 1: Unit (pure, red-green-refactor core)

- **AC-U1 — Word index resolves by time, clamped.** `WordTimeline([0.0, 0.5, 1.0, 2.0]).index(at:)`: `-0.1 -> 0`, `0.0 -> 0`, `0.49 -> 0`, `0.5 -> 1`, `1.99 -> 2`, `2.0 -> 3`, `100 -> 3`. Single-word `[0.0]` returns `0` for any time. Component: `WordTimeline`.
- **AC-U2 — Word start-time lookup is the inverse.** `WordTimeline([0.0, 0.5, 1.0, 2.0]).time(ofWordAt: 2) == 1.0`; out-of-range clamps. Component: `WordTimeline`.
- **AC-U3 — Rate and WPM math.** `wordCount 9000`, `duration 3600`: `averageWPM == 150`; `displayedWPM(rate: 1.5) == 225`; `clampRate(0.1) == 0.5`, `clampRate(5.0) == 3.0`, `clampRate(1.25) == 1.25`; `duration 0` yields `averageWPM == 0` (no crash). Component: `WordTimeline`.
- **AC-U4 — Timing storage round-trips exactly.** `decode(encode([0.0, 0.5, 1.0, 3600.25])) == [0.0, 0.5, 1.0, 3600.25]` (Float64). Empty encodes to empty/`nil`. Component: `WordTimingStorage`.
- **AC-U5 — Valid v2 file parses to words, boundaries, times.** The example JSON yields words `["In","a","hole","in","the","ground"]`, segment boundaries `[0, 3]`, and starts `[0.42,0.55,0.61,0.94,1.02,1.10]`. Component: `AudiobookTimingParser`.
- **AC-U6 — Unknown schema version rejected.** `version: 1` or `3` throws `DocumentImportError.unsupportedTimingVersion`. Component: `AudiobookTimingParser`.
- **AC-U7 — Malformed input rejected.** Non-JSON, empty `segments`, an empty segment, or an entry missing `w`/`s` each throw `malformedTimings`. Component: `AudiobookTimingParser`.
- **AC-U8 — Non-monotonic times rejected; equal allowed.** Word starts `[0.0, 0.5, 0.4]` or segment starts out of order throw `nonMonotonicTimings`. `[0.0, 0.5, 0.5]` parses (equal permitted per AC-U1). Component: `AudiobookTimingParser`.
- **AC-U9 — Timings must fit audio.** Negative start throws `nonMonotonicTimings`/`malformedTimings`. With `duration 100.0`, tolerance `2.0`: last start `103.0` throws `timingsExceedAudio`; `101.5` accepted. Component: `AudiobookTimingParser` (duration is a plain `TimeInterval`).
- **AC-U10 — Segment re-anchoring bounds error.** `SegmentTimeline` with boundaries `[0, 3]`, segment starts `[0.0, 5.0]`, and deliberately corrupt within-segment word times (segment 0 words all `0.0`): `index(at: 4.9)` is within `[0, 3)`; `index(at: 5.0) == 3` (snaps to segment 1's first word). Error cannot leak past the boundary. Component: `SegmentTimeline`.
- **AC-U11 — Output offset shifts effective time.** With `audioOutputOffset == 0.2`, resolving at `currentTime == 0.6` uses `effectiveTime == 0.4`; at `currentTime == 0.1` uses `0.0` (clamped, never negative). Component: coordinator helper (pure).

### Layer 2: Integration (fakes and in-memory SwiftData)

- **AC-I1 — Coordinator sets index to match current time.** With `SegmentTimeline` over `[0.0,0.5,1.0,2.0]` and a `FakePlaybackClock`: after a tick at `currentTime 0.6`, `engine.currentIndex == 1`; at `2.0`, `== 3`. The guarantee is "index equals `SegmentTimeline.index(at: effectiveTime)` after each tick." (Not "every word renders": a sub-tick word between two ticks may be skipped visually. That is acceptable and asserted as expected, not as a bug.) Component: `AudioSyncCoordinator`.
- **AC-I2 — UI seek drives the clock via word index.** Seeking to word `2` calls `FakePlaybackClock.seek(to: 1.0, ...)` and leaves `engine.currentIndex == 2`. Component: `AudioSyncCoordinator`.
- **AC-I3 — Play/pause delegate; WPM timer stays off.** `play()`/`pause()` call the clock; the engine `DispatchSourceTimer` is never scheduled in audio mode. Component: `AudioSyncCoordinator` + `RSVPEngine`.
- **AC-I4 — Rate clamped and forwarded.** `setRate(5.0)` yields `clock.rate == 3.0`; `setRate(0.1)` yields `0.5`. Component: `AudioSyncCoordinator`.
- **AC-I5 — Interruption/route/background pauses and persists.** A `didInterrupt` signal while playing at index `k` calls `clock.pause()`, sets `isPlaying == false`, persists `currentWordIndex == k`. Component: `AudioSyncCoordinator`.
- **AC-I6 — Import creates one self-contained document.** In-memory `ModelContainer` + temp audio + valid v2 file: exactly one `.audiobook` `Document` with correct `wordCount`, decoded timings and boundaries, `playbackRate == 1.0`, `audioDuration`, seeded `audioOutputOffset`, and the copied audio present. Component: import flow.
- **AC-I7 — Delete cleans up copied audio.** Deleting the document removes its copied audio file. Component: delete hook.
- **AC-I8 — Invalid import is atomic.** A pair failing any AC-U6 to AC-U9 check creates zero rows and throws the matching error. Component: import flow.
- **AC-I9 — Failed/delayed seek is handled.** `FakePlaybackClock` set to fail a seek: the coordinator does not advance to a false position and surfaces a transient error; a delayed-completion seek does not update index until completion fires. Component: `AudioSyncCoordinator`.
- **AC-I10 — Coordinator re-anchors across a boundary.** Sweeping `currentTime` across a segment boundary forces `engine.currentIndex` into the new segment's range regardless of within-segment word-time noise. Component: `AudioSyncCoordinator` + `SegmentTimeline`.
- **AC-I11 — Duplicate import does not silently double-store.** Importing the same audio content twice either replaces in place or creates a clearly distinct document per the chosen policy; it never leaves two copies of the same media with no linkage. Component: import flow.
- **AC-I12 — Cancelled/failed import removes partial copy.** Cancelling during (or failing after) the audio copy leaves zero documents and no orphaned file on disk. Component: import flow.
- **AC-I13 — End of item shows completion.** A `didReachEnd` signal triggers the completion overlay and pauses. Component: `AudioSyncCoordinator`.

### Layer 3: Manual (real-device acceptance, no automated coverage)

- **AC-M1 — Pitch preserved.** Confirm `audioTimePitchAlgorithm` is a pitch-preserving mode; A/B narration at 0.5x/1x/2x/3x against the source at 1x and confirm no perceptible pitch shift.
- **AC-M2 — Phone call.** An incoming call pauses audio+text; after the call the app stays paused on the same word until resumed.
- **AC-M3 — Headphone unplug.** `routeChange` with `.oldDeviceUnavailable` pauses audio+text.
- **AC-M4 — Background / sleep.** Backgrounding (iOS) and app suspension/display sleep (macOS) pause within one run loop; foregrounding resumes on the same word.
- **AC-M5 — Latency and no drift (specified).** Method: log `(wallClock, currentTime, displayedIndex)` per tick. Sample >= 30 words spread across the book (start, middle, end). Rates: 0.5x, 1x, 2x, 3x. Routes: built-in speaker, wired, Bluetooth. Pass: at 1x on built-in/wired, displayed word within 150 ms of onset; end-of-book samples within the same tolerance (no cumulative drift). Bluetooth measured separately (see AC-M6).
- **AC-M6 — Bluetooth offset.** With `audioOutputOffset` seeded from `AVAudioSession.outputLatency` (and nudged if needed), Bluetooth playback shows the word being heard, not the word ~150 to 200 ms ahead. Document the residual on a representative device.

### Goal-to-criteria map

| Goal | Verified by |
|------|-------------|
| Exact word sync | AC-U1, AC-U11, AC-I1, AC-M5 |
| Feature parity | Feature Parity Matrix (per-row criteria) |
| Speed control preserves sync | AC-U3, AC-I4, AC-M1, AC-M5, Flow C |
| Robust real-world playback | AC-I5, AC-I9, AC-I13, AC-M2 to AC-M4 |
| Graceful misalignment recovery | AC-U10, AC-I10 |

🛑 **Checkpoint:** Confirm architecture (clock inversion, two-level `SegmentTimeline`, `PlaybackClock` seam with async seek/end/failure/interruption, copy-into-library, output offset) and acceptance criteria before build.

---

# Launch Plan

## Milestones

| Target | Phase | Exit Criteria |
|--------|-------|---------------|
| TBD | Pilot (dogfood) | End-to-end import + sync works on one real book on iOS and macOS; AC-M5 latency held at 1x on wired output; AC-U10/AC-I10 recovery demonstrated on a deliberately drifted file; no P0/P1 crashes for 7 days. |
| TBD | Beta | All Key Flow postconditions pass; AC-I* green; interruption/route/background/end verified on device (AC-M2 to AC-M4); Bluetooth offset acceptable (AC-M6); import rejects all malformed pairs with the correct specific error. |
| TBD | Launch | Sync stable across >= 3 books/narrators including one with known alignment gaps; Feature Parity Matrix verified; docs and in-app import hint + generation guide updated. |

Dates are placeholders pending a build estimate.

## Operational Checklist

| Team | Need | Action |
|------|------|--------|
| Analytics | Additional tracking? | Build a local latency-instrumentation harness (the AC-M5 logger) as a dev tool; it is required to defend the 150 ms target, not optional. No remote analytics. |
| Sales | Enablement materials? | N/A (personal app). |
| Docs/CS | Support content updates? | Ship the generation-setup guide with a concrete quality bar (sentence-segmented, word-timed v2 JSON; CBR/m4a for seek accuracy); in-app import hint; update CLAUDE.md architecture notes with the audio pipeline and `SegmentTimeline`. |
| Legal | Legal review needed? | Real review, not a note: the app accepts only user-supplied, non-protected audio and user-generated timing files; it detects and rejects DRM-protected content; it contains no circumvention path. Confirm the import gating actually blocks protected files before ship. |
| Marketing | GTM plan needed? | N/A. |

---

# Appendix

## Decisions Locked (scoping + review)

1. **Speed control:** WPM slider becomes a playback-rate control (0.5x-3x); audio is the master clock; independent WPM is out.
2. **Pairing:** dedicated import flow with a confirmation preview; pick audio + timing file together.
3. **Background:** foreground playback with robust interruption/route/background handling; auto-pause; no lock-screen playback.
4. **Storage:** audio copied into the app library (self-contained), with explicit cleanup on delete and on cancelled/failed import.
5. **Companion format:** hierarchical segment-and-word JSON (schema v2). Flat word-only JSON rejected because it cannot support recovery.
6. **Misalignment recovery:** segment-anchored auto-resync (re-anchor at every segment boundary), plus a global output-offset for latency. Chosen over a manual per-word editor and over re-import-only.

## Open Questions

- [x] Timing storage precision? **Resolved: Float64** (exact round-trip, AC-U4).
- [x] Recovery strategy? **Resolved: segment-anchored auto-resync** (Decision 6).
- [x] Companion format? **Resolved: hierarchical v2 JSON.**
- [ ] Segment granularity: sentence only, or allow paragraph-level segments too? (Affects re-anchor frequency versus generation simplicity.)
- [ ] Output offset: auto from `AVAudioSession.outputLatency` only, or also expose a manual nudge control in v1?
- [ ] Rate steps: free 0.5x to 3x, or snap to 1.0x/1.25x/1.5x/2x?
- [ ] Chapters: derive from segment structure, m4b metadata, or leave out of v1?
- [ ] A "synced" badge to distinguish audiobook documents in the library list?
- [ ] Duplicate-import policy default when unattended: replace-in-place or create-new?

## Changelog

| Date | Change |
|------|--------|
| 2026-07-07 | Initial draft created from scoping session (four decisions locked). |
| 2026-07-07 | TDD pass: Testability Architecture (pure core / `PlaybackClock` seam), CRISP Key Flows with observable postconditions, layered Acceptance Criteria with concrete fixtures, count-mismatch fix, Float64 storage. |
| 2026-07-07 | Codex adversarial review folded in: segment-anchored recovery (Decision 6) with hierarchical v2 format and `SegmentTimeline`; output-offset for Bluetooth latency + latency/tolerance model; `PlaybackClock` expanded for async seek/end/failure/interruption; AC-I1 corrected (index-matches-time, not every-word-renders); Feature Parity Matrix rows mapped to criteria; goals made measurable; DRM detection promoted from non-goal to feature with distinct errors; added import preview, partial-copy cleanup, duplicate-import, VBR/format, seek-failure, and sleep edge cases; tightened AC-M1/AC-M5 and added AC-M6, AC-U10/U11, AC-I9 to AC-I13. |
