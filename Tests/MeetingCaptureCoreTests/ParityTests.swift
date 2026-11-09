import XCTest

@testable import MeetingCaptureCore

/// Keeps the terminal side of docs/parity.md true. It runs the built binary with piped
/// stdin (so menus fall back to numbered lists) in a throwaway home and output folder,
/// with only the fake `claude` and `codex` on PATH, and reads what the menus print.
/// The shell has no 'back' on the main menu: `q` is always the last input, because end
/// of input on the main menu would pick item 1 (Record).
final class ParityTests: XCTestCase {

    private var world: FakeCLIWorld!
    private var out: URL!

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
        try writeOneFullRecording()
    }

    override func tearDown() {
        world.cleanUp()
        super.tearDown()
    }

    /// A recording with audio, transcript and report, so every Library action is enabled.
    private func writeOneFullRecording() throws {
        let base = out.appendingPathComponent("meeting_20261107_124800")
        try "[00:00:01] You: hello\n".write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        try Data().write(to: out.appendingPathComponent("meeting_20261107_124800.m4a"))
        let side = RecordingSidecar(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), state: .processed,
            transcribedAt: Date(timeIntervalSince1970: 1_800_000_000), audioFiles: ["meeting_20261107_124800.m4a"])
        try side.save(to: RecordingSidecar.url(forBase: base))
        let report = Report(
            topic: "Invented topic", scenario: "meeting", scenarioTitle: "Company meeting",
            createdAt: "2026-11-07T12:48:00Z", durationSeconds: 60, language: "en", models: .init(), reviewed: true,
            notices: [], sections: [], reviewChanges: [], transcript: [])
        try JSONEncoder().encode(report).write(to: base.appendingPathExtension("report.json"))
    }

    private var binary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("MeetingCaptureCLI")
    }

    /// Runs the shell on these input lines. Killed after `limit` seconds.
    private func shell(_ lines: [String], limit: TimeInterval = 40, env: [String: String] = [:]) throws -> (
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
            "PATH": world.bin.path + ":/usr/bin:/bin",
            "MEETINGCAPTURE_E2E": "1",
            "MEETINGCAPTURE_HOME": world.root.path,
            "HOME": world.root.path,
            "TMPDIR": world.root.path + "/",
            "USER": "tester",
        ].merging(env) { _, new in new }
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

    /// The prompt "> " is printed without a newline, so the first result shares its line.
    private func resultLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.hasPrefix("> ") ? String($0.dropFirst(2)) : $0 }
            .filter { $0.hasPrefix("✓") || $0.hasPrefix("✗") }
    }

    private func parityDoc() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/parity.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    // MARK: Menus

    func testMainMenuLibraryAndSettingsNameEveryTerminalEntryTheDocNames() throws {
        // Main menu, Library list, an entry's actions, back out; Settings, back out; Quit.
        let r = try shell(["6", "1", "b", "5", "b", "q"])
        XCTAssertFalse(r.timedOut, r.out)
        XCTAssertEqual(r.status, 0, r.out)
        XCTAssertTrue(r.out.contains("Bye."), r.out)
        for label in [
            "Record a meeting", "Rename or merge speakers", "Library: open a report, re-run a step",
            // Library entry actions
            "Open report", "Transcribe again", "Write the report again", "Show in Finder",
            // Settings
            "Test CLI connection", "Redaction", "Keep audio for", "Output directory", "Whisper model", "LLM route",
            "Audio source", "Mic capture",
        ] {
            XCTAssertTrue(r.out.contains(label), "terminal never printed “\(label)”:\n\(r.out)")
        }
        XCTAssertTrue(r.out.contains("Invented topic"), "the library lists the recording")
    }

    func testEveryShortcutKeyTheDocNamesIsARowOnThatMenu() throws {
        let doc = try parityDoc()
        let mainKeys = Set(matches(#"Main menu (\d)"#, in: doc))
        let settingsKeys = Set(matches(#"Settings › ([a-z0-9])(?![A-Za-z])"#, in: doc))
        let libraryKeys = Set(matches(#"Library › ([a-z])(?![A-Za-z])"#, in: doc))
        XCTAssertGreaterThanOrEqual(mainKeys.count, 3, "the doc's main-menu refs weren't found")
        XCTAssertGreaterThanOrEqual(settingsKeys.count, 6, "the doc's settings refs weren't found")
        XCTAssertGreaterThanOrEqual(libraryKeys.count, 4, "the doc's library refs weren't found")

        let r = try shell(["6", "1", "b", "5", "b", "q"])
        XCTAssertFalse(r.timedOut, r.out)
        let lines = r.out.components(separatedBy: "\n")
        func hasRow(_ key: String) -> Bool { lines.contains { $0.hasPrefix("  \(key)) ") } }
        for k in mainKeys { XCTAssertTrue(hasRow(k), "Main menu \(k) from parity.md is not a row") }
        for k in settingsKeys { XCTAssertTrue(hasRow(k), "Settings › \(k) from parity.md is not a row") }
        for k in libraryKeys { XCTAssertTrue(hasRow(k), "Library › \(k) from parity.md is not a row") }
    }

    func testLibraryWithNothingInItSaysSoAndReturnsToTheMenu() throws {
        try FileManager.default.removeItem(at: out)
        let r = try shell(["6", "q"])
        XCTAssertFalse(r.timedOut, r.out)
        XCTAssertTrue(r.out.contains("No recordings in"), r.out)
        XCTAssertTrue(r.out.contains("Bye."), r.out)
    }

    func testTheDocNamesTheSameLabelsThisTestChecks() throws {
        let doc = try parityDoc()
        for word in [
            "Library", "Open report", "Rename and merge speakers", "Show in Finder", "Test CLI connection",
            "Keep audio for", "Output folder", "Whisper model", "LLM route", "Audio source", "Mic capture", "Redaction",
        ] {
            XCTAssertTrue(
                doc.contains(word) || doc.lowercased().contains(word.lowercased()), "parity.md lost “\(word)”")
        }
    }

    // MARK: M5.1 notebook (spec 05.1 Done-when: parity checklist)

    func testLibraryActionsForRenameNotesSendNotesAndDeleteExistAndTheDocNamesThem() throws {
        let doc = try parityDoc()
        for key in ["r", "n", "l", "d"] {
            XCTAssertTrue(doc.contains("Library › \(key)"), "parity.md doesn't name Library › \(key)")
        }
        XCTAssertTrue(doc.contains("Desktop only"), "editing content is documented as the desktop-only exception")
        let r = try shell(["6", "1", "b", "q"])
        XCTAssertFalse(r.timedOut, r.out)
        let lines = r.out.components(separatedBy: "\n")
        for (key, label) in [
            ("r", "Rename the title"), ("n", "Notes"), ("l", "Send notes to the LLM"), ("d", "Delete"),
        ] {
            XCTAssertTrue(
                lines.contains { $0.hasPrefix("  \(key)) ") && $0.contains(label) }, "Library › \(key) \(label)")
        }
    }

    func testLibraryDeleteListsTheFilesAndAnsweringNoMovesNothing() throws {
        let before = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        // Library, the entry, d, then "n" to "Move N file(s)?", then quit. Never answers y: the real Trash isn't used.
        let r = try shell(["6", "1", "d", "n", "q"])
        XCTAssertFalse(r.timedOut, r.out)
        XCTAssertTrue(r.out.contains("These files go to the Trash"), r.out)
        XCTAssertTrue(r.out.contains("meeting_20261107_124800.m4a"), r.out)
        XCTAssertTrue(r.out.contains("Nothing moved"), r.out)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted(), before)
        let listed = r.out.components(separatedBy: "\n").filter { $0.hasPrefix("   meeting_20261107_124800") }
        XCTAssertEqual(
            listed.last?.trimmingCharacters(in: .whitespaces), "meeting_20261107_124800.mcmeta.json", "sidecar last")
    }

    func testLibrarySendNotesToggleFlipsAndShowsInTheMenuNextTime() throws {
        let r = try shell(["6", "1", "l", "6", "1", "b", "q"])
        XCTAssertFalse(r.timedOut, r.out)
        XCTAssertTrue(r.out.contains("Notes go to the LLM"), r.out)
        XCTAssertTrue(r.out.contains("[on]"), "the menu shows the new state: \(r.out)")
        let edits = out.appendingPathComponent("meeting_20261107_124800.edits.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: edits.path))
    }

    func testLibraryRenameChangesTheTitleTheLibraryShows() throws {
        let r = try shell(["6", "1", "r", "Renamed from the shell", "6", "b", "q"])
        XCTAssertFalse(r.timedOut, r.out)
        XCTAssertTrue(r.out.contains("Renamed."), r.out)
        XCTAssertTrue(r.out.contains("Renamed from the shell"), "the library lists the new title: \(r.out)")
    }

    // M5.1 deep review #10 / security #1: a title from a file on disk can't send escape codes
    // to the terminal Library menus.
    func testALibraryTitleWithAnEscapeCodeNeverReachesTheTerminal() throws {
        let base = out.appendingPathComponent("meeting_20261107_124800")
        var e = ReportEdits()
        e.userTitle = "Bad\u{1B}[2J title"
        try e.save(to: ReportEdits.url(forBase: base))
        let r = try shell(["6", "1", "r", "b", "q"])
        XCTAssertFalse(r.timedOut, r.out)
        XCTAssertTrue(r.out.contains("Bad"), r.out)
        XCTAssertFalse(r.out.contains("\u{1B}"), "no ESC in the list, the entry menu or Now: line")
    }

    // M5.1 deep review #7: an editor that returns at once leaves the (empty) notes file.
    func testNotesFlowWithAnEditorThatExitsAtOnceLeavesTheEmptyNotesFile() throws {
        let script = world.root.appendingPathComponent("fake-editor.sh")
        try "#!/usr/bin/true\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let r = try shell(["6", "1", "n", "q"], env: ["EDITOR": script.path])
        XCTAssertFalse(r.timedOut, r.out)
        XCTAssertTrue(r.out.contains("Notes saved"), r.out)
        let notes = out.appendingPathComponent("meeting_20261107_124800.notes.md")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: notes.path), "the file stays for the editor that has it open")
    }

    // MARK: Settings › p Test CLI connection (M6 finding: picker keys; k was the picker up key)

    func testCLIConnectionTestPrintsOneLinePerCLIAndReturns() throws {
        let r = try shell(["5", "p", "b", "q"])
        XCTAssertFalse(r.timedOut, "Test CLI connection hung (semaphore around Task?):\n\(r.out)")
        XCTAssertEqual(r.status, 0, r.out)
        XCTAssertTrue(r.out.contains("Bye."), r.out)
        let results = resultLines(r.out)
        XCTAssertEqual(results.count, 2, r.out)
        XCTAssertTrue(results.contains { $0.contains("Claude") }, r.out)
        XCTAssertTrue(results.contains { $0.contains("Codex") }, r.out)
        XCTAssertTrue(results.allSatisfy { $0.hasPrefix("✓") }, "fakes are logged in: \(results)")
    }

    func testCLIConnectionTestReportsANotReadyCLIWithAReason() throws {
        // codex: not on PATH at all.
        try FileManager.default.removeItem(at: world.bin.appendingPathComponent("codex"))
        let r = try shell(["5", "p", "b", "q"])
        XCTAssertFalse(r.timedOut, r.out)
        let results = resultLines(r.out)
        XCTAssertEqual(results.count, 2, r.out)
        let codex = try XCTUnwrap(results.first { $0.contains("Codex") }, r.out)
        XCTAssertTrue(codex.hasPrefix("✗"), codex)
        XCTAssertGreaterThan(codex.count, "✗  Codex: ".count + 3, "a reason follows: \(codex)")
        XCTAssertTrue(try XCTUnwrap(results.first { $0.contains("Claude") }).hasPrefix("✓"))
    }

    func testCLIConnectionTestMakesNoModelCall() throws {
        _ = try shell(["5", "p", "b", "q"])
        XCTAssertEqual(world.calls(.claude).count, 0)
        XCTAssertEqual(world.calls(.codex).count, 0)
    }
}
