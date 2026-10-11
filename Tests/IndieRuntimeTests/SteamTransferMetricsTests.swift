import XCTest
import IndieRuntime

final class SteamTransferMetricsTests: XCTestCase {
    func testLiveProgressWinsOverStaleManifest() {
        XCTAssertEqual(SteamTransferMetrics.progress(live:0.48,fallback:0),0.48)
        XCTAssertEqual(SteamTransferMetrics.progress(live:.nan,fallback:0.2),0.2)
        XCTAssertNil(SteamTransferMetrics.progress(live:2,fallback:nil))
    }
    func testLargeCountersAndUnknownTotals() {
        let pair=SteamTransferMetrics.bytes(downloaded:64701486282,total:134794763088)
        XCTAssertEqual(pair?.downloaded,64701486282)
        XCTAssertEqual(pair?.total,134794763088)
        XCTAssertNil(SteamTransferMetrics.bytes(downloaded:85000000,total:1))
        XCTAssertNil(SteamTransferMetrics.bytes(downloaded:10,total:0))
        XCTAssertNil(SteamTransferMetrics.bytes(downloaded:nil,total:100))
    }
}
