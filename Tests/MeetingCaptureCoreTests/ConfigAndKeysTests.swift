import XCTest

@testable import MeetingCaptureCore

/// Config and keys, always at temp paths. The real ~/.config is never read or written.
final class ConfigAndKeysTests: XCTestCase {

    private var dir: URL!
    private var configURL: URL { dir.appendingPathComponent("config.json") }
    private var legacyURL: URL { dir.appendingPathComponent("old/config.json") }
    private var keysURL: URL { dir.appendingPathComponent("sub/keys.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        APIKeyStore.pathOverride = keysURL
    }

    override func tearDownWithError() throws {
        APIKeyStore.pathOverride = nil
        try FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    // MARK: Old locations and shapes

    func testALegacyFileMovesForwardAndTheOriginalStays() throws {
        try write(#"{"whisperModel":"tiny","llmProfiles":[]}"#, to: legacyURL)
        let config = Config.load(at: configURL, legacyURL: legacyURL)
        XCTAssertEqual(config.whisperModel, "tiny")
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path), "it moved forward")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path), "and non-destructively")
    }

    func testTheNewFileWinsOverALegacyOne() throws {
        try write(#"{"whisperModel":"old"}"#, to: legacyURL)
        try write(#"{"whisperModel":"new"}"#, to: configURL)
        XCTAssertEqual(Config.load(at: configURL, legacyURL: legacyURL).whisperModel, "new")
    }

    func testACorruptLegacyFileGivesDefaultsAndIsLeftAlone() throws {
        try write("{ nope", to: legacyURL)
        // Unlike an unreadable current config, a legacy one predates retention, so it holds no choice to keep.
        XCTAssertEqual(Config.load(at: configURL, legacyURL: legacyURL), Config())
        XCTAssertEqual(try String(contentsOf: legacyURL, encoding: .utf8), "{ nope")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
    }

    func testAFlatConfigIsRewrittenToProfilesOnFirstLoad() throws {
        try write(
            #"{"llmProviderID":"openai","llmModel":"gpt-x","llmBaseURL":"https://api.openai.com/v1"}"#, to: configURL)
        let config = Config.load(at: configURL, legacyURL: nil)
        XCTAssertEqual(config.llmProfiles.map(\.id), [Config.migratedLegacyProfileID])
        XCTAssertEqual(config.selectedLLMProfileID, Config.migratedLegacyProfileID)
        XCTAssertEqual(config.llmProfiles[0].name, "OpenAI")
        let onDisk = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("llmProfiles"))
        XCTAssertFalse(onDisk.contains("llmProviderID"), "old keys must not be written back")
        XCTAssertEqual(Config.load(at: configURL, legacyURL: nil), config, "the rewrite loads the same")
    }

    func testOldReasoningKeysBecomeTheNearestEffort() throws {
        try write(
            #"{"llmProviderID":"custom","llmModel":"m","llmBaseURL":"https://x.example.com","kimiThinkingEnabled":true,"kimiThinkingBudgetTokens":8000}"#,
            to: configURL)
        XCTAssertEqual(Config.load(at: configURL, legacyURL: nil).llmProfiles.first?.reasoningEffort, .low)
        XCTAssertEqual(LLMProfile.effort(fromLegacyEnabled: false, budget: 32_000), .off)
        XCTAssertEqual(LLMProfile.effort(fromLegacyEnabled: true, budget: 11_999), .low)
        XCTAssertEqual(LLMProfile.effort(fromLegacyEnabled: true, budget: 12_000), .medium)
        XCTAssertEqual(LLMProfile.effort(fromLegacyEnabled: true, budget: 24_000), .high)
    }

    func testAnOldProfileWithReasoningKeysReadsWithoutEffort() throws {
        try write(
            #"{"llmProfiles":[{"id":"a","name":"n","providerID":"custom","model":"m","baseURL":"https://x.example.com","reasoningEnabled":true,"reasoningBudgetTokens":16000}]}"#,
            to: configURL)
        XCTAssertEqual(Config.load(at: configURL, legacyURL: nil).llmProfiles.first?.reasoningEffort, .medium)
    }

    func testAnUnknownReasoningFormatMeansNone() throws {
        let data = Data(#"["from-the-future"]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([ReasoningStyle].self, from: data), [ReasoningStyle.none])
    }

    func testRemovingAnUnselectedQianfanProfileKeepsTheSelection() throws {
        let qianfan =
            #"{"id":"q","name":"q","providerID":"custom","model":"m","baseURL":"https://QIANFAN.BAIDUBCE.COM/v2","reasoningEffort":"off"}"#
        let other =
            #"{"id":"a","name":"a","providerID":"openai","model":"m","baseURL":"https://api.openai.com/v1","reasoningEffort":"off"}"#
        let another =
            #"{"id":"b","name":"b","providerID":"openai","model":"m","baseURL":"https://api.openai.com/v1","reasoningEffort":"off"}"#
        try write(#"{"llmProfiles":[\#(qianfan),\#(other),\#(another)],"selectedLLMProfileID":"b"}"#, to: configURL)
        let config = Config.load(at: configURL, legacyURL: nil)
        XCTAssertEqual(config.llmProfiles.map(\.id), ["a", "b"])
        XCTAssertEqual(config.selectedLLMProfileID, "b")
    }

    func testAStaleSelectionFallsBackToTheFirstProfile() {
        let a = LLMProfile(id: "a", name: "a", providerID: "openai", model: "m", baseURL: "")
        let config = Config(llmProfiles: [a], selectedLLMProfileID: "gone")
        XCTAssertEqual(config.activeLLMProfile.id, "a")
    }

    func testAnEmptyProfileListStandsInWithAProfileThatHasNoKey() {
        let stand = Config().activeLLMProfile
        XCTAssertFalse(APIKeyStore.isStored(profileID: stand.id))
    }

    // MARK: Saving and not saving

    func testACleanFileIsNotRewrittenOnLoad() throws {
        let text = #"{ "llmProfiles" : [], "whisperModel" : "tiny", "somethingNew" : 1 }"#
        try write(text, to: configURL)
        _ = Config.load(at: configURL, legacyURL: nil)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), text, "the user's file stays theirs")
    }

    func testAFieldOfTheWrongTypeCountsAsCorruptIsNotOverwrittenAndKeepsEverything() throws {
        let text = #"{"audioRetentionDays":"thirty"}"#
        try write(text, to: configURL)
        var expected = Config()
        expected.audioRetentionDays = 0  // D-52
        XCTAssertEqual(Config.load(at: configURL, legacyURL: nil), expected)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), text)
    }

    /// Retention runs at launch from whatever load returns. A user who chose 0 (keep
    /// forever) and then mistyped something else in the file must not get real deletion.
    func testAnUnreadableConfigDoesntTurnRetentionOn() throws {
        try write(#"{"audioRetentionDays":0,"defaultDurationMinutes":"sixty"}"#, to: configURL)
        XCTAssertEqual(
            Config.load(at: configURL, legacyURL: nil).audioRetentionDays, 0,
            "unsure what the user chose, so nothing should be deleted")
    }

    /// D-52: in range is kept as it is, and out of range means keep forever (0), not the default.
    func testRetentionBoundsAreKeptAndAnythingOutOfRangeMeansForever() throws {
        for (saved, expected) in [(0, 0), (1, 1), (3650, 3650), (-1, 0), (3651, 0), (Int.max, 0), (Int.min, 0)] {
            let config = try JSONDecoder().decode(
                Config.self, from: Data(#"{"audioRetentionDays":\#(saved)}"#.utf8))
            XCTAssertEqual(config.audioRetentionDays, expected, "\(saved)")
        }
    }

    func testEverySettingSurvivesASaveAndLoad() throws {
        var config = Config(whisperModel: "m", whisperLanguage: "zh", outputDirectory: dir.path, captureAllAudio: true)
        config.llmRoute = .apiProfile
        config.primaryCLI = .codex
        config.dailyCLICallCap = 7
        config.allowCLIAPIBilling = true
        config.redactionEnabled = false
        config.audioRetentionDays = 0
        config.claudeModels = CLITierModels(cheap: "a", normal: "b", frontier: "c")
        try config.save(to: configURL)
        XCTAssertEqual(Config.load(at: configURL, legacyURL: nil), config)
    }

    func testAMeetingNameUsesTheConfiguredFolderAndTheTime() throws {
        let config = Config(outputDirectory: dir.appendingPathComponent("new/folder").path)
        let base = try config.newMeetingBase(timestamp: Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(base.deletingLastPathComponent().lastPathComponent, "folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.deletingLastPathComponent().path))
        XCTAssertNotNil(base.lastPathComponent.range(of: #"^meeting_\d{8}_\d{6}$"#, options: .regularExpression))
    }

    // MARK: Keys

    func testAKeyFileIsOwnerOnlyAfterEveryKindOfWrite() throws {
        XCTAssertTrue(APIKeyStore.write("fake-one", forProfile: "a"))
        XCTAssertEqual(try mode(keysURL), 0o600)
        XCTAssertTrue(APIKeyStore.write("fake-two", forProfile: "a"))
        XCTAssertEqual(try mode(keysURL), 0o600, "replacing a key writes a new file")
        XCTAssertTrue(APIKeyStore.write("fake-three", forProfile: "b"))
        XCTAssertTrue(APIKeyStore.delete(profileID: "b"))
        XCTAssertEqual(try mode(keysURL), 0o600)
    }

    func testAKeyFileLeftOpenIsTightenedOnTheNextWrite() throws {
        XCTAssertTrue(APIKeyStore.write("fake-one", forProfile: "a"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keysURL.path)
        XCTAssertTrue(APIKeyStore.write("fake-two", forProfile: "a"))
        XCTAssertEqual(try mode(keysURL), 0o600)
    }

    func testKeysAreKeptPerProfileAndDeleteTakesOnlyOne() {
        APIKeyStore.write("fake-a", forProfile: "a")
        APIKeyStore.write("fake-b", forProfile: "b")
        XCTAssertEqual(APIKeyStore.read(profileID: "a"), "fake-a")
        XCTAssertTrue(APIKeyStore.delete(profileID: "a"))
        XCTAssertNil(APIKeyStore.read(profileID: "a"))
        XCTAssertEqual(APIKeyStore.read(profileID: "b"), "fake-b")
        XCTAssertTrue(APIKeyStore.delete(profileID: "never-existed"))
    }

    func testAPastedKeyIsTrimmedAndABlankOneCountsAsNone() {
        APIKeyStore.write("  fake-key\n", forProfile: "a")
        XCTAssertEqual(APIKeyStore.read(profileID: "a"), "fake-key")
        APIKeyStore.write("  \n", forProfile: "b")
        XCTAssertNil(APIKeyStore.read(profileID: "b"))
        XCTAssertFalse(APIKeyStore.isStored(profileID: "b"))
    }

    /// `config.json` is meant to be safe to share, and the keys file isn't.
    func testAKeyNeverReachesConfigJSON() throws {
        let profile = LLMProfile(id: "a", name: "n", providerID: "openai", model: "m", baseURL: "https://x.example.com")
        APIKeyStore.write("fake-secret-value", forProfile: "a")
        try Config(llmProfiles: [profile], selectedLLMProfileID: "a").save(to: configURL)
        XCTAssertFalse(try String(contentsOf: configURL, encoding: .utf8).contains("fake-secret-value"))
    }

    /// `Config.load` keeps a corrupt config for a person to fix. A save of any one key
    /// must not replace an unreadable key file, or every other key in it is gone for good.
    func testACorruptKeyFileIsNotOverwritten() throws {
        try write("{ fake-a: broken", to: keysURL)
        APIKeyStore.write("fake-b", forProfile: "b")
        XCTAssertTrue(
            try String(contentsOf: keysURL, encoding: .utf8).contains("fake-a"), "the old keys may still be recoverable"
        )
    }

    /// Each replace writes a private file and moves it into place. None may be left over.
    func testNoTemporaryFileStaysBehindAfterWritesReplacesAndDeletes() throws {
        for i in 0..<5 { XCTAssertTrue(APIKeyStore.write("fake-\(i)", forProfile: "a")) }
        XCTAssertTrue(APIKeyStore.write("fake-b", forProfile: "b"))
        XCTAssertTrue(APIKeyStore.delete(profileID: "a"))
        XCTAssertTrue(APIKeyStore.delete(profileID: "a"), "deleting what isn't there is fine")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: keysURL.deletingLastPathComponent().path), ["keys.json"]
        )
        XCTAssertEqual(try mode(keysURL), 0o600)
    }

    func testAWriteThatCantBeMadeLeavesNothingBehind() throws {
        let folder = keysURL.deletingLastPathComponent()
        XCTAssertTrue(APIKeyStore.write("fake-a", forProfile: "a"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        try XCTSkipIf(access(folder.path, W_OK) == 0, "this user can write anywhere")
        XCTAssertFalse(APIKeyStore.write("fake-b", forProfile: "b"))
        XCTAssertEqual(APIKeyStore.read(profileID: "a"), "fake-a", "the old file is untouched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["keys.json"])
    }

    func testDeleteRefusesAnUnreadableKeyFileAndLeavesItAlone() throws {
        let broken = "{ fake-a: broken"
        try write(broken, to: keysURL)
        XCTAssertFalse(APIKeyStore.delete(profileID: "a"))
        XCTAssertFalse(APIKeyStore.delete(profileID: "never-existed"), "it can't know the key isn't in there")
        XCTAssertEqual(try String(contentsOf: keysURL, encoding: .utf8), broken)
    }

    func testAnUnreadableKeyFileReadsAsNoKeyAndNeverCrashes() throws {
        let junk: [Data] = [
            Data("{ not json".utf8), Data(), Data([0xFF, 0xFE, 0x00, 0x01]), Data("[]".utf8), Data("null".utf8),
            Data(#"{"a":1}"#.utf8), Data(#"{"a":["x"]}"#.utf8), Data(#"{"a":null}"#.utf8),
        ]
        try FileManager.default.createDirectory(
            at: keysURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        for data in junk {
            try data.write(to: keysURL)
            XCTAssertNil(APIKeyStore.read(profileID: "a"), String(decoding: data, as: UTF8.self))
            XCTAssertFalse(APIKeyStore.isStored(profileID: "a"))
            XCTAssertFalse(APIKeyStore.write("fake", forProfile: "a"), "an unreadable file is never replaced")
            XCTAssertEqual(try Data(contentsOf: keysURL), data)
        }
    }

    func testAKeyFilePathThatIsAFolderReadsAsNoKeyAndIsNotReplaced() throws {
        try FileManager.default.createDirectory(at: keysURL, withIntermediateDirectories: true)
        XCTAssertNil(APIKeyStore.read(profileID: "a"))
        XCTAssertFalse(APIKeyStore.write("fake", forProfile: "a"))
        XCTAssertFalse(APIKeyStore.delete(profileID: "a"))
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: keysURL.path, isDirectory: &isFolder))
        XCTAssertTrue(isFolder.boolValue)
    }

    func testAKeyStoreThatCantBeWrittenSaysSo() throws {
        try Data().write(to: dir.appendingPathComponent("blocker"))
        APIKeyStore.pathOverride = dir.appendingPathComponent("blocker/keys.json")
        XCTAssertFalse(APIKeyStore.write("fake", forProfile: "a"))
    }

    func testAFlagBeatsTheEnvironmentAndTheEnvironmentBeatsTheStore() async throws {
        APIKeyStore.write("fake-stored", forProfile: "a")
        await withEnvironment("LLM_API_KEY", "fake-env") {
            XCTAssertEqual(Config.resolveApiKey(profileID: "a", flag: "fake-flag"), "fake-flag")
            XCTAssertEqual(Config.resolveApiKey(profileID: "a"), "fake-env")
            XCTAssertEqual(Config.apiKeySource(profileID: "a"), "set via LLM_API_KEY")
        }
        await withEnvironment("LLM_API_KEY", nil) {
            XCTAssertEqual(Config.resolveApiKey(profileID: "a", flag: ""), "fake-stored", "an empty flag isn't a key")
            XCTAssertEqual(Config.resolveApiKey(profileID: "a"), "fake-stored")
            XCTAssertNil(Config.resolveApiKey(profileID: "other"))
            XCTAssertEqual(Config.apiKeySource(profileID: "other"), "not set")
        }
    }

    // MARK: Command line

    func testAnOptionTakesTheValueAfterItsFirstUse() {
        let args = CommandLineArguments(raw: ["--model", "a", "--model", "b"])
        XCTAssertEqual(args.option("--model"), "a")
        XCTAssertFalse(args.flag("--mode"), "a flag matches whole")
    }
}
