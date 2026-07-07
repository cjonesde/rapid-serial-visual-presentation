import Foundation
import os

@Observable
final class AudioSyncCoordinator: RSVPPlaybackController {

    nonisolated static let maxOutputOffset: TimeInterval = 1.0

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
