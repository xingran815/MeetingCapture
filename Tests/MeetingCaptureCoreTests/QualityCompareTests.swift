import Foundation
import XCTest

@testable import MeetingCaptureCore

/// `quality-compare.sh --full` spends subscription usage, so it must check the planned calls
/// against today's cap first and stop rather than exceed it (spec 04, D-18, D-19).
final class QualityCompareTests: GuardedTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private var scenarioFixtures: String { ReportFixtures.fixturesRoot.appendingPathComponent("scenarios").path }

    private func fixture(kind: String) throws -> RedactionFixture {
        let json = #"{"id":"x","kind":"\#(kind)","text":"t","formatted":[],"facts":[["a"]]}"#
        return try JSONDecoder().decode(RedactionFixture.self, from: Data(json.utf8))
    }

    /// What `print` wrote while `body` ran.
    private func captureStdout(_ body: () async -> Void) async throws -> String {
        let file = dir.appendingPathComponent("stdout-\(UUID().uuidString).txt")
        fflush(stdout)
        let saved = dup(1)
        let fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        dup2(fd, 1)
        await body()
        fflush(stdout)
        dup2(saved, 1)
        close(saved)
        close(fd)
        return try String(contentsOf: file, encoding: .utf8)
    }

    // MARK: Planned calls

    func testPlannedCallsForTheFullPipelineCountEveryStepBothWays() throws {
        let catalog = ScenarioCatalog.builtIn
        // classify + sections + review is 3 per run, 2 runs, plus one blind rating.
        for kind in ["meeting", "interview", "one_on_one", "general"] {
            XCTAssertEqual(QualityCompare.plannedCalls(try fixture(kind: kind), mode: .full, catalog: catalog), 7, kind)
        }
        // therapy and lecture add the concept search.
        for kind in ["therapy", "lecture"] {
            XCTAssertEqual(QualityCompare.plannedCalls(try fixture(kind: kind), mode: .full, catalog: catalog), 9, kind)
        }
        XCTAssertEqual(
            QualityCompare.plannedCalls(try fixture(kind: "not_a_scenario"), mode: .full, catalog: catalog), 7)
    }

    func testPlannedCallsForTheSectionsOnlyComparisonAreThree() throws {
        for kind in ReportFixtures.scenarios {
            XCTAssertEqual(
                QualityCompare.plannedCalls(try fixture(kind: kind), mode: .redaction, catalog: .builtIn), 3, kind)
        }
    }

    func testTheCommittedScenarioFixturesPlanFortySixCalls() throws {
        let fixtures = try RedactionFixture.load(directory: scenarioFixtures)
        let planned = fixtures.reduce(0) { $0 + QualityCompare.plannedCalls($1, mode: .full, catalog: .builtIn) }
        XCTAssertEqual(planned, 46)
    }

    func testAUserScenarioWithConceptsPlansTheSearchToo() throws {
        let t = ScenarioTemplate(
            name: "study", title: "Study", description: "d", rules: [],
            sections: [
                .init(id: "terms", title: "Terms", kind: .concepts, instructions: "x", note: nil)
            ])
        XCTAssertEqual(
            QualityCompare.plannedCalls(
                try fixture(kind: "study"), mode: .full, catalog: ScenarioCatalog(templates: [t])), 9)
    }

    // MARK: Stopping at the cap

    private func ledger(used: Int) throws -> UsageLedger {
        let ledger = UsageLedger(path: dir.appendingPathComponent("usage.json"))
        for _ in 0..<used { XCTAssertTrue(try ledger.reserve(.claude, cap: 10_000)) }
        return ledger
    }

    func testARunThatWouldPassTodaysCapStopsBeforeMakingAnyCall() async throws {
        let world = try FakeCLIWorld()
        defer { world.cleanUp() }
        try world.install(.claude, answers: [.init(stdout: FakeCLIWorld.claudeOK())])
        try world.install(.codex, answers: [.init(stdout: FakeCLIWorld.codexOK())])
        let ledger = try ledger(used: 190)
        var config = Config()
        config.dailyCLICallCap = 200
        let out = dir.appendingPathComponent("quality.md")

        var result = true
        let text = try await captureStdout {
            result = await withEnvironment("PATH", world.bin.path + ":/usr/bin:/bin") {
                await QualityCompare.run(
                    mode: .full, fixturesDirectory: scenarioFixtures, outputPath: out.path, config: config,
                    primary: .claude, ledger: ledger)
            }
        }
        XCTAssertFalse(result)
        XCTAssertTrue(
            text.contains("Planned: about 46 calls on Claude (56 with retries); 190 used today of 200."), text)
        XCTAssertTrue(text.contains("That would pass today's cap of 200, so nothing was run."), text)
        XCTAssertEqual(world.calls(.claude).count, 0, "no model call at all")
        XCTAssertEqual(world.calls(.codex).count, 0)
        XCTAssertEqual(try ledger.count(.claude), 190, "and nothing was counted")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: out.path), "no results file for a run that did not happen")
    }

    func testOneCallOverTheMarginStopsAndExactlyAtTheCapDoesNot() async throws {
        let world = try FakeCLIWorld()  // no CLI installed: a run that is allowed to start finds none ready
        defer { world.cleanUp() }
        var config = Config()
        config.dailyCLICallCap = 200
        for (used, stops) in [(145, true), (144, false)] {
            let ledger = UsageLedger(path: dir.appendingPathComponent("usage-\(used).json"))
            for _ in 0..<used { _ = try ledger.reserve(.claude, cap: 10_000) }
            var result = true
            let text = try await captureStdout {
                result = await withEnvironment("PATH", world.bin.path) {
                    await QualityCompare.run(
                        mode: .full, fixturesDirectory: scenarioFixtures,
                        outputPath: dir.appendingPathComponent("q.md").path,
                        config: config, primary: .claude, ledger: ledger)
                }
            }
            XCTAssertFalse(result)
            XCTAssertEqual(text.contains("so nothing was run"), stops, "used \(used): \(text)")
            if !stops { XCTAssertTrue(text.contains("No CLI is ready"), text) }
        }
        XCTAssertEqual(world.calls(.claude).count, 0)
    }

    func testTheCapIsCheckedForTheCLIThatWillRun() async throws {
        // Claude is nearly full, Codex is empty: asking for Codex fits.
        let world = try FakeCLIWorld()
        defer { world.cleanUp() }
        let ledger = try ledger(used: 190)
        var config = Config()
        config.dailyCLICallCap = 200
        let text = try await captureStdout {
            _ = await withEnvironment("PATH", world.bin.path) {
                await QualityCompare.run(
                    mode: .full, fixturesDirectory: scenarioFixtures,
                    outputPath: dir.appendingPathComponent("q.md").path,
                    config: config, primary: .codex, ledger: ledger)
            }
        }
        XCTAssertTrue(text.contains("on Codex"), text)
        XCTAssertFalse(text.contains("so nothing was run"), text)
    }

    func testTheSectionsOnlyComparisonChecksTheCapToo() async throws {
        let world = try FakeCLIWorld()
        defer { world.cleanUp() }
        try world.install(.claude, answers: [.init(stdout: FakeCLIWorld.claudeOK())])
        let ledger = try ledger(used: 199)
        var config = Config()
        config.dailyCLICallCap = 200
        let text = try await captureStdout {
            _ = await withEnvironment("PATH", world.bin.path + ":/usr/bin:/bin") {
                await QualityCompare.run(
                    mode: .redaction,
                    fixturesDirectory: ReportFixtures.fixturesRoot.appendingPathComponent("redaction").path,
                    outputPath: dir.appendingPathComponent("q.md").path, config: config, primary: .claude,
                    ledger: ledger)
            }
        }
        XCTAssertTrue(text.contains("so nothing was run"), text)
        XCTAssertEqual(world.calls(.claude).count, 0)
    }
}
