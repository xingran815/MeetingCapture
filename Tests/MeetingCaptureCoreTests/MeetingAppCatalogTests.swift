import XCTest

@testable import MeetingCaptureCore

/// VSee call recorded silence, 2026-11-11: VSee was not in the catalog, Chrome was open, so
/// capture was scoped to Chrome and the system track was silent. Each test uses its own temp
/// folder and passes the config path explicitly, so the real config is never read.
final class MeetingAppCatalogTests: AudioTestCase {

    private var configURL: URL { url("config.json") }

    private func app(_ id: String) throws -> MeetingApp {
        try XCTUnwrap(MeetingApp.catalog.first { $0.id == id })
    }

    /// Writes a config JSON holding only the given meeting-app keys, then loads it.
    private func load(enabled: [String]?, known: [String]?) throws -> Config {
        var obj: [String: Any] = [:]
        if let enabled { obj["enabledMeetingAppIDs"] = enabled }
        if let known { obj["knownMeetingAppIDs"] = known }
        try JSONSerialization.data(withJSONObject: obj).write(to: configURL)
        return Config.load(at: configURL, legacyURL: nil)
    }

    // MARK: catalog

    func testVSeeIsInTheCatalogAndIsNotABrowser() throws {
        let vsee = try app("vsee")
        XCTAssertEqual(vsee.label, "VSee")
        XCTAssertEqual(vsee.bundleIDs, ["com.vsee.VSee"])
        XCTAssertFalse(vsee.isBrowser)
        XCTAssertNil(AudioCapture.targetWarning(for: vsee))
    }

    func testEveryNonBrowserComesBeforeEveryBrowser() {
        let browserIdx = MeetingApp.catalog.indices.filter { MeetingApp.catalog[$0].isBrowser }
        let otherIdx = MeetingApp.catalog.indices.filter { !MeetingApp.catalog[$0].isBrowser }
        XCTAssertFalse(browserIdx.isEmpty)
        XCTAssertLessThan(otherIdx.max()!, browserIdx.min()!)
    }

    func testCatalogIDsAreUniqueAndFirstReleaseIDsAreInIt() {
        XCTAssertEqual(Set(MeetingApp.allIDs).count, MeetingApp.allIDs.count)
        XCTAssertTrue(Set(MeetingApp.firstReleaseIDs).isSubset(of: Set(MeetingApp.allIDs)))
        XCTAssertFalse(MeetingApp.firstReleaseIDs.contains("vsee"))
    }

    /// AudioCapture.run walks the enabled catalog in order and takes the first app that is
    /// running (inline, over SCRunningApplication, so not callable without ScreenCaptureKit).
    /// This repeats that rule over bundle ids, using the same catalog filter DesktopAPI uses.
    func testWithVSeeAndChromeRunningVSeeIsChosen() throws {
        let running: Set<String> = ["com.google.Chrome", "com.vsee.VSee"]
        let enabled = MeetingApp.catalog.filter { Config().enabledMeetingAppIDs.contains($0.id) }
        let chosen = enabled.first { $0.bundleIDs.contains(where: running.contains) }
        XCTAssertEqual(chosen?.id, "vsee")
    }

    // MARK: config migration

    func testOldConfigWithTheFiveOldIDsGainsVSee() throws {
        let c = try load(enabled: MeetingApp.firstReleaseIDs, known: nil)
        XCTAssertTrue(c.enabledMeetingAppIDs.contains("vsee"))
        XCTAssertEqual(c.enabledMeetingAppIDs, MeetingApp.allIDs)
        XCTAssertEqual(c.knownMeetingAppIDs, MeetingApp.allIDs)
    }

    func testOldConfigWithOnlyZoomGetsZoomAndVSee() throws {
        let c = try load(enabled: ["zoom"], known: nil)
        XCTAssertEqual(c.enabledMeetingAppIDs, ["zoom", "vsee"])
    }

    func testAnIDTheUserHadSeenAndSwitchedOffStaysOff() throws {
        let c = try load(enabled: ["zoom"], known: MeetingApp.allIDs)
        XCTAssertEqual(c.enabledMeetingAppIDs, ["zoom"])
        XCTAssertFalse(c.enabledMeetingAppIDs.contains("vsee"))
    }

    func testForeignIDsAreKeptAfterTheCatalogIDs() throws {
        let c = try load(enabled: ["zoom", "mystery"], known: nil)
        XCTAssertEqual(c.enabledMeetingAppIDs, ["zoom", "vsee", "mystery"])
    }

    func testRoundTripKeepsTheUsersChoiceAndWritesKnownIDs() throws {
        var c = try load(enabled: MeetingApp.firstReleaseIDs, known: nil)
        c.enabledMeetingAppIDs.removeAll { $0 == "vsee" }
        try c.save(to: configURL)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        XCTAssertEqual(json["knownMeetingAppIDs"] as? [String], MeetingApp.allIDs)

        let again = Config.load(at: configURL, legacyURL: nil)
        XCTAssertFalse(again.enabledMeetingAppIDs.contains("vsee"))
        XCTAssertEqual(again.knownMeetingAppIDs, MeetingApp.allIDs)
    }

    func testAFreshConfigEnablesEverythingIncludingVSee() {
        XCTAssertEqual(Config().enabledMeetingAppIDs, MeetingApp.allIDs)
        XCTAssertTrue(Config().enabledMeetingAppIDs.contains("vsee"))
    }
}
