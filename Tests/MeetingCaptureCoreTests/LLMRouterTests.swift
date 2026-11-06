import XCTest

@testable import MeetingCaptureCore

final class LLMRouterTests: GuardedTestCase {

    private var world: FakeCLIWorld!
    private let plain = CLIRequest.text(tier: .normal, system: "s", input: "i")

    private var claudeFull: FakeCLIWorld.Script {
        .init(stdout: "", exit: 1, stderr: "You've hit your usage limit")
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        world = try FakeCLIWorld()
    }

    override func tearDown() {
        world.cleanUp()
        super.tearDown()
    }

    private func installBoth(claude: [FakeCLIWorld.Script]? = nil, codex: [FakeCLIWorld.Script]? = nil) throws {
        try world.install(.claude, answers: claude ?? [.init(stdout: FakeCLIWorld.claudeOK())])
        try world.install(.codex, answers: codex ?? [.init(stdout: FakeCLIWorld.codexOK())])
    }

    func testClaudeRunsEveryTierWhenBothAreReady() async throws {
        try installBoth()
        let router = world.router()
        for tier in ModelTier.allCases {
            let result = try await router.call(.text(tier: tier, system: "s", input: "i"))
            XCTAssertEqual(result.cli, .claude)
        }
        XCTAssertEqual(world.calls(.claude).count, 3)
        XCTAssertEqual(world.calls(.codex).count, 0, "tiers must not mix across CLIs")
        XCTAssertTrue(router.notes.isEmpty)
    }

    func testPrimaryCLIIsASetting() async throws {
        try installBoth()
        let result = try await world.router(primary: .codex).call(plain)
        XCTAssertEqual(result.cli, .codex)
    }

    func testOneCLIAvailableIsUsed() async throws {
        try world.install(.codex, answers: [.init(stdout: FakeCLIWorld.codexOK())])
        let result = try await world.router().call(plain)
        XCTAssertEqual(result.cli, .codex)
    }

    func testFullLimitSwitchesAndStaysSwitched() async throws {
        try installBoth(claude: [.init(stdout: FakeCLIWorld.claudeOK()), claudeFull])
        let router = world.router()
        let first = try await router.call(plain)
        XCTAssertEqual(first.cli, .claude)
        let second = try await router.call(plain)
        XCTAssertEqual(second.cli, .codex, "fills up mid-run: Codex takes over")
        let third = try await router.call(plain)
        XCTAssertEqual(third.cli, .codex, "stays on Codex for the remaining steps")
        XCTAssertEqual(world.calls(.claude).count, 2)
        XCTAssertTrue(router.notes.joined().contains("Codex"), "the report must say so")
    }

