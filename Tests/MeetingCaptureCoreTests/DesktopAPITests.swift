import XCTest

@testable import MeetingCaptureCore

/// The desktop app's facade over the core: settings, names, PATH. Each test uses its own
/// temp folder and passes the config path explicitly, so the real config is never read.
final class DesktopAPITests: AudioTestCase {

    private var configURL: URL { url("config.json") }

    private func unrelatedNonDefaultConfig() -> Config {
        var c = Config()
        c.whisperLanguage = "zh"
        c.defaultDurationMinutes = 90
        c.autoTranscribe = false
        c.autoSummarize = false
        c.aecEnabled = false
        c.llmRoute = .apiProfile
        c.dailyCLICallCap = 77
        c.claudeModels = CLITierModels(cheap: "c-cheap", normal: "c-normal", frontier: "c-front")
        c.codexModels = CLITierModels(cheap: "x-cheap", normal: "x-normal", frontier: "x-front")
        c.allowCLIAPIBilling = true
        c.llmProfiles = [LLMProfile.defaultProfile()]
        c.selectedLLMProfileID = c.llmProfiles[0].id
        return c
    }

    // MARK: AppSettings

    func testSaveChangesOnlyTheAppFieldsAndKeepsEveryOtherConfigField() throws {
        let original = unrelatedNonDefaultConfig()
        try original.save(to: configURL)

        var s = AppSettings(Config.load(at: configURL, legacyURL: nil))
        s.outputDirectory = dir.appendingPathComponent("out").path
        s.audioRetentionDays = 7
        s.whisperModel = "openai_whisper-base.en"
        s.captureAllAudio = true
        s.enabledMeetingAppIDs = [MeetingApp.allIDs[0]]
        s.micEnabled = false
        s.primaryCLI = "codex"
        s.redactionEnabled = false
        try s.save(to: configURL)

        let saved = Config.load(at: configURL, legacyURL: nil)
        var expected = original
        expected.outputDirectory = s.outputDirectory
        expected.audioRetentionDays = 7
        expected.whisperModel = "openai_whisper-base.en"
        expected.captureAllAudio = true
        expected.enabledMeetingAppIDs = [MeetingApp.allIDs[0]]
        expected.micEnabled = false
        expected.primaryCLI = .codex
        expected.redactionEnabled = false
        XCTAssertEqual(saved, expected)
        // Spot checks, so a failure names the field.
        XCTAssertEqual(saved.whisperLanguage, "zh")
        XCTAssertEqual(saved.dailyCLICallCap, 77)
        XCTAssertEqual(saved.llmProfiles, original.llmProfiles)
        XCTAssertTrue(saved.allowCLIAPIBilling)
        XCTAssertFalse(saved.aecEnabled)
    }

    func testSavingUnchangedSettingsLeavesTheConfigEqual() throws {
        var original = unrelatedNonDefaultConfig()
        original.outputDirectory = dir.path
        try original.save(to: configURL)
        try AppSettings(Config.load(at: configURL, legacyURL: nil)).save(to: configURL)
        XCTAssertEqual(Config.load(at: configURL, legacyURL: nil), original)
    }

    func testInvalidRetentionIsRefusedAndNothingIsWritten() throws {
        try Config().save(to: configURL)
        let before = try Data(contentsOf: configURL)
        for days in [-1, 3651, 100_000] {
            var s = AppSettings(Config())
            s.audioRetentionDays = days
            XCTAssertThrowsError(try s.save(to: configURL), "days \(days)") {
                XCTAssertEqual($0 as? AppSettings.SettingsError, .badRetention)
            }
        }
        XCTAssertEqual(try Data(contentsOf: configURL), before)
    }

    func testRetentionEdgesAreAccepted() throws {
        for days in [0, 1, 3650] {
            var s = AppSettings(Config())
            s.audioRetentionDays = days
            XCTAssertNoThrow(try s.save(to: configURL), "days \(days)")
            XCTAssertEqual(Config.load(at: configURL, legacyURL: nil).audioRetentionDays, days)
        }
    }

