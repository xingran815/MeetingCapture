import XCTest

@testable import MeetingCaptureCore

/// Tests that came from the M5 review's findings, each named after its finding.
final class M5ReviewFindingTests: AudioTestCase {

    private let transcript = "[00:00:01] Speaker 1: a\n[00:00:02] Speaker 2: b\n"

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: url(name), atomically: true, encoding: .utf8)
    }

    private func entry(_ base: String, busy: Set<String> = []) -> LibraryEntry? {
        Library.entries(in: dir, busy: busy).first { $0.base.lastPathComponent == base }
    }

    // MARK: Finding 2: a recording this process left in the recording state

    func testFinding2OwnPidWithAWAVIsUnfinishedUnlessBusy() throws {
        var s = RecordingSidecar(createdAt: now, state: .recording)
        s.pid = getpid()
        try saveSidecar("meeting_own", s)
        try wav("meeting_own.wav")

        let listed = try XCTUnwrap(entry("meeting_own"))
        XCTAssertTrue(listed.isUnfinished)
        XCTAssertEqual(listed.audioFiles.map(\.lastPathComponent), ["meeting_own.wav"])

        // Still being recorded or processed by this process: sidecar-only rule leaves it out.
        XCTAssertNil(entry("meeting_own", busy: ["meeting_own"]))
        XCTAssertTrue(exists("meeting_own.mcmeta.json"), "listing never deletes")
    }

    func testFinding2BusyOnlyHidesThatBase() throws {
        for n in ["meeting_a", "meeting_b"] {
            var s = RecordingSidecar(createdAt: now, state: .recording)
            s.pid = getpid()
            try saveSidecar(n, s)
            try wav(n + ".wav")
        }
        let names = Library.entries(in: dir, busy: ["meeting_a"]).map { $0.base.lastPathComponent }
        XCTAssertEqual(names, ["meeting_b"])
    }

    func testFinding2AnotherLiveProcesssRecordingIsStillNotUnfinished() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["60"]
        try sleeper.run()
        defer {
            sleeper.terminate()
            sleeper.waitUntilExit()
        }
        var s = RecordingSidecar(createdAt: now, state: .recording)
        s.pid = sleeper.processIdentifier
        try saveSidecar("meeting_other", s)
        try wav("meeting_other.wav")
        XCTAssertNil(entry("meeting_other"), "no audio listed, not unfinished: sidecar-only, left out")

        // With the process gone it is unfinished again.
        sleeper.terminate()
        sleeper.waitUntilExit()
        XCTAssertTrue(try XCTUnwrap(entry("meeting_other")).isUnfinished)
    }

    // MARK: Finding 4: save only what the app changed

    private var configURL: URL { url("config.json") }

    func testFinding4OnlyChangedFieldsAreWrittenOverWhatTheTerminalChanged() throws {
        try Config().save(to: configURL)
        let a = AppSettings(Config.load(at: configURL, legacyURL: nil))

        // The terminal changes two other fields meanwhile.
        var outside = Config.load(at: configURL, legacyURL: nil)
        outside.outputDirectory = url("terminal-folder").path
        outside.whisperModel = "openai_whisper-base.en"
        try outside.save(to: configURL)

        var b = a
        b.redactionEnabled.toggle()
        try b.save(to: configURL, changedFrom: a)

        let disk = Config.load(at: configURL, legacyURL: nil)
        XCTAssertEqual(disk.outputDirectory, url("terminal-folder").path, "terminal's folder kept")
        XCTAssertEqual(disk.whisperModel, "openai_whisper-base.en", "terminal's model kept")
        XCTAssertEqual(disk.redactionEnabled, b.redactionEnabled)
    }

    func testFinding4SavingUnchangedSettingsWritesNothing() throws {
        try Config().save(to: configURL)
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: configURL.path)
        let before = try Data(contentsOf: configURL)
        let a = AppSettings(Config.load(at: configURL, legacyURL: nil))
        try a.save(to: configURL, changedFrom: a)
        XCTAssertEqual(try Data(contentsOf: configURL), before)
        let mtime = try FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate] as? Date
        XCTAssertEqual(mtime, old)
    }

    func testFinding4AChangedFieldStillValidates() throws {
        try Config().save(to: configURL)
        let a = AppSettings(Config.load(at: configURL, legacyURL: nil))
        var b = a
        b.audioRetentionDays = 99_999
        XCTAssertThrowsError(try b.save(to: configURL, changedFrom: a)) {
            XCTAssertEqual($0 as? AppSettings.SettingsError, .badRetention)
        }
        var c = a
        c.whisperModel = "../x"
        XCTAssertThrowsError(try c.save(to: configURL, changedFrom: a)) {
            XCTAssertEqual($0 as? AppSettings.SettingsError, .badModel)
        }
    }

    // MARK: Finding 5: a swap of speaker names

    func testFinding5RenameWithAMappingSwapsInsteadOfChaining() {
        let out = SpeakerLabels.rename(["Speaker 1": "Speaker 2", "Speaker 2": "Speaker 1"], in: transcript)
        XCTAssertEqual(out, "[00:00:01] Speaker 2: a\n[00:00:02] Speaker 1: b\n")
        // a to b and b to c: a becomes b, not c.
        XCTAssertEqual(
            SpeakerLabels.rename(["Speaker 1": "Speaker 2", "Speaker 2": "Ana"], in: transcript),
            "[00:00:01] Speaker 2: a\n[00:00:02] Ana: b\n")
        // Words and similar labels are left alone; names are literal.
        let tricky = "[00:00:01] Speaker 1: Speaker 2: said\n[00:00:02] Speaker 1 (part 2): x\n"
        XCTAssertEqual(
            SpeakerLabels.rename(["Speaker 1": "$1", "Speaker 2": "Z"], in: tricky),
            "[00:00:01] $1: Speaker 2: said\n[00:00:02] Speaker 1 (part 2): x\n")
        XCTAssertEqual(SpeakerLabels.rename([:], in: transcript), transcript)
    }

    func testFinding5ApplySpeakerNamesSwapsAndRecordsBothInTheSidecar() throws {
        try saveSidecar("meeting_s", transcribed(ageDays: 1, files: ["meeting_s.m4a"]))
        try touch("meeting_s.m4a")
        try write("meeting_s.txt", transcript)
        let e = try XCTUnwrap(entry("meeting_s"))
        XCTAssertTrue(try e.applySpeakerNames(["Speaker 1": "Speaker 2", "Speaker 2": "Speaker 1"]))
        XCTAssertEqual(
            try String(contentsOf: url("meeting_s.txt"), encoding: .utf8),
            "[00:00:01] Speaker 2: a\n[00:00:02] Speaker 1: b\n")
        XCTAssertEqual(
            loadSidecar("meeting_s")?.speakerNames, ["Speaker 1": "Speaker 2", "Speaker 2": "Speaker 1"])
    }

    func testFinding5OneInvalidNameChangesNothingAtAll() throws {
        try saveSidecar("meeting_i", transcribed(ageDays: 1, files: ["meeting_i.m4a"]))
        try touch("meeting_i.m4a")
        try write("meeting_i.txt", transcript)
        let textBefore = try Data(contentsOf: url("meeting_i.txt"))
        let sidecarBefore = try Data(contentsOf: url("meeting_i.mcmeta.json"))
        let e = try XCTUnwrap(entry("meeting_i"))
        for bad in ["", "   ", "A: B"] {
            XCTAssertFalse(try e.applySpeakerNames(["Speaker 1": "Ana", "Speaker 2": bad]), bad)
            XCTAssertFalse(try e.applySpeakerNames(["Speaker 2": bad, "Speaker 1": "Ana"]), bad)
        }
        XCTAssertEqual(try Data(contentsOf: url("meeting_i.txt")), textBefore)
        XCTAssertEqual(try Data(contentsOf: url("meeting_i.mcmeta.json")), sidecarBefore)
    }

    func testFinding5AnUnchangedMappingWritesNothing() throws {
        try saveSidecar("meeting_u", transcribed(ageDays: 1, files: ["meeting_u.m4a"]))
        try touch("meeting_u.m4a")
        try write("meeting_u.txt", transcript)
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        for f in ["meeting_u.txt", "meeting_u.mcmeta.json"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url(f).path)
        }
        let e = try XCTUnwrap(entry("meeting_u"))
        XCTAssertTrue(try e.applySpeakerNames(["Speaker 1": "Speaker 1", "Speaker 2": " Speaker 2 "]))
        XCTAssertTrue(try e.applySpeakerNames([:]))
        for f in ["meeting_u.txt", "meeting_u.mcmeta.json"] {
            let m = try FileManager.default.attributesOfItem(atPath: url(f).path)[.modificationDate] as? Date
            XCTAssertEqual(m, old, f)
        }
    }

    // MARK: Finding 8: the stages a progress list shows

    func testFinding8PlannedStagesFollowTheAutoSettings() {
        func stages(transcribe: Bool, summarize: Bool) -> [ProcessingStage] {
            var c = Config()
            c.autoTranscribe = transcribe
            c.autoSummarize = summarize
            return MeetingProcessor(config: c).plannedStages
        }
        let transcription: [ProcessingStage] = [.removingEcho, .transcribing, .labellingSpeakers]
        XCTAssertEqual(stages(transcribe: true, summarize: true), transcription + [.savingAudio, .writingReport])
        XCTAssertEqual(stages(transcribe: true, summarize: false), transcription + [.savingAudio])
        // No transcript means no report, whatever auto-summarize says.
        XCTAssertEqual(stages(transcribe: false, summarize: true), [.savingAudio])
        XCTAssertEqual(stages(transcribe: false, summarize: false), [.savingAudio])
    }

    // MARK: Finding 9: kept-audio lines travel in the transcript notes

    func testFinding9KeptWAVLinesGoInTheTranscriptNotes() async throws {
        let part = try wav("m.wav")
        let pipeline = RecordingPipeline(transcriber: ScriptedTranscriber(text: "invented words"), detector: nil)
        let kept = try await RecordingPipeline.finish(
            parts: [part], base: url("m"), pipeline: pipeline, encoder: FailingEncoder(), now: now)
        let result = try XCTUnwrap(kept)
        XCTAssertTrue(result.notes.contains { $0.hasPrefix("Kept m.wav") }, "\(result.notes)")

        let good = try wav("n.wav")
        let fine = try await RecordingPipeline.finish(
            parts: [good], base: url("n"), pipeline: pipeline, now: now)
        XCTAssertFalse(try XCTUnwrap(fine).notes.contains { $0.hasPrefix("Kept") }, "\(fine?.notes ?? [])")
    }
}

