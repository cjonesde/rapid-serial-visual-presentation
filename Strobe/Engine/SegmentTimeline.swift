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
