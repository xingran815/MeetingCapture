import XCTest

@testable import MeetingCaptureCore

/// Fallback must happen for a full limit and nothing else, and every started call counts.
final class LLMRouterAttackTests: GuardedTestCase {

    private var world: FakeCLIWorld!
    private let plain = CLIRequest.text(tier: .normal, system: "s", input: "i")
    private var codexOK: FakeCLIWorld.Script { .init(stdout: FakeCLIWorld.codexOK()) }
    private var claudeOK: FakeCLIWorld.Script { .init(stdout: FakeCLIWorld.claudeOK()) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        world = try FakeCLIWorld()
    }

    override func tearDown() {
        world.cleanUp()
        super.tearDown()
    }

    private func rejectedStream(resetsIn seconds: TimeInterval) -> String {
        let reset = Int(world.now.timeIntervalSince1970 + seconds)
        return """
            {"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":\(reset)}}
            {"type":"result","is_error":true,"result":"limit"}
            """
    }

    // MARK: No fallback for anything but a full limit

    func testARefusedAPIKeyStreamDoesNotFallBack() async throws {
        try world.install(.claude, answers: [.init(stdout: FakeCLIWorld.claudeOK(apiKeySource: "SOME_HELPER"))])
        try world.install(.codex, answers: [codexOK])
        do {
            _ = try await world.router().call(plain)
            XCTFail("the answer must be refused")
        } catch let error as CLIError {
            XCTAssertEqual(error, .apiBillingRefused(.claude, "SOME_HELPER"))
        }
        XCTAssertEqual(world.calls(.codex).count, 0)
    }

    func testATimeoutDoesNotFallBack() async throws {
        try world.installScript(.claude, modelCall: "exec sleep 20")
        try world.install(.codex, answers: [codexOK])
        let router = LLMRouter(
            runner: world.runner(timeout: 0.2), ledger: world.ledger(), primary: .claude, cap: 200,
            clock: { [world] in world!.now })
        do {
            _ = try await router.call(plain)
            XCTFail("expected a timeout")
        } catch let error as CLIError {
            XCTAssertEqual(error, .timedOut(.claude))
        }
        XCTAssertEqual(world.calls(.codex).count, 0)
    }