    func testOtherErrorsDoNotFallBack() async throws {
        try installBoth(claude: [.init(stdout: "", exit: 1, stderr: "model not found")])
        do {
            _ = try await world.router().call(plain)
            XCTFail("expected the error to surface")
        } catch let error as CLIError {
            guard case .failed(.claude, _) = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(world.calls(.codex).count, 0, "no fallback for a non-limit error")
    }

    func testKnownFullFromAnEarlierRunSkipsWithoutSpendingACall() async throws {
        try installBoth()
        try world.ledger().record(
            limit: RateLimitSnapshot(status: "rejected", resetsAt: world.now.addingTimeInterval(3600), windows: [:]),
            for: .claude)
        let result = try await world.router().call(plain)
        XCTAssertEqual(result.cli, .codex)
        XCTAssertEqual(world.calls(.claude).count, 0)
    }

    func testKnownFullExpiresAtItsReset() async throws {
        try installBoth()
        try world.ledger().record(
            limit: RateLimitSnapshot(status: "rejected", resetsAt: world.now.addingTimeInterval(-1), windows: [:]),
            for: .claude)
        let result = try await world.router().call(plain)
        XCTAssertEqual(result.cli, .claude)
    }

    func testNoCLIReportsWhy() async throws {
        do {
            _ = try await world.router().call(plain)
            XCTFail("expected noCLI")
        } catch let error as LLMRouter.RouterError {
            guard case .noCLI(let reasons) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(reasons.count, 2)
        }
    }

    // MARK: - Daily cap (D-18)

    func testCall200RunsAndCall201SwitchesCLI() async throws {
        try installBoth()
        let router = world.router(cap: 3)
        for _ in 0..<3 {
            let r = try await router.call(plain)
            XCTAssertEqual(r.cli, .claude)
        }
        let next = try await router.call(plain)
        XCTAssertEqual(next.cli, .codex)
        XCTAssertEqual(try world.ledger().count(.claude), 3)
        XCTAssertEqual(try world.ledger().count(.codex), 1)
        XCTAssertTrue(router.notes.joined().contains("daily cap"))
    }

    func testRealCapValue() async throws {
        // The default itself, without starting 200 processes.
        let ledger = world.ledger()
        for _ in 0..<UsageLedger.defaultCap {
            let reserved = try ledger.reserve(.claude, cap: UsageLedger.defaultCap)
            XCTAssertTrue(reserved)
        }
        XCTAssertFalse(try ledger.reserve(.claude, cap: UsageLedger.defaultCap), "call 201 is refused")
        XCTAssertEqual(UsageLedger.defaultCap, 200)
    }

    func testBothCappedStopsAndSaysWhen() async throws {
        try installBoth()
        let router = world.router(cap: 1)
        _ = try await router.call(plain)
        _ = try await router.call(plain)
        do {
            _ = try await router.call(plain)
            XCTFail("expected a stop")
        } catch let error as LLMRouter.RouterError {
            guard case .allUsageFull(let resets, _) = error else { return XCTFail("\(error)") }
            XCTAssertGreaterThan(resets, world.now)
            XCTAssertTrue(error.localizedDescription.contains("no API profile was used"))
        }
        XCTAssertEqual(world.calls(.claude).count, 1)
        XCTAssertEqual(world.calls(.codex).count, 1)
    }

    func testBothCappedMakesNoAPICall() async throws {
        // The backend is CLI-only: a capped run must end in an error, never reach Summarizer.
        try installBoth()
        let router = world.router(cap: 1)
        _ = try await router.call(plain)
        _ = try await router.call(plain)
        let requestsBefore = NetworkRefusal.attempts
        let pipeline = SummaryPipeline(backend: CLISummaryBackend(router: router), redaction: true)
        do {
            _ = try await pipeline.run(transcript: "hello", forcedStyle: .meeting)
            XCTFail("expected a stop")
        } catch {
            XCTAssertTrue(error is LLMRouter.RouterError, "\(error)")
        }
        XCTAssertEqual(NetworkRefusal.attempts, requestsBefore, "nothing may try a network request")
    }

    func testCountResetsNextDay() throws {
        let ledger = world.ledger()
        XCTAssertTrue(try ledger.reserve(.claude, cap: 1))
        XCTAssertFalse(try ledger.reserve(.claude, cap: 1))
        world.now = ledger.countResetsAt
        XCTAssertTrue(try ledger.reserve(.claude, cap: 1), "a new local day restarts the count")
        XCTAssertEqual(try ledger.count(.claude), 1)
    }

    func testResetIsAtLocalMidnightNotUTC() throws {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = UsageLedger(path: world.ledgerPath, clock: { clock }, timeZone: tokyo)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        XCTAssertEqual(calendar.component(.hour, from: ledger.countResetsAt), 0)
        clock = ledger.countResetsAt.addingTimeInterval(-1)
        XCTAssertTrue(try ledger.reserve(.claude, cap: 1))
        clock = clock.addingTimeInterval(2)
        XCTAssertTrue(try ledger.reserve(.claude, cap: 1), "one second later it is tomorrow")
    }

    func testFailedCallsCount() async throws {
        try installBoth(claude: [.init(stdout: "", exit: 1, stderr: "boom")])
        _ = try? await world.router().call(plain)
        XCTAssertEqual(try world.ledger().count(.claude), 1)
    }

    func testCorruptCounterIsKeptAndRestarted() throws {
        try "not json".write(to: world.ledgerPath, atomically: true, encoding: .utf8)
        XCTAssertTrue(try world.ledger().reserve(.claude, cap: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.ledgerPath.path + ".corrupt"))
    }

    func testTwoProcessesCountingAtOnceLoseNoCalls() throws {
        // A real second process, because that's what the lock is for.
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let binary = products.appendingPathComponent("MeetingCaptureCLI")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path), binary.path)
        let processes = (0..<2).map { _ -> Process in
            let p = Process()
            p.executableURL = binary
            p.arguments = ["--usage-ledger-stress", world.ledgerPath.path, "--calls", "100"]
            return p
        }
        for p in processes { try p.run() }
        for p in processes {
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }
        let realClock = UsageLedger(path: world.ledgerPath)
        XCTAssertEqual(try realClock.count(.claude), 200)
    }
}
