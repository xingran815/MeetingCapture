import XCTest

@testable import MeetingCaptureCore

/// Keeps the terminal side of the M5.2 rows in docs/parity.md true: runs the built binary
/// with piped stdin (menus fall back to numbered lists) in a throwaway home and output
/// folder, with only the fake `claude` and `codex` on PATH. `q` is always the last input.
final class GroupTerminalTests: XCTestCase {

    private var world: FakeCLIWorld!
    private var out: URL!
    private let recName = "meeting_20261107_124800"
    private var base: URL { out.appendingPathComponent(recName) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        world = try FakeCLIWorld()
        out = world.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let config = world.root.appendingPathComponent(".config/MeetingCapture")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let json = #"{"outputDirectory": \#(FakeCLIWorld.jsonString(out.path))}"#
        try json.write(to: config.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try world.install(.claude, answers: [.init(stdout: FakeCLIWorld.claudeOK())])
        try world.install(.codex, answers: [.init(stdout: FakeCLIWorld.codexOK())])
        try writeRecording(recName, topic: "Invented topic")
    }

    override func tearDown() {
        world.cleanUp()
        super.tearDown()
    }

    private func writeRecording(_ name: String, topic: String) throws {
        let base = out.appendingPathComponent(name)
        try "[00:00:01] You: hello\n".write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        try Data().write(to: out.appendingPathComponent(name + ".m4a"))
        let side = RecordingSidecar(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), state: .processed,
            transcribedAt: Date(timeIntervalSince1970: 1_800_000_000), audioFiles: [name + ".m4a"])
        try side.save(to: RecordingSidecar.url(forBase: base))
        let report = Report(
            topic: topic, scenario: "meeting", scenarioTitle: "Company meeting", createdAt: "2026-11-07T12:48:00Z",
            durationSeconds: 60, language: "en", models: .init(), reviewed: true, notices: [], sections: [],
            reviewChanges: [], transcript: [])
        try JSONEncoder().encode(report).write(to: base.appendingPathExtension("report.json"))
    }