    func testUnknownCLIAndBadModelNamesAreRefused() throws {
        var s = AppSettings(Config())
        s.primaryCLI = "gemini"
        XCTAssertThrowsError(try s.save(to: configURL)) {
            XCTAssertEqual($0 as? AppSettings.SettingsError, .badCLI)
        }
        for bad in [
            "", "../etc/passwd", "a/b", "a b", "..", ".hidden", "x;rm", "モデル", String(repeating: "a", count: 101),
        ] {
            var m = AppSettings(Config())
            m.whisperModel = bad
            XCTAssertThrowsError(try m.save(to: configURL), "model \(bad)") {
                XCTAssertEqual($0 as? AppSettings.SettingsError, .badModel)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path), "nothing is written on refusal")
    }

    func testUnknownMeetingAppIDsAreDroppedOnSave() throws {
        var s = AppSettings(Config())
        s.enabledMeetingAppIDs = [MeetingApp.allIDs[0], "not-an-app"]
        try s.save(to: configURL)
        XCTAssertEqual(Config.load(at: configURL, legacyURL: nil).enabledMeetingAppIDs, [MeetingApp.allIDs[0]])
    }

    func testResolvedOutputDirectoryMakesAnAbsoluteFolder() {
        var s = AppSettings(Config())
        s.outputDirectory = url("made/here").path
        XCTAssertEqual(s.resolvedOutputDirectory.path, url("made/here").path)
        XCTAssertTrue(exists("made/here"))
    }

    // MARK: WhisperModelCatalog

    func testEveryListedModelIsValidAndFindable() {
        XCTAssertFalse(WhisperModelCatalog.models.isEmpty)
        for m in WhisperModelCatalog.models {
            XCTAssertTrue(WhisperModelCatalog.isValidID(m.id), m.id)
            XCTAssertEqual(WhisperModelCatalog.choice(for: m.id), m)
        }
        XCTAssertEqual(Set(WhisperModelCatalog.models.map(\.id)).count, WhisperModelCatalog.models.count)
        XCTAssertTrue(WhisperModelCatalog.isValidID(Config().whisperModel), "the default must be valid")
    }

    func testCustomModelIdsOfPlainCharactersPassAndOthersDont() {
        XCTAssertTrue(WhisperModelCatalog.isValidID("distil-whisper_large-v3.en"))
        XCTAssertNil(WhisperModelCatalog.choice(for: "distil-whisper_large-v3.en"))
        XCTAssertFalse(WhisperModelCatalog.isValidID(""))
        XCTAssertFalse(WhisperModelCatalog.isValidID("a..b"))
        XCTAssertFalse(WhisperModelCatalog.isValidID("a\nb"))
        XCTAssertFalse(WhisperModelCatalog.isValidID("a\0b"))
    }

    // MARK: RecordingName

    func testTitleLongAndShortForTheTimestampName() {
        let base = URL(fileURLWithPath: "/x/meeting_20261107_124800")
        let en = Locale(identifier: "en_US")
        let long = RecordingName.title(for: base, locale: en)
        XCTAssertTrue(long.hasPrefix("Recording, "), long)
        XCTAssertTrue(long.contains("Nov 7, 2026"), long)
        XCTAssertTrue(long.contains("12:48"), long)
        XCTAssertEqual(RecordingName.title(for: base, short: true, locale: en), "Recording, Nov 7")
        let gb = Locale(identifier: "en_GB")
        XCTAssertEqual(RecordingName.title(for: base, short: true, locale: gb), "Recording, 7 Nov")
        XCTAssertTrue(RecordingName.title(for: base, locale: gb).contains("7 Nov 2026"))
    }

