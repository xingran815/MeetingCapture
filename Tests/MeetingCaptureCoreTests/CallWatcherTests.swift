import XCTest

@testable import MeetingCaptureCore

final class CallWatcherTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private func user(_ bundle: String) -> MicUser { MicUser(pid: 4242, bundleID: bundle) }
    private let zoom = "us.zoom.xos"
    private let chrome = "com.google.Chrome"

    private func started(_ events: [CallEvent]) -> [DetectedCall] {
        events.compactMap { if case .started(let c) = $0 { return c } else { return nil } }
    }
    private func ended(_ events: [CallEvent]) -> [DetectedCall] {
        events.compactMap { if case .ended(let c) = $0 { return c } else { return nil } }
    }

    // MARK: Start and end

    func testNoCallBeforeTheThreeSecondHoldAndACallAtThree() {
        let w = CallWatcher()
        XCTAssertTrue(w.update(now: at(0), users: [user(zoom)], running: []).isEmpty)
        XCTAssertTrue(w.update(now: at(2.9), users: [user(zoom)], running: []).isEmpty)
        let events = w.update(now: at(3), users: [user(zoom)], running: [])
        XCTAssertEqual(started(events).map(\.appID), ["zoom"])
        XCTAssertNil(started(events).first?.site)
        XCTAssertEqual(started(events).first?.isBrowser, false)
        XCTAssertEqual(w.activeCalls.map(\.appID), ["zoom"])
    }

    func testOnlyOneStartedPerCall() {
        let w = CallWatcher()
        _ = w.update(now: at(0), users: [user(zoom)], running: [])
        var count = started(w.update(now: at(3), users: [user(zoom)], running: [])).count
        for s in stride(from: 4.0, through: 60, by: 1) {
            count += started(w.update(now: at(s), users: [user(zoom)], running: [])).count
        }
        XCTAssertEqual(count, 1)
    }

    func testAShortHoldThatNeverBecameACallStartsOver() {
        let w = CallWatcher()
        _ = w.update(now: at(0), users: [user(zoom)], running: [])
        _ = w.update(now: at(2), users: [], running: [])
        // Held again at 4: the hold counts from 4, not from 0.
        XCTAssertTrue(started(w.update(now: at(4), users: [user(zoom)], running: [])).isEmpty)
        XCTAssertTrue(started(w.update(now: at(6.9), users: [user(zoom)], running: [])).isEmpty)
        XCTAssertEqual(started(w.update(now: at(7), users: [user(zoom)], running: [])).count, 1)
    }

    func testAReleaseShorterThanTheGraceIsNeitherAnEndNorANewCall() {
        let w = CallWatcher()
        _ = w.update(now: at(0), users: [user(zoom)], running: [])
        XCTAssertEqual(started(w.update(now: at(3), users: [user(zoom)], running: [])).count, 1)
        XCTAssertTrue(w.update(now: at(20), users: [user(zoom)], running: []).isEmpty)
        XCTAssertTrue(w.update(now: at(25), users: [], running: []).isEmpty)
        XCTAssertTrue(w.update(now: at(29.9), users: [], running: []).isEmpty)
        XCTAssertTrue(w.update(now: at(30), users: [user(zoom)], running: []).isEmpty, "back: same call")
        XCTAssertEqual(w.activeCalls.count, 1)
        XCTAssertTrue(w.update(now: at(60), users: [user(zoom)], running: []).isEmpty)
    }

    func testReleaseOfTenSecondsEndsTheCallOnceAndAnotherHoldIsANewCall() {
        let w = CallWatcher()
        _ = w.update(now: at(0), users: [user(zoom)], running: [])
        _ = w.update(now: at(3), users: [user(zoom)], running: [])
        _ = w.update(now: at(10), users: [user(zoom)], running: [])  // last held at 10
        XCTAssertTrue(w.update(now: at(19.9), users: [], running: []).isEmpty)
        XCTAssertEqual(ended(w.update(now: at(20), users: [], running: [])).map(\.appID), ["zoom"])
        XCTAssertTrue(w.update(now: at(21), users: [], running: []).isEmpty, "ended only once")
        XCTAssertTrue(w.activeCalls.isEmpty)
        // A new call later starts afresh.
        _ = w.update(now: at(100), users: [user(zoom)], running: [])
        XCTAssertEqual(started(w.update(now: at(103), users: [user(zoom)], running: [])).count, 1)
    }

    func testEndedReportsTheSameCallThatStarted() {
        let w = CallWatcher()
        _ = w.update(now: at(0), users: [user(zoom)], running: [])
        let call = started(w.update(now: at(3), users: [user(zoom)], running: [])).first
        let end = ended(w.update(now: at(14), users: [], running: [])).first
        XCTAssertNotNil(call)
        XCTAssertEqual(end, call)
    }

    // MARK: Which apps

    func testHelperBundleIDsMatchButALookAlikeDoesNot() {
        for bundle in ["com.google.Chrome.helper", "com.google.Chrome"] {
            let w = CallWatcher(appIDs: ["chrome"])
            _ = w.update(now: at(0), users: [user(bundle)], running: [])
            let events = w.update(now: at(10), users: [user(bundle)], running: [])
            XCTAssertTrue(events.contains(.checkTabs(appID: "chrome")), bundle)
        }
        let zw = CallWatcher(appIDs: ["zoom"])
        _ = zw.update(now: at(0), users: [user("us.zoom.xos.something")], running: [])
        XCTAssertEqual(started(zw.update(now: at(3), users: [user("us.zoom.xos.something")], running: [])).count, 1)

        let x = CallWatcher(appIDs: ["chrome"])
        _ = x.update(now: at(0), users: [user("com.google.ChromeX")], running: [])
        XCTAssertTrue(x.update(now: at(30), users: [user("com.google.ChromeX")], running: []).isEmpty)
        XCTAssertTrue(CallWatcher.matches(MeetingApp.catalog[0], bundleID: "us.zoom.xos.ZoomAudio", running: []))
        XCTAssertFalse(CallWatcher.matches(MeetingApp.catalog[0], bundleID: "us.zoom.xosX", running: []))
    }

    func testWebKitGPUCountsAsSafariOnlyWhileSafariRuns() {
        let safari = MeetingApp.catalog.first { $0.id == "safari" }!
        XCTAssertTrue(
            CallWatcher.matches(safari, bundleID: "com.apple.WebKit.GPU", running: ["com.apple.Safari"]))
        XCTAssertFalse(CallWatcher.matches(safari, bundleID: "com.apple.WebKit.GPU", running: ["com.other.App"]))
        XCTAssertFalse(CallWatcher.matches(safari, bundleID: "com.apple.WebKit.GPU", running: []))

        let w = CallWatcher(appIDs: ["safari"])
        _ = w.update(now: at(0), users: [user("com.apple.WebKit.GPU")], running: ["com.apple.Safari"])
        XCTAssertEqual(
            w.update(now: at(10), users: [user("com.apple.WebKit.GPU")], running: ["com.apple.Safari"]),
            [.checkTabs(appID: "safari")])
        let n = CallWatcher(appIDs: ["safari"])
        _ = n.update(now: at(0), users: [user("com.apple.WebKit.GPU")], running: [])
        XCTAssertTrue(n.update(now: at(30), users: [user("com.apple.WebKit.GPU")], running: []).isEmpty)
    }

    func testAnAppOutsideAppIDsNeverStarts() {
        let w = CallWatcher(appIDs: ["teams"])
        _ = w.update(now: at(0), users: [user(zoom)], running: [])
        XCTAssertTrue(w.update(now: at(60), users: [user(zoom)], running: []).isEmpty)
        XCTAssertTrue(w.activeCalls.isEmpty)
        let none = CallWatcher(appIDs: [])
        _ = none.update(now: at(0), users: [user(zoom)], running: [])
        XCTAssertTrue(none.update(now: at(60), users: [user(zoom)], running: []).isEmpty)
    }

    func testRemovingAnAppMidCallEndsIt() {
        let w = CallWatcher()
        _ = w.update(now: at(0), users: [user(zoom)], running: [])
        _ = w.update(now: at(3), users: [user(zoom)], running: [])
        w.appIDs.remove("zoom")
        XCTAssertEqual(ended(w.update(now: at(4), users: [user(zoom)], running: [])).map(\.appID), ["zoom"])
        XCTAssertTrue(w.activeCalls.isEmpty)
        // Taken out and not asked again while it stays out.
        XCTAssertTrue(w.update(now: at(60), users: [user(zoom)], running: []).isEmpty)
    }

    func testTwoAppsAreTrackedSeparately() {
        let w = CallWatcher(appIDs: ["zoom", "teams"])
        _ = w.update(now: at(0), users: [user(zoom), user("com.microsoft.teams2")], running: [])
        let events = w.update(now: at(3), users: [user(zoom), user("com.microsoft.teams2")], running: [])
        XCTAssertEqual(Set(started(events).map(\.appID)), ["zoom", "teams"])
        let later = w.update(now: at(14), users: [user(zoom)], running: [])
        XCTAssertEqual(ended(later).map(\.appID), ["teams"])
        XCTAssertEqual(w.activeCalls.map(\.appID), ["zoom"])
    }

    // MARK: Browsers

    func testABrowserNeedsTenSecondsAndAsksForItsTabsOnceThenWaits() {
        let w = CallWatcher(appIDs: ["chrome"])
        _ = w.update(now: at(0), users: [user(chrome)], running: [])
        XCTAssertTrue(w.update(now: at(3), users: [user(chrome)], running: []).isEmpty, "not 3 s for a browser")
        XCTAssertTrue(w.update(now: at(9.9), users: [user(chrome)], running: []).isEmpty)
        XCTAssertEqual(w.update(now: at(10), users: [user(chrome)], running: []), [.checkTabs(appID: "chrome")])
        // The answer hasn't come yet: no second question.
        XCTAssertTrue(w.update(now: at(11), users: [user(chrome)], running: []).isEmpty)
        XCTAssertTrue(w.update(now: at(15), users: [user(chrome)], running: []).isEmpty)
    }

    func testAMeetingTabStartsTheCallWithItsSite() {
        let w = CallWatcher(appIDs: ["chrome"])
        _ = w.update(now: at(0), users: [user(chrome)], running: [])
        _ = w.update(now: at(10), users: [user(chrome)], running: [])
        w.tabsChecked(appID: "chrome", .meeting(host: "meet.google.com"))
        let call = started(w.update(now: at(11), users: [user(chrome)], running: [])).first
        XCTAssertEqual(call?.site, "meet.google.com")
        XCTAssertEqual(call?.isBrowser, true)
        XCTAssertEqual(call?.sourceLine, "Chrome is on meet.google.com")
        XCTAssertTrue(started(w.update(now: at(12), users: [user(chrome)], running: [])).isEmpty)
    }

    func testUnreadableTabsStartTheCallWithNoSite() {
        let w = CallWatcher(appIDs: ["chrome"])
        _ = w.update(now: at(0), users: [user(chrome)], running: [])
        _ = w.update(now: at(10), users: [user(chrome)], running: [])
        w.tabsChecked(appID: "chrome", .unknown)
        let call = started(w.update(now: at(11), users: [user(chrome)], running: [])).first
        XCTAssertNotNil(call)
        XCTAssertNil(call?.site)
        XCTAssertEqual(call?.sourceLine, "Chrome is using the microphone")
    }

    func testNoMeetingTabAsksNothingAndIsAskedAgainOnlyAfterTheRecheck() {
        let w = CallWatcher(appIDs: ["chrome"])
        _ = w.update(now: at(0), users: [user(chrome)], running: [])
        XCTAssertEqual(w.update(now: at(10), users: [user(chrome)], running: []), [.checkTabs(appID: "chrome")])
        w.tabsChecked(appID: "chrome", .notMeeting)
        XCTAssertTrue(w.update(now: at(11), users: [user(chrome)], running: []).isEmpty)
        XCTAssertTrue(w.update(now: at(19.9), users: [user(chrome)], running: []).isEmpty)
        XCTAssertEqual(w.update(now: at(20), users: [user(chrome)], running: []), [.checkTabs(appID: "chrome")])
        // This time a meeting tab is open.
        w.tabsChecked(appID: "chrome", .meeting(host: "us02web.zoom.us"))
        XCTAssertEqual(
            started(w.update(now: at(21), users: [user(chrome)], running: [])).first?.site, "us02web.zoom.us")
        XCTAssertTrue(w.activeCalls.count == 1)
    }

    func testABrowserCallEndsAfterTheGraceLikeAnyOther() {
        let w = CallWatcher(appIDs: ["chrome"])
        _ = w.update(now: at(0), users: [user(chrome)], running: [])
        _ = w.update(now: at(10), users: [user(chrome)], running: [])
        w.tabsChecked(appID: "chrome", .meeting(host: "meet.google.com"))
        _ = w.update(now: at(11), users: [user(chrome)], running: [])
        XCTAssertEqual(ended(w.update(now: at(21), users: [], running: [])).first?.site, "meet.google.com")
        // The next call asks about the tabs again.
        _ = w.update(now: at(100), users: [user(chrome)], running: [])
        XCTAssertEqual(w.update(now: at(110), users: [user(chrome)], running: []), [.checkTabs(appID: "chrome")])
    }

    // MARK: MeetingSites

    func testMeetingHostsMatchOnADotBoundary() {
        for h in [
            "meet.google.com", "us02web.zoom.us", "ZOOM.US.", "zoom.us", "teams.microsoft.com", "teams.live.com",
            "company.webex.com",
        ] {
            XCTAssertTrue(MeetingSites.isMeetingHost(h), h)
        }
        for h in ["evilzoom.us", "zoom.us.example.com", "", ".", "notmeet.google.com", "google.com", "not a host"] {
            XCTAssertFalse(MeetingSites.isMeetingHost(h), h)
        }
    }

    func testMeetingHostInURLsNeedsHTTPSAndTakesTheFirstMeetingOne() {
        XCTAssertEqual(
            MeetingSites.meetingHost(in: ["https://example.org/a", "https://MEET.google.com/abc-defg-hij?x=1"]),
            "meet.google.com")
        XCTAssertEqual(MeetingSites.meetingHost(in: ["https://us02web.zoom.us/j/123"]), "us02web.zoom.us")
        XCTAssertNil(MeetingSites.meetingHost(in: ["http://meet.google.com/abc"]))
        XCTAssertNil(MeetingSites.meetingHost(in: ["https://evilzoom.us/j/1", "https://zoom.us.example.com/"]))
        XCTAssertNil(MeetingSites.meetingHost(in: ["", "garbage", "https://", "meet.google.com"]))
        XCTAssertNil(MeetingSites.meetingHost(in: []))
        XCTAssertNil(MeetingSites.meetingHost(in: ["https://example.org/?next=https://meet.google.com"]))
        XCTAssertNil(MeetingSites.meetingHost(in: ["https://meet.google.com.evil.example/"]))
    }

    // MARK: DetectedCall

    func testSourceLineNames() {
        let zoomCall = DetectedCall(appID: "zoom", appLabel: "Zoom", site: nil, isBrowser: false)
        XCTAssertEqual(zoomCall.sourceLine, "Zoom is using the microphone")
        let safari = DetectedCall(appID: "safari", appLabel: "Safari (Meet)", site: "meet.google.com", isBrowser: true)
        XCTAssertEqual(safari.appName, "Safari")
        XCTAssertEqual(safari.sourceLine, "Safari is on meet.google.com")
    }

    // MARK: Recorder.captureApps

    func testCaptureAppsPutsTheSourceFirstEvenWhenNotEnabled() {
        let apps = Recorder.captureApps(enabledIDs: ["teams", "webex"], sourceAppID: "zoom")
        XCTAssertEqual(apps.map(\.id), ["zoom", "teams", "webex"])
    }

    func testCaptureAppsMovesAnEnabledSourceToTheFrontWithoutRepeating() {
        let apps = Recorder.captureApps(enabledIDs: ["zoom", "teams", "webex"], sourceAppID: "webex")
        XCTAssertEqual(apps.map(\.id), ["webex", "zoom", "teams"])
    }

    func testCaptureAppsKeepsTheEnabledOrderWithoutASource() {
        let apps = Recorder.captureApps(enabledIDs: ["webex", "zoom"], sourceAppID: nil)
        XCTAssertEqual(apps.map(\.id), MeetingApp.catalog.map(\.id).filter { ["webex", "zoom"].contains($0) })
    }

    func testCaptureAppsIgnoresAnUnknownSource() {
        let apps = Recorder.captureApps(enabledIDs: ["teams"], sourceAppID: "nonesuch")
        XCTAssertEqual(apps.map(\.id), ["teams"])
    }
}