    private var binary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("MeetingCaptureCLI")
    }

    private func shell(_ lines: [String], limit: TimeInterval = 40) throws -> (
        status: Int32, out: String, timedOut: Bool
    ) {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("MeetingCaptureCLI isn't built beside the tests: \(binary.path)")
        }
        let p = Process()
        p.executableURL = binary
        p.arguments = []
        p.currentDirectoryURL = world.root
        p.environment = [
            "PATH": world.bin.path + ":/usr/bin:/bin", "MEETINGCAPTURE_E2E": "1",
            "MEETINGCAPTURE_HOME": world.root.path, "HOME": world.root.path, "TMPDIR": world.root.path + "/",
            "USER": "tester",
        ]
        let stdout = Pipe()
        let stdin = Pipe()
        p.standardOutput = stdout
        p.standardError = stdout
        p.standardInput = stdin
        try p.run()
        stdin.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try? stdin.fileHandleForWriting.close()
        var timedOut = false
        let killer = DispatchWorkItem {
            timedOut = true
            p.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: killer)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self), timedOut)
    }

    private func groups() throws -> [ReportGroup] { try GroupStore.load(in: out) }

    private func rows(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    // MARK: menu rows

    func testMainMenuHasGroupsOnSevenAndLibraryActionsHaveG() throws {
        let r = try shell(["6", "1", "b", "q"])
        XCTAssertFalse(r.timedOut, r.out)
        XCTAssertTrue(rows(r.out).contains { $0.hasPrefix("  7) ") && $0.contains("Groups") }, r.out)
        XCTAssertTrue(rows(r.out).contains { $0.hasPrefix("  g) ") && $0.contains("Group") }, r.out)
        XCTAssertTrue(r.out.contains("[none]"), "an ungrouped report shows [none]: \(r.out)")
    }

    func testTheDocNamesTheGroupRowsTheTerminalHas() throws {
        let doc = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("docs/parity.md"), encoding: .utf8)
        for ref in ["Library › g", "Main menu 7", "Main menu 7 › group › x", "Main menu 7 › group › c", "Library › w"] {
            XCTAssertTrue(doc.contains(ref), "parity.md lost “\(ref)”")
        }
    }

    // MARK: Done-when 10: make a group from 7, put the report in it from Library › g

    func testMakeAGroupFromMainMenu7ThenPutTheLibraryReportInItAndSeeItsNameInTheActionList() throws {
        // 7 > n > name > (list again) > b; Library > entry > g > pick group 1; Library > entry > action list; back; quit.
        let r = try shell(["7", "n", "Weekly team", "b", "6", "1", "g", "1", "6", "1", "b", "q"])
        XCTAssertFalse(r.timedOut, r.out)
        XCTAssertEqual(r.status, 0, r.out)
        XCTAssertTrue(r.out.contains("Made."), r.out)
        XCTAssertTrue(r.out.contains("In \"Weekly team\""), r.out)
        XCTAssertTrue(
            rows(r.out).contains { $0.hasPrefix("  g) ") && $0.contains("[Weekly team]") },
            "the action list shows the group name:\n\(r.out)")
        let g = try XCTUnwrap(try groups().first)
        XCTAssertEqual(g.name, "Weekly team")
        XCTAssertEqual(g.members, [recName])
    }

    func testLibraryGCanMakeANewGroupPutTheReportInItAndTakeItOut() throws {
        let r1 = try shell(["6", "1", "g", "n", "Series A", "q"])
        XCTAssertFalse(r1.timedOut, r1.out)
        XCTAssertTrue(r1.out.contains("Made \"Series A\""), r1.out)
        XCTAssertEqual(try groups().first?.members, [recName])
        // "No group" is the row after "New group…": groups(1) then n then x.
        let r2 = try shell(["6", "1", "g", "x", "q"])
        XCTAssertFalse(r2.timedOut, r2.out)
        XCTAssertTrue(r2.out.contains("Not in a group."), r2.out)
        XCTAssertEqual(try groups().first?.members, [], "the group stays, the report is out")
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathExtension("report.json").path))
    }

    func testAGroupWithTheSameNameInOtherCaseIsRefusedWithAMessage() throws {
        try GroupStore.create(named: "Weekly team", in: out)
        let r = try shell(["7", "n", "WEEKLY TEAM", "b", "q"])
        XCTAssertFalse(r.timedOut, r.out)
        XCTAssertTrue(r.out.contains("There's already a group called"), r.out)
        XCTAssertEqual(try groups().count, 1)
    }

    func testAnUnreadableGroupsFileIsReportedAndLeftAloneFromBothPlaces() throws {
        let junk = Data("{ nope".utf8)
        try junk.write(to: GroupStore.url(in: out))
        let r = try shell(["7", "6", "1", "g", "q"])
        XCTAssertFalse(r.timedOut, r.out)
        XCTAssertTrue(r.out.contains("groups.json can't be read"), r.out)
        XCTAssertEqual(try Data(contentsOf: GroupStore.url(in: out)), junk)
    }

    // MARK: group menu: rename, redaction switch, pinned scenario, take out, delete

    func testGroupMenuRenameChangesTheName() throws {
        try GroupStore.create(named: "Old name", in: out)
        let r = try shell(["7", "1", "r", "New name", "b", "q"])
        XCTAssertFalse(r.timedOut, r.out)
        XCTAssertTrue(r.out.contains("Renamed."), r.out)
        XCTAssertEqual(try groups().first?.name, "New name")
    }

    func testGroupMenuRedactionSwitchTurnsOffAndTheMenuSaysSo() throws {
        try GroupStore.create(named: "Series", in: out)
        let r = try shell(["7", "1", "x", "b", "q"])
        XCTAssertFalse(r.timedOut, r.out)
        XCTAssertTrue(r.out.contains("without redaction"), r.out)
        XCTAssertTrue(r.out.contains("The transcript is still redacted"), r.out)
        XCTAssertEqual(try groups().first?.redactContext, false)
    }

    func testGroupMenuRedactionRowIsDisabledWhenRedactionIsOffInSettings() throws {
        try GroupStore.create(named: "Series", in: out)
        let config = world.root.appendingPathComponent(".config/MeetingCapture/config.json")
        let json = #"{"outputDirectory": \#(FakeCLIWorld.jsonString(out.path)), "redactionEnabled": false}"#
        try json.write(to: config, atomically: true, encoding: .utf8)
        let r = try shell(["7", "1", "b", "b", "q"])
        XCTAssertFalse(r.timedOut, r.out)
        XCTAssertTrue(r.out.contains("off (off in Settings)"), r.out)
        XCTAssertEqual(try groups().first?.redactContext, true, "nothing changed")
    }

    func testGroupMenuPinsAScenarioAndUnpinsIt() throws {
        try GroupStore.create(named: "Series", in: out)
        let first = try XCTUnwrap(ReportGroups.scenarioChoices.first).name
        let r = try shell(["7", "1", "c", "1", "b", "q"])
        XCTAssertFalse(r.timedOut, r.out)
        XCTAssertTrue(r.out.contains("Saved."), r.out)
        XCTAssertEqual(try groups().first?.scenario, first)
        let count = ReportGroups.scenarioChoices.count
        XCTAssertGreaterThan(count, 0)
        // "None: classify each report" is key u.
        let r2 = try shell(["7", "1", "c", "u", "b", "q"])
        XCTAssertFalse(r2.timedOut, r2.out)
        XCTAssertNil(try groups().first?.scenario)
    }

    func testGroupMenuTakesAReportOutAndKeepsIt() throws {
        let g = try GroupStore.create(named: "Series", in: out)
        try GroupStore.add(recName, to: g.id, in: out)
        let r = try shell(["7", "1", "m", "1", "b", "q"])
        XCTAssertFalse(r.timedOut, r.out)
        XCTAssertTrue(r.out.contains("Taken out."), r.out)
        XCTAssertEqual(try groups().first?.members, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathExtension("report.json").path))
    }

    func testGroupMenuDeleteNeedsAYesAndKeepsTheReports() throws {
        let g = try GroupStore.create(named: "Series", in: out)
        try GroupStore.add(recName, to: g.id, in: out)
        let no = try shell(["7", "1", "d", "n", "b", "q"])
        XCTAssertFalse(no.timedOut, no.out)
        XCTAssertEqual(try groups().count, 1, "answering n deletes nothing")
        let yes = try shell(["7", "1", "d", "y", "b", "q"])
        XCTAssertFalse(yes.timedOut, yes.out)
        XCTAssertTrue(yes.out.contains("Deleted the group."), yes.out)
        XCTAssertEqual(try groups().count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathExtension("report.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathExtension("txt").path))
    }

    func testAGroupNameWithAnEscapeCodeNeverReachesTheTerminal() throws {
        let g = try GroupStore.create(named: "Series", in: out)
        try GroupStore.add(recName, to: g.id, in: out)
        // A hand-edited groups.json can hold anything.
        try GroupStore.change(in: out) { $0[0].name = "Bad\u{1B}[2J name" }
        let r = try shell(["7", "1", "b", "b", "6", "1", "g", "b", "6", "1", "b", "q"])
        XCTAssertFalse(r.timedOut, r.out)
        XCTAssertTrue(r.out.contains("Bad"), r.out)
        XCTAssertFalse(r.out.contains("\u{1B}"), "no ESC from a group name in any menu")
    }

    // MARK: Library › w says which group's context is used

    func testRewritingAGroupedReportPrintsTheGroupLine() throws {
        let g = try GroupStore.create(named: "Weekly team", in: out)
        try GroupStore.add(recName, to: g.id, in: out)
        let r = try shell(["6", "1", "w", "q"], limit: 60)
        XCTAssertFalse(r.timedOut, r.out)
        XCTAssertTrue(r.out.contains("In the group \"Weekly team\""), r.out)
        XCTAssertTrue(r.out.contains("never transcripts"), r.out)
    }

    func testRewritingAnUngroupedReportPrintsNoGroupLine() throws {
        let r = try shell(["6", "1", "w", "q"], limit: 60)
        XCTAssertFalse(r.timedOut, r.out)
        XCTAssertFalse(r.out.contains("In the group"), r.out)
    }
}