/// Steps arrive in order, with the fake backend of ReportPipelineTests.
final class ReportStepTests: XCTestCase {

    private final class Steps {
        var seen: [ReportStep] = []
    }

    private func steps(_ scenario: String, review: Bool = true) async throws -> [ReportStep] {
        let box = Steps()
        var p = ReportFixtures.pipeline(try ScriptedBackend.fixture(scenario))
        p.review = review
        p.onStep = { box.seen.append($0) }
        _ = try await p.run(transcript: try ReportFixtures.read(scenario, "transcript.txt"))
        return box.seen
    }

    func testStepsWithoutConceptsSkipLookingUp() async throws {
        let seen = try await steps("meeting")
        XCTAssertEqual(seen, [.choosingType, .writingSections, .reviewing, .finishing])
    }

    func testStepsWithConceptsIncludeLookingUpBetweenSectionsAndReview() async throws {
        for scenario in ["therapy", "lecture"] {
            let seen = try await steps(scenario)
            XCTAssertEqual(
                seen, [.choosingType, .writingSections, .lookingUpConcepts, .reviewing, .finishing], scenario)
        }
    }

    func testStepsWithReviewOffHaveNoReviewing() async throws {
        let seen = try await steps("therapy", review: false)
        XCTAssertEqual(seen, [.choosingType, .writingSections, .lookingUpConcepts, .finishing])
        let meeting = try await steps("meeting", review: false)
        XCTAssertFalse(meeting.contains(.reviewing))
    }

