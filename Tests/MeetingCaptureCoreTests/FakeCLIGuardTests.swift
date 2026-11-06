import Foundation
import XCTest

/// scripts/check.sh also runs this suite with the fakes off PATH and expects it to fail.
final class FakeCLIGuardTests: GuardedTestCase {

    func testModelCLIsOnPathAreTheFakes() throws {
        XCTAssertTrue(Self.firstOnPath("claude")?.contains("/Tests/FakeBin/") ?? false)
        XCTAssertTrue(Self.firstOnPath("codex")?.contains("/Tests/FakeBin/") ?? false)
    }

    func testFakeCLIRefusesRatherThanAnswering() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try XCTUnwrap(Self.firstOnPath("claude")))
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 3)
    }

    func testNetworkIsRefused() async {
        do {
            _ = try await URLSession.shared.data(from: URL(string: "https://example.com/")!)
            XCTFail("a request got out during a guarded test")
        } catch {
            // Refused by NetworkRefusal, as intended.
        }
    }
}
