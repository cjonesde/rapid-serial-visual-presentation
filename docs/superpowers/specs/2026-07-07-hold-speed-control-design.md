# Hold-to-Read Vertical Speed Control — Design

Date: 2026-07-07
Status: Approved

## Summary

In hold-to-read mode, while the hold is actively playing, vertical finger
movement adjusts reading speed live: up increases WPM, down decreases it.
Releasing pauses playback (existing behavior) and discards the adjustment;
the next hold plays at the document's configured WPM (existing behavior).

## Behavior

- Applies only when `holdToReadEnabled` is on and the touch has entered
  `touchMode == .reading` (playback started by the hold).
- Mapping is absolute from the touch-down point:
  - Dead zone: ±15pt of vertical travel changes nothing.
  - Beyond the dead zone: 2.5 WPM per point of travel, measured from the
    dead-zone edge.
  - Up (negative `translation.height`) increases WPM; down decreases it.
  - Result snapped to 10-WPM steps (slider granularity), clamped to 100–1000.
- Moving the finger back inside the dead zone restores the configured speed.
- Horizontal scrub detection is unchanged; vertical movement never flips an
  undecided touch into scrubbing.
- Tap-to-toggle mode, the bottom-bar WPM slider, scrubbing, and macOS
  keyboard controls are unchanged.

## Architecture

### RSVPEngine

- New `var wpmOverride: Int?`. `didSet` calls the existing
  `onPlaybackSettingChanged()` so rescheduling reuses the pull-earlier-only
  logic (a continuous drag can never stall playback on one word).
- New `var effectiveWordsPerMinute: Int` returning
  `wpmOverride ?? wordsPerMinute`. `baseInterval` computes from it.
- `pause()` clears `wpmOverride`. "Re-hold resumes at configured speed" is
  therefore an engine-enforced invariant.
- `wordsPerMinute` is never mutated by the gesture, so
  `persistState`/`document.recordPosition` can never capture a transient
  speed.
- New pure helper alongside the existing static timing helpers:
  `nonisolated static func holdSpeedWPM(baseWPM: Int, verticalTranslation: CGFloat) -> Int`
  containing dead zone, slope, snapping, and clamping.

### ReaderView

- In `unifiedGesture.onChanged`, when `holdToReadEnabled` and
  `touchMode == .reading`: map `value.translation.height` through
  `holdSpeedWPM` and assign `engine.wpmOverride`; nil while inside the dead
  zone. Fire `HapticManager.shared.scrubTick()` when the snapped value
  crosses a step boundary.
- In `onEnded`, the existing `engine.pause()` clears the override; also nil
  it defensively for the not-playing edge case (e.g. hold at end of
  document).

### Feedback

- Transient WPM readout ("420 WPM", theme `bodyFont`, secondary text color)
  below the word while `wpmOverride != nil`. Every speed step restarts a 2s
  idle window; once the speed has not changed for 2s, the readout fades out
  over 1s, and the next speed change fades it back in. Release fades it out
  quickly. Implemented as a per-tick child view per the existing
  invalidation-scoping pattern.
- Haptic step ticks via the existing `scrubTick()` (no-op on macOS).

## Testing (Swift Testing, TDD)

1. `holdSpeedWPM`:
   - Returns `baseWPM` inside the ±15pt dead zone.
   - Up (negative translation) increases, down decreases.
   - Slope 2.5 WPM/pt from the dead-zone edge, snapped to 10-WPM steps.
   - Clamps at 100 and 1000.
2. `RSVPEngine`:
   - `effectiveWordsPerMinute` equals `wordsPerMinute` without override and
     the override value with it.
   - Setting/clearing `wpmOverride` never mutates `wordsPerMinute`.
   - `pause()` clears `wpmOverride`.
   - After pause + play, playback uses the base speed
     (`effectiveWordsPerMinute == wordsPerMinute`).
3. Gesture wiring is thin glue: verified by build and manual run, not unit
   tests.

## Out of Scope

- No new settings key; sensitivity and dead zone are constants.
- No change to tap-to-toggle mode.
- No persistence of the temporary speed.