    func testFractionRisesFromZeroAndStaysBelowOne() {
        XCTAssertEqual(ReportStep.choosingType.fraction, 0)
        let fractions = ReportStep.allCases.map(\.fraction)
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertEqual(Set(fractions).count, fractions.count, "strictly rising")
        XCTAssertTrue(fractions.allSatisfy { $0 >= 0 && $0 < 1 })
        XCTAssertTrue(ReportStep.allCases.allSatisfy { !$0.title.isEmpty })
    }
}

/// The processor's report path with fake CLIs on PATH and a temp home. No model, no network.
final class MeetingProcessorReportTests: XCTestCase {

    private var world: FakeCLIWorld!
    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        world = try FakeCLIWorld()
        folder = world.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try world.installFixture("meeting")
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        world.cleanUp()
        super.tearDown()
    }

    private func inFakeWorld<T>(_ body: () async throws -> T) async rethrows -> T {
        try await withEnvironment("PATH", world.bin.path + ":/usr/bin:/bin") {
            try await withEnvironment("MEETINGCAPTURE_E2E", "1") {
                try await withEnvironment("MEETINGCAPTURE_HOME", world.root.path) {
                    try await withEnvironment("MEETINGCAPTURE_CLI_ONLY", "1") { try await body() }
                }
            }
        }
    }

    private func transcriptFile() throws -> URL {
        let t = folder.appendingPathComponent("m.txt")
        try ReportFixtures.read("meeting", "transcript.txt").write(to: t, atomically: true, encoding: .utf8)
        return t
    }

    func testFinding6TheReportIsKeptWhenWritingItsFilesFails() async throws {
        let t = try transcriptFile()
        // The folder can be read but not written, so the files can't be made.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let processor = MeetingProcessor(config: Config())
        let result = await inFakeWorld { await processor.summarize(transcriptAt: t) }
        XCTAssertGreaterThan(world.calls(.claude).count, 0, "the fake CLI answered")
        XCTAssertNotNil(result.failure, "writing failed")
        XCTAssertEqual(result.failedStage, .writingReport)
        XCTAssertNotNil(processor.lastReport, "the report the calls paid for is kept")
        XCTAssertNil(result.reportHTML)
    }

    func testAGoodRunSetsTheReportAndNoFailure() async throws {
        let t = try transcriptFile()
        let processor = MeetingProcessor(config: Config())
        var events: [String] = []
        let result = await inFakeWorld {
            await processor.summarize(transcriptAt: t) { event in
                if case .reportBackend(let label) = event { events.append(label) }
            }
        }
        XCTAssertNil(result.failure)
        XCTAssertNotNil(processor.lastReport)
        XCTAssertNotNil(result.reportHTML)
        XCTAssertEqual(events.count, 1, "the backend label is announced once")
    }
}
