import XCTest

@testable import MeetingCaptureCore

final class ConfigMigrationTests: XCTestCase {

    private var dir: URL!
    private var configURL: URL { dir.appendingPathComponent("config.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        APIKeyStore.pathOverride = dir.appendingPathComponent("keys.json")
    }

    override func tearDownWithError() throws {
        APIKeyStore.pathOverride = nil
        try FileManager.default.removeItem(at: dir)
    }

    private func write(_ json: String) throws {
        try json.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private let qianfanProfile =
        #"{"id":"default-qianfan","name":"Qianfan / Kimi","providerID":"qianfan","model":"kimi-k2.5","baseURL":"https://qianfan.baidubce.com/v2/coding","reasoningEffort":"off"}"#
    private let deepseekProfile =
        #"{"id":"ds1","name":"deepseek","providerID":"custom","model":"deepseek-v4-flash","baseURL":"https://api.deepseek.com","reasoningEffort":"medium","reasoningStyleOverride":"kimi"}"#

    func testQianfanProfileAndKeyGoAndDeepSeekStays() throws {
        APIKeyStore.write("old-fake-key", forProfile: "default-qianfan")
        APIKeyStore.write("deepseek-fake-key", forProfile: "ds1")
        try write(#"{"llmProfiles":[\#(qianfanProfile),\#(deepseekProfile)],"selectedLLMProfileID":"default-qianfan"}"#)

        let config = Config.load(at: configURL, legacyURL: nil)

        XCTAssertEqual(config.llmProfiles.map(\.id), ["ds1"])
        XCTAssertEqual(config.selectedLLMProfileID, "ds1")
        XCTAssertNil(APIKeyStore.read(profileID: "default-qianfan"), "the key entry must be gone")
        XCTAssertEqual(APIKeyStore.read(profileID: "ds1"), "deepseek-fake-key", "DeepSeek's key stays")

        // The change reached the disk, so the next load has nothing to do.
        let onDisk = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("qianfan"))
        XCTAssertEqual(Config.load(at: configURL, legacyURL: nil), config)
    }

    func testOldKimiFormatValueReadsAsThinkingForDeepSeek() throws {
        try write(#"{"llmProfiles":[\#(deepseekProfile)],"selectedLLMProfileID":"ds1"}"#)
        let config = Config.load(at: configURL, legacyURL: nil)
        XCTAssertEqual(config.llmProfiles[0].reasoningStyleOverride, .thinking)
        XCTAssertEqual(config.llmProfiles[0].reasoningEffort, .medium)
        try config.save(to: configURL)
        XCTAssertTrue(try String(contentsOf: configURL, encoding: .utf8).contains("\"thinking\""))
    }

    func testOnlyQianfanLeavesNoProfilesAndTheCLIOrder() throws {
        try write(#"{"llmProfiles":[\#(qianfanProfile)],"selectedLLMProfileID":"default-qianfan"}"#)
        let config = Config.load(at: configURL, legacyURL: nil)
        XCTAssertTrue(config.llmProfiles.isEmpty)
        XCTAssertEqual(config.llmRoute, .subscription)
        XCTAssertEqual(config.primaryCLI, .claude)
    }

    func testFlatLegacyQianfanConfigIsRemovedToo() throws {
        try write(
            #"{"llmProviderID":"qianfan","llmModel":"kimi-k2.5","llmBaseURL":"https://qianfan.baidubce.com/v2/coding"}"#
        )
        XCTAssertTrue(Config.load(at: configURL, legacyURL: nil).llmProfiles.isEmpty)
    }

    func testFlatLegacyDeepSeekConfigStays() throws {
        try write(
            #"{"llmProviderID":"custom","llmCustomName":"DS","llmModel":"deepseek-v4-flash","llmBaseURL":"https://api.deepseek.com"}"#
        )
        let config = Config.load(at: configURL, legacyURL: nil)
        XCTAssertEqual(config.llmProfiles.map(\.model), ["deepseek-v4-flash"])
    }

    func testCustomProfilePointingAtQianfanIsRemoved() throws {
        try write(
            #"{"llmProfiles":[{"id":"c1","name":"mine","providerID":"custom","model":"m","baseURL":"https://qianfan.baidubce.com/v2","reasoningEffort":"off"}]}"#
        )
        XCTAssertTrue(Config.load(at: configURL, legacyURL: nil).llmProfiles.isEmpty)
    }

    func testFreshInstallHasNoProfilesAndNoQianfanPreset() {
        let config = Config()
        XCTAssertTrue(config.llmProfiles.isEmpty)
        XCTAssertNil(LLMProvider.byID("qianfan"))
        XCTAssertNotNil(LLMProvider.byID("deepseek"))
        XCTAssertEqual(LLMProvider.reasoningStyle(baseURL: "https://api.deepseek.com", providerID: "custom"), .thinking)
    }

    func testNewSettingsDefaultWhenAbsent() throws {
        try write(#"{"llmProfiles":[]}"#)
        let config = Config.load(at: configURL, legacyURL: nil)
        XCTAssertEqual(config.dailyCLICallCap, 200)
        XCTAssertTrue(config.redactionEnabled)
        XCTAssertFalse(config.allowCLIAPIBilling)
        XCTAssertEqual(config.claudeModels, .claudeDefault)
        XCTAssertEqual(config.codexModels.normal, "gpt-6.1-sol")
    }

    func testCorruptConfigIsNotOverwrittenAndDeletesNothing() throws {
        try write("{ not json")
        var expected = Config()
        expected.audioRetentionDays = 0  // D-52: unsure what the user chose, so keep forever
        XCTAssertEqual(Config.load(at: configURL, legacyURL: nil), expected)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), "{ not json")
    }
}
