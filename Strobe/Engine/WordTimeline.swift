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
