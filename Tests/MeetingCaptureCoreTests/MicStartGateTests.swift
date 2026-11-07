import XCTest

@testable import MeetingCaptureCore

/// The mic is held back until system audio starts (D-58), so the two tracks line up from the first frame.
final class MicStartGateTests: XCTestCase {

    func testMicStartGateIsClosedUntilOpenedAndStaysOpen() {
        let gate = MicStartGate()
        XCTAssertFalse(gate.passes)
        gate.open()
        XCTAssertTrue(gate.passes)
        gate.open()
        XCTAssertTrue(gate.passes)
    }

    func testMicStartGateIsSafeWhenOpenedFromAnotherThreadWhileRead() {
        let gate = MicStartGate()
        let lock = NSLock()
        var wentBackToClosed = false
        var sawOpen = false
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            if worker == 0 {
                Thread.sleep(forTimeInterval: 0.01)
                gate.open()
            } else {
                var seen = false
                for _ in 0..<200_000 {
                    let p = gate.passes
                    if seen && !p {
                        lock.lock()
                        wentBackToClosed = true
                        lock.unlock()
                    }
                    if p {
                        seen = true
                    }
                }
                if seen {
                    lock.lock()
                    sawOpen = true
                    lock.unlock()
                }
            }
        }
        XCTAssertFalse(wentBackToClosed, "a gate that was seen open closed again")
        XCTAssertTrue(gate.passes)
        _ = sawOpen  // Whether a reader caught the opening depends on timing, so it isn't asserted.
    }
}
