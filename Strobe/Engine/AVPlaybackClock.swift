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
