import XCTest

@testable import MeetingCaptureCore

final class CommandLineArgumentsTests: XCTestCase {

    func testFlagsAndOptions() {
        let args = CommandLineArguments(raw: ["--transcribe", "--model", "tiny"])
        XCTAssertTrue(args.flag("--transcribe"))
        XCTAssertFalse(args.flag("--summarize"))
        XCTAssertEqual(args.option("--model"), "tiny")
        XCTAssertNil(args.option("--language"))
    }

    func testOptionMissingItsValueIsNil() {
        XCTAssertNil(CommandLineArguments(raw: ["--model"]).option("--model"))
    }
}