    func testTitleOfANameThatDoesntParseIsTheNameItself() {
        for name in ["notes", "meeting_garbage", "meeting_2026110", "meeting_20261307_124800"] {
            let base = URL(fileURLWithPath: "/x/\(name)")
            XCTAssertEqual(RecordingName.title(for: base, locale: Locale(identifier: "en_US")), name, name)
            XCTAssertEqual(RecordingName.title(for: base, short: true, locale: Locale(identifier: "en_US")), name)
        }
    }

    /// Finding: an empty stamp ("meeting_") was parsed as 2000-01-01; a stamp shorter than
    /// 15 characters now returns the name itself.
    func testTitleOfAnEmptyOrShortStampIsTheNameItself() {
        let en = Locale(identifier: "en_US")
        for name in ["meeting_", "meeting_2026", "meeting_20261107", "meeting_20261107_1248"] {
            let base = URL(fileURLWithPath: "/x/\(name)")
            XCTAssertEqual(RecordingName.title(for: base, locale: en), name, name)
            XCTAssertEqual(RecordingName.title(for: base, short: true, locale: en), name, name)
        }
    }

    func testTitleOfAPartNameStillReadsTheTimestamp() {
        let base = URL(fileURLWithPath: "/x/meeting_20261107_124800_part2")
        XCTAssertTrue(
            RecordingName.title(for: base, short: true, locale: Locale(identifier: "en_US")).hasPrefix("Recording, "))
    }

    // MARK: LaunchEnvironment

    func testExtendedPATHAddsOnlyFoldersThatExistAfterWhatIsThere() throws {
        let home = url("home")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".bun/bin"), withIntermediateDirectories: true)
        // A file, not a folder, where a folder is expected.
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".npm-global"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: home.appendingPathComponent(".npm-global/bin").path, contents: Data())

        let result = LaunchEnvironment.extendedPATH(current: "/usr/bin:/bin", home: home.path)
        let parts = result.split(separator: ":").map(String.init)
        XCTAssertEqual(Array(parts.prefix(2)), ["/usr/bin", "/bin"])
        XCTAssertTrue(parts.contains(home.path + "/.local/bin"))
        XCTAssertTrue(parts.contains(home.path + "/.bun/bin"))
        XCTAssertFalse(parts.contains(home.path + "/.npm-global/bin"), "a file is not a tool folder")
        XCTAssertFalse(parts.contains(home.path + "/.claude/local"), "missing folders are not added")
        XCTAssertEqual(Set(parts).count, parts.count, "no duplicates: \(result)")
    }

    func testExtendedPATHKeepsExistingOrderAndDoesNotDuplicate() throws {
        let home = url("home2")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
        let local = home.path + "/.local/bin"
        let current = "\(local):/usr/bin:/bin"
        XCTAssertEqual(
            LaunchEnvironment.extendedPATH(current: current, home: home.path)
                .split(separator: ":").filter { $0 == Substring(local) }.count, 1)
        XCTAssertTrue(LaunchEnvironment.extendedPATH(current: current, home: home.path).hasPrefix(current))
        // Twice gives the same answer.
        let once = LaunchEnvironment.extendedPATH(current: current, home: home.path)
        XCTAssertEqual(LaunchEnvironment.extendedPATH(current: once, home: home.path), once)
    }

    func testExtendedPATHWithAnEmptyPathAndNoFolders() {
        let result = LaunchEnvironment.extendedPATH(current: "", home: url("nohome").path)
        for part in result.split(separator: ":") {
            XCTAssertTrue(["/opt/homebrew/bin", "/usr/local/bin"].contains(String(part)), result)
        }
    }

    // MARK: SummaryService (no model, no config read beyond usage text)

    func testCLIChoicesAreClaudeAndCodex() {
        XCTAssertEqual(Set(SummaryService.cliChoices.map(\.id)), ["claude", "codex"])
        XCTAssertEqual(SummaryService.usageLine(cli: "nonsense"), "")
    }
}
