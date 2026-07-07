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
