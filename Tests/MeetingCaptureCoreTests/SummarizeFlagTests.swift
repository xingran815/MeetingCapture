import XCTest

@testable import MeetingCaptureCore

/// The built binary in flag mode, with fake `claude`/`codex` only. Every run sets
/// `MEETINGCAPTURE_E2E=1` and `MEETINGCAPTURE_HOME` to a fresh temp folder, a PATH holding
/// only the fakes, and no API keys, because `NSHomeDirectory()` ignores `$HOME` and an
/// earlier run reached the real config.
final class SummarizeFlagTests: XCTestCase {

    struct Result {
        let status: Int32
        let out: String
        let err: String
    }

    private var world: FakeCLIWorld!
    private var work: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        world = try FakeCLIWorld()
        work = world.root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() {
        world.cleanUp()
        super.tearDown()
    }

    private var binary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("MeetingCaptureCLI")
    }

    private var usagePath: URL { world.root.appendingPathComponent(".config/MeetingCapture/usage.json") }

    private func writeTranscript(_ name: String = "m.txt", scenario: String = "meeting") throws -> URL {
        let url = work.appendingPathComponent(name)
        try ReportFixtures.read(scenario, "transcript.txt").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Never inherits the caller's environment.
    private func run(_ arguments: [String]) throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("MeetingCaptureCLI isn't built beside the tests: \(binary.path)")
        }
        let p = Process()
        p.executableURL = binary
        p.arguments = arguments
        p.currentDirectoryURL = work
        p.environment = [
            "PATH": world.bin.path + ":/usr/bin:/bin",
            "MEETINGCAPTURE_E2E": "1",
            "MEETINGCAPTURE_HOME": world.root.path,
            "HOME": world.root.path,
            "TMPDIR": world.root.path + "/",
            "USER": "tester",
        ]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(
            status: p.terminationStatus, out: String(decoding: outData, as: UTF8.self),
            err: String(decoding: errData, as: UTF8.self))
    }

    private func files(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func installGoodMeeting() throws { try world.installFixture("meeting") }

    // MARK: Guard (runs before any other binary test could matter)

    func testAppHomeIgnoresHomeVariableWithoutE2E() {
        let home = AppHome.url(environment: ["MEETINGCAPTURE_HOME": "/tmp/elsewhere"])
        XCTAssertEqual(home.path, NSHomeDirectory())
        let off = AppHome.url(environment: ["MEETINGCAPTURE_HOME": "/tmp/elsewhere", "MEETINGCAPTURE_E2E": "0"])
        XCTAssertEqual(off.path, NSHomeDirectory())
    }

    func testAppHomeUsesHomeVariableOnlyWithE2EAndAbsolutePath() {
        let on = AppHome.url(environment: ["MEETINGCAPTURE_HOME": "/tmp/elsewhere", "MEETINGCAPTURE_E2E": "1"])
        XCTAssertEqual(on.path, "/tmp/elsewhere")
        let relative = AppHome.url(environment: ["MEETINGCAPTURE_HOME": "relative/dir", "MEETINGCAPTURE_E2E": "1"])
        XCTAssertEqual(relative.path, NSHomeDirectory())
    }

    func testBinaryReadsItsHomeFromTheTempFolder() throws {
        // A scenario that exists only in the temp home is accepted, so that home is the one in use.
        let dir = world.root.appendingPathComponent(".config/MeetingCapture/scenarios")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let template = """
            {"name":"zzguard","title":"Guard","description":"Only for the home guard test.","rules":[],
             "sections":[{"id":"summary","title":"Summary","kind":"prose","instructions":"Summarize."}]}
            """
        try template.write(to: dir.appendingPathComponent("zzguard.json"), atomically: true, encoding: .utf8)
        try world.install(.claude, answers: [FakeCLIWorld.Script(stdout: "", exit: 3, stderr: "fake refuses")])
        let t = try writeTranscript()
        let r = try run(["--scenario", "zzguard", "--summarize-only", t.path])
        XCTAssertFalse(r.err.contains("no scenario called"), r.err)
        XCTAssertNotEqual(r.status, 2, r.err)
        // And an unknown one in the same home is refused, so the check above can fail.
        let bad = try run(["--scenario", "zzother", "--summarize-only", t.path])
        XCTAssertEqual(bad.status, 2)
        XCTAssertTrue(bad.err.contains("zzguard"), "the temp home's scenario is listed: \(bad.err)")
    }

    // MARK: 1. Good run

    func testSummarizeOnlyWritesMdJsonAndHtmlNextToTheTranscript() throws {
        try installGoodMeeting()
        let t = try writeTranscript()
        let r = try run(["--summarize-only", t.path])
        XCTAssertEqual(r.status, 0, r.out + r.err)
        // M5 review finding 10: the terminal says which backend writes the report.
        XCTAssertTrue(r.out.contains("Writing the report via subscription CLI…"), r.out)

        let names = files(in: work)
        XCTAssertTrue(names.contains("m.md"), "\(names)")
        XCTAssertTrue(names.contains("m.report.json"), "\(names)")
        XCTAssertTrue(names.contains("m.txt"))
        let html = names.filter { $0.hasSuffix(".html") }
        XCTAssertEqual(html.count, 1, "\(names)")
        if let h = html.first {
            XCTAssertNotNil(
                h.range(of: "^[0-9]{8}_[0-9]{6}_.+\\.html$", options: .regularExpression), "file name \(h)")
            let content = try String(contentsOf: work.appendingPathComponent(h), encoding: .utf8)
            XCTAssertTrue(content.contains("<html"))
        }
        XCTAssertEqual(
            try String(contentsOf: t, encoding: .utf8), try ReportFixtures.read("meeting", "transcript.txt"))
    }

    func testTerminalShowsTranscriptThenSummaryThenHtmlPath() throws {
        try installGoodMeeting()
        let t = try writeTranscript()
        let r = try run(["--summarize-only", t.path])
        XCTAssertEqual(r.status, 0, r.out + r.err)
        let transcript = r.out.range(of: "──── transcript")
        let timed = r.out.range(of: "[00:00:21] Speaker 1:")
        let summary = r.out.range(of: "──── summary")
        let report = r.out.range(of: "Report: ")
        let html = r.out.range(of: ".html")
        XCTAssertNotNil(transcript, r.out)
        XCTAssertNotNil(timed, "time and speaker are shown: \(r.out)")
        XCTAssertNotNil(summary)
        XCTAssertNotNil(report)
        XCTAssertNotNil(html)
        if let transcript, let timed, let summary, let report, let html {
            XCTAssertLessThan(transcript.lowerBound, timed.lowerBound)
            XCTAssertLessThan(timed.lowerBound, summary.lowerBound)
            XCTAssertLessThan(summary.lowerBound, report.lowerBound)
            XCTAssertLessThan(report.lowerBound, html.lowerBound)
        }
        XCTAssertTrue(r.out.contains(work.path), "the HTML path is printed")
    }

    // MARK: 2. Malformed replies

    func testTwoMalformedSectionRepliesFailAndKeepTheTranscript() throws {
        let classify = FakeCLIWorld.jsonScript(try ReportFixtures.read("meeting", "classify.json"))
        let bad = FakeCLIWorld.jsonScript(#"{"nonsense":true}"#)
        try world.install(.claude, answers: [classify, bad, bad])
        let t = try writeTranscript()
        let before = try Data(contentsOf: t)
        let r = try run(["--summarize-only", t.path])
        XCTAssertNotEqual(r.status, 0, r.out + r.err)
        let message = r.out + r.err
        XCTAssertTrue(message.contains("The transcript is kept at"), message)
        XCTAssertTrue(message.contains(t.path), message)
        XCTAssertEqual(try Data(contentsOf: t), before)
        XCTAssertEqual(files(in: work), ["m.txt"], "nothing else is written")
    }

    // MARK: 3. Removed flags

    func testTherapyFlagIsRemovedAndCallsNoModel() throws {
        try installGoodMeeting()
        let t = try writeTranscript()
        let r = try run(["--therapy", "--summarize-only", t.path])
        XCTAssertEqual(r.status, 2, r.err)
        XCTAssertTrue((r.out + r.err).contains("--scenario"))
        XCTAssertTrue(world.calls(.claude).isEmpty)
        XCTAssertTrue(world.calls(.codex).isEmpty)
        XCTAssertEqual(files(in: work), ["m.txt"])
    }

    func testSummaryStyleFlagIsRemovedAndCallsNoModel() throws {
        try installGoodMeeting()
        let t = try writeTranscript()
        let r = try run(["--summary-style", "meeting", "--summarize-only", t.path])
        XCTAssertEqual(r.status, 2, r.err)
        XCTAssertTrue((r.out + r.err).contains("--scenario"))
        XCTAssertTrue(world.calls(.claude).isEmpty)
        XCTAssertTrue(world.calls(.codex).isEmpty)
        XCTAssertEqual(files(in: work), ["m.txt"])
    }

    // MARK: 4. --scenario

    func testUnknownScenarioExitsTwoListingKnownOnesWithoutAModelCall() throws {
        try installGoodMeeting()
        let t = try writeTranscript()
        let r = try run(["--scenario", "nosuch", "--summarize-only", t.path])
        XCTAssertEqual(r.status, 2, r.err)
        let message = r.out + r.err
        XCTAssertTrue(message.contains("nosuch"), message)
        for name in ReportFixtures.scenarios { XCTAssertTrue(message.contains(name), "lists \(name): \(message)") }
        XCTAssertTrue(world.calls(.claude).isEmpty)
        XCTAssertEqual(files(in: work), ["m.txt"])
    }

    func testForcedScenarioSkipsTheClassifier() throws {
        // Replies in call order for a forced therapy run: sections, concepts, review.
        var replies = [try ReportFixtures.read("therapy", "sections.json")]
        if ReportFixtures.exists("therapy", "concepts.json") {
            replies.append(try ReportFixtures.read("therapy", "concepts.json"))
        }
        replies.append(try ReportFixtures.read("therapy", "review.json"))
        try world.install(.claude, answers: replies.map { FakeCLIWorld.jsonScript($0) })
        let t = try writeTranscript(scenario: "therapy")
        let r = try run(["--scenario", "therapy", "--summarize-only", t.path])
        XCTAssertEqual(r.status, 0, r.out + r.err)
        let calls = world.calls(.claude)
        XCTAssertEqual(calls.count, replies.count, "no classifier call")
        let first = calls.first?.everything ?? ""
        XCTAssertTrue(first.contains("\"sections\"") || first.contains("sections"), "first call is the sections call")
        let classifierSchemaMarker = "\"confidence\""
        XCTAssertFalse(
            (calls.first?.args.joined(separator: " ") ?? "").contains("\"scenario\"")
                && first.contains(classifierSchemaMarker) && !first.contains("\"sections\""),
            "the first call is not the classifier")
    }

    // MARK: 5. Ledger

    func testUsageIsCountedInTheTempHomeLedger() throws {
        try installGoodMeeting()
        let t = try writeTranscript()
        let r = try run(["--summarize-only", t.path])
        XCTAssertEqual(r.status, 0, r.out + r.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: usagePath.path), "usage.json in the temp home")
        let ledger = UsageLedger(path: usagePath)
        XCTAssertEqual(try ledger.count(.claude), world.calls(.claude).count)
        XCTAssertGreaterThan(world.calls(.claude).count, 0)
    }
}
