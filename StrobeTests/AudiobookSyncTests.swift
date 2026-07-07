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
}
