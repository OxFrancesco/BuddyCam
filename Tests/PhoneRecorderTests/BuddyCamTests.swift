import XCTest
@testable import PhoneRecorder

final class BuddyCamTests: XCTestCase {
    func testFormatDimensions() {
        XCTAssertEqual(RecordingFormat.square.width, 1080)
        XCTAssertEqual(RecordingFormat.square.height, 1080)
        XCTAssertEqual(RecordingFormat.portrait.width, 1080)
        XCTAssertEqual(RecordingFormat.portrait.height, 1920)
        XCTAssertEqual(RecordingFormat.landscape.width, 1920)
        XCTAssertEqual(RecordingFormat.landscape.height, 1080)
    }
}