    func testAPrimaryNotLoggedInMovesToTheOtherWithoutCountingIt() async throws {
        try world.install(.claude, answers: [claudeOK], authStatus: #"{"loggedIn":false}"#)
        try world.install(.codex, answers: [codexOK])
        let result = try await world.router().call(plain)
        XCTAssertEqual(result.cli, .codex)
        XCTAssertEqual(try world.ledger().count(.claude), 0, "a login check isn't a model call")
    }

    func testAPrimaryOnAnAPIKeyIsNotUsedAndTheReasonIsKept() async throws {
        try world.install(.claude, answers: [claudeOK], authStatus: #"{"loggedIn":true,"authMethod":"api_key"}"#)
        do {
            _ = try await world.router().call(plain)
            XCTFail("expected no CLI")
        } catch let error as LLMRouter.RouterError {
            XCTAssertTrue(error.localizedDescription.contains("bill an API key"), error.localizedDescription)
        }
        XCTAssertEqual(world.calls(.claude).count, 0)
    }

    // MARK: Counting

    func testACapOfZeroStartsNothing() async throws {
        try world.install(.claude, answers: [claudeOK])
        try world.install(.codex, answers: [codexOK])
        do {
            _ = try await world.router(cap: 0).call(plain)
            XCTFail("expected a stop")
        } catch let error as LLMRouter.RouterError {
            guard case .allUsageFull = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(world.calls(.claude).count + world.calls(.codex).count, 0)
    }

    func testAFullResponseStillCounts() async throws {
        try world.install(.claude, answers: [.init(stdout: "", exit: 1, stderr: "usage limit")])
        try world.install(.codex, answers: [codexOK])
        _ = try await world.router().call(plain)
        XCTAssertEqual(try world.ledger().count(.claude), 1, "the process ran, so it may have used quota")
        XCTAssertEqual(try world.ledger().count(.codex), 1)
    }

    /// Once both are out, further steps in the run mustn't start anything or say so twice.
    func testAfterBothAreFullLaterStepsStartNothing() async throws {
        let full = FakeCLIWorld.Script(stdout: "", exit: 1, stderr: "usage limit")
        try world.install(.claude, answers: [full])
        try world.install(.codex, answers: [full])
        let router = world.router()
        for _ in 0..<3 { _ = try? await router.call(plain) }
        XCTAssertEqual(world.calls(.claude).count, 1)
        XCTAssertEqual(world.calls(.codex).count, 1)
        XCTAssertEqual(router.notes.count, 2, "\(router.notes)")
    }

    func testACounterThatCantBeWrittenStartsNoCall() async throws {
        try world.install(.claude, answers: [claudeOK])
        let blocker = world.root.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let ledger = UsageLedger(path: blocker.appendingPathComponent("usage.json"), clock: { [world] in world!.now })
        let router = LLMRouter(runner: world.runner(), ledger: ledger, primary: .claude, cap: 200)
        do {
            _ = try await router.call(plain)
            XCTFail("an uncounted call could go past the cap")
        } catch {}
        XCTAssertEqual(world.calls(.claude).count, 0)
    }

    // MARK: What carries between runs

    func testALimitReportedInAFailedCallStopsTheNextRunTrying() async throws {
        try world.install(.claude, answers: [.init(stdout: rejectedStream(resetsIn: 3600), exit: 1)])
        try world.install(.codex, answers: [codexOK])
        let first = try await world.router().call(plain)
        XCTAssertEqual(first.cli, .codex)

        let second = try await world.router().call(plain)
        XCTAssertEqual(second.cli, .codex)
        XCTAssertEqual(world.calls(.claude).count, 1, "the new run knows Claude is full until its reset")

        world.now = world.now.addingTimeInterval(3601)
        try world.install(.claude, answers: [claudeOK])
        let third = try await world.router().call(plain)
        XCTAssertEqual(third.cli, .claude, "and goes back after the reset")
    }

    func testAFullReportWithNoResetTimeDoesntLockTheCLIOut() async throws {
        try world.ledger().record(
            limit: RateLimitSnapshot(status: "rejected", resetsAt: nil, windows: [:]), for: .claude)
        try world.install(.claude, answers: [claudeOK])
        let result = try await world.router().call(plain)
        XCTAssertEqual(result.cli, .claude, "with no reset time it could stay locked out for good")
    }

    func testABothFullStopNamesTheReportedResetTime() async throws {
        let full = FakeCLIWorld.Script(stdout: rejectedStream(resetsIn: 3600), exit: 1)
        try world.install(.claude, answers: [full])
        try world.install(.codex, answers: [.init(stdout: "", exit: 1, stderr: "usage limit")])
        do {
            _ = try await world.router().call(plain)
            XCTFail("expected a stop")
        } catch let error as LLMRouter.RouterError {
            guard case .allUsageFull(_, let limits) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(limits, world.now.addingTimeInterval(3600))
        }
    }

    func testASuccessfulCallStaysOnTheCLIThatAnswered() async throws {
        try world.install(.claude, answers: [claudeOK], authStatus: #"{"loggedIn":false}"#)
        try world.install(.codex, answers: [codexOK])
        let router = world.router()
        _ = try await router.call(plain)
        _ = try await router.call(plain)
        XCTAssertEqual(world.calls(.codex).count, 2)
    }

    // MARK: Ledger

    func testLimitsSurviveTheDayChangeAndCountsDont() throws {
        let ledger = world.ledger()
        XCTAssertTrue(try ledger.reserve(.claude, cap: 5))
        let reset = world.now.addingTimeInterval(3 * 86_400)
        try ledger.record(limit: RateLimitSnapshot(status: "rejected", resetsAt: reset, windows: [:]), for: .claude)
        world.now = ledger.countResetsAt
        XCTAssertEqual(try ledger.count(.claude), 0)
        XCTAssertTrue(try ledger.isKnownFull(.claude))
    }

    func testEachCLICountsSeparately() throws {
        let ledger = world.ledger()
        XCTAssertTrue(try ledger.reserve(.claude, cap: 1))
        XCTAssertTrue(try ledger.reserve(.codex, cap: 1))
        XCTAssertFalse(try ledger.reserve(.claude, cap: 1))
    }

    func testASecondCorruptCounterAlsoRestarts() throws {
        for _ in 0..<2 {
            try "not json".write(to: world.ledgerPath, atomically: true, encoding: .utf8)
            XCTAssertTrue(try world.ledger().reserve(.claude, cap: 1))
        }
        XCTAssertEqual(try world.ledger().count(.claude), 1)
    }

    func testTheResetTimeIsRightOnADaylightSavingDay() throws {
        // 2026-03-08 in New York has 23 hours.
        var calendar = Calendar(identifier: .gregorian)
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        calendar.timeZone = zone
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 9)))
        let ledger = UsageLedger(path: world.ledgerPath, clock: { morning }, timeZone: zone)
        let expected = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9))
        XCTAssertEqual(ledger.countResetsAt, expected)
    }

    func testTheSettingsLineSaysWhatsKnown() throws {
        let ledger = world.ledger()
        _ = try ledger.reserve(.claude, cap: 200)
        XCTAssertEqual(ledger.summaryLine(.codex, cap: 200), "Codex: 0/200 today · limits known only from errors")
        try ledger.record(
            limit: RateLimitSnapshot(
                status: "rejected", resetsAt: nil, windows: ["five_hour": 0.07, "seven_day": 0.66]),
            for: .claude)
        XCTAssertEqual(ledger.summaryLine(.claude, cap: 200), "Claude: 1/200 today · 5h 7% · 7d 66% · full")
    }
}
