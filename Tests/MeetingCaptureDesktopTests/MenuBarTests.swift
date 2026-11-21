import AppKit
import XCTest

@testable import MeetingCaptureDesktop

final class MenuBarTests: XCTestCase {
    private typealias Activity = AppModel.Activity

    func testGlyphMapping() {
        XCTAssertEqual(MenuBarGlyph(Activity.idle), .idle)
        XCTAssertEqual(MenuBarGlyph(Activity.starting), .recording)
        XCTAssertEqual(MenuBarGlyph(Activity.recording(elapsed: 3)), .recording)
        XCTAssertEqual(MenuBarGlyph(Activity.paused(elapsed: 3)), .paused)
        XCTAssertEqual(MenuBarGlyph(Activity.processing(step: 1, of: 2, name: "x")), .processing)
    }

    /// Draws at 2x into a bitmap so shapes that differ by a pixel at 1x still differ.
    private func pixels(_ image: NSImage) throws -> Data {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let ctx = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
        NSGraphicsContext.restoreGraphicsState()
        return Data(bytes: try XCTUnwrap(rep.bitmapData), count: rep.bytesPerRow * 36)
    }

    func testFiveTemplateGlyphsAreDistinct() throws {
        XCTAssertEqual(MenuBarGlyph.allCases.count, 5)
        var seen: [Data] = []
        var labels = Set<String>()
        for glyph in MenuBarGlyph.allCases {
            let image = glyph.image
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18), "\(glyph)")
            XCTAssertTrue(image.isTemplate, "\(glyph)")
            XCTAssertEqual(image.accessibilityDescription, glyph.accessibilityLabel)
            labels.insert(glyph.accessibilityLabel)
            let data = try pixels(image)
            XCTAssertFalse(data.allSatisfy { $0 == 0 }, "\(glyph) drew nothing")
            for (i, other) in seen.enumerated() {
                XCTAssertNotEqual(data, other, "\(glyph) looks like glyph #\(i)")
            }
            seen.append(data)
        }
        XCTAssertEqual(labels.count, 5)
    }

    func testAskingGlyphIsOnlyForAnIdleAppWithAnUnansweredCall() {
        XCTAssertEqual(MenuBarGlyph(Activity.idle, unansweredCall: true), .asking)
        XCTAssertEqual(MenuBarGlyph(Activity.idle, unansweredCall: false), .idle)
        XCTAssertEqual(MenuBarGlyph(Activity.recording(elapsed: 1), unansweredCall: true), .recording)
        XCTAssertEqual(MenuBarGlyph(Activity.starting, unansweredCall: true), .recording)
        XCTAssertEqual(MenuBarGlyph(Activity.paused(elapsed: 1), unansweredCall: true), .paused)
        XCTAssertEqual(MenuBarGlyph.asking.image.size, NSSize(width: 18, height: 18))
    }

    func testStatusLineForAnUnansweredCall() {
        XCTAssertEqual(MenuBarText.status(.idle, unansweredCall: "Zoom"), "? Zoom call, not recording")
        XCTAssertEqual(MenuBarText.status(.idle, unansweredCall: nil), "✓ Ready")
    }

    func testRecordThisCallIsFirstOnlyWhenIdleWithAnUnansweredCall() {
        let idle = MenuBarItem.items(
            recording: false, paused: false, enabled: { _ in true }, lastReport: nil, unansweredCall: true)
        XCTAssertEqual(idle.first?.title, "Record This Call")
        XCTAssertEqual(idle.first?.action, .recordCall)
        XCTAssertEqual(idle[1].title, "Start Recording")
        let off = MenuBarItem.items(
            recording: false, paused: false, enabled: { _ in false }, lastReport: nil, unansweredCall: true)
        XCTAssertEqual(off.first?.enabled, false, "follows canPerform(.start)")
        let rec = MenuBarItem.items(
            recording: true, paused: false, enabled: { _ in true }, lastReport: nil, unansweredCall: true)
        XCTAssertFalse(rec.contains { $0.action == .recordCall })
        let plain = MenuBarItem.items(recording: false, paused: false, enabled: { _ in true }, lastReport: nil)
        XCTAssertFalse(plain.contains { $0.action == .recordCall })
    }

    func testClock() {
        XCTAssertEqual(MenuBarText.clock(0), "00:00")
        XCTAssertEqual(MenuBarText.clock(-5), "00:00")
        XCTAssertEqual(MenuBarText.clock(724.9), "12:04")
        XCTAssertEqual(MenuBarText.clock(3599), "59:59")
        XCTAssertEqual(MenuBarText.clock(3600), "1:00:00")
        XCTAssertEqual(MenuBarText.clock(3723), "1:02:03")
    }

    func testLabelAndStatusForEveryActivity() {
        XCTAssertNil(MenuBarText.label(.idle))
        XCTAssertNil(MenuBarText.label(.starting))
        XCTAssertEqual(MenuBarText.label(.recording(elapsed: 724)), "12:04")
        XCTAssertEqual(MenuBarText.label(.paused(elapsed: 724)), "12:04")
        XCTAssertEqual(MenuBarText.label(.processing(step: 3, of: 6, name: "Transcribing")), "3/6")
        XCTAssertEqual(MenuBarText.status(.idle), "✓ Ready")
        XCTAssertEqual(MenuBarText.status(.starting), "● Starting…")
        XCTAssertEqual(MenuBarText.status(.recording(elapsed: 724)), "● Recording 12:04")
        XCTAssertEqual(MenuBarText.status(.recording(elapsed: 3723)), "● Recording 1:02:03")
        XCTAssertEqual(MenuBarText.status(.paused(elapsed: 0)), "‖ Paused at 00:00")
        XCTAssertEqual(
            MenuBarText.status(.processing(step: 3, of: 6, name: "Transcribing")), "··· Transcribing 3/6")
    }

    private func items(
        recording: Bool = false, paused: Bool = false, enabled: Bool = true, last: String? = nil
    ) -> [MenuBarItem] {
        MenuBarItem.items(recording: recording, paused: paused, enabled: { _ in enabled }, lastReport: last)
    }

    /// Finding: on a Mac with a notch the clock beside the glyph widened the item while
    /// recording, and macOS hid it. The bar shows the glyph only unless the user opts in.
    func testNotchFindingBarShowsGlyphOnlyByDefault() {
        XCTAssertEqual(MenuBarPreference.showsTextKey, "menuBarShowsText")
        let all: [Activity] = [
            .idle, .starting, .recording(elapsed: 724), .paused(elapsed: 724),
            .processing(step: 3, of: 6, name: "Transcribing"),
        ]
        for activity in all {
            XCTAssertNil(MenuBarText.barText(activity, showsText: false), "\(activity)")
            XCTAssertEqual(
                MenuBarText.barText(activity, showsText: true), MenuBarText.label(activity),
                "\(activity)")
        }
        XCTAssertNil(MenuBarText.barText(.idle, showsText: true))
        XCTAssertNil(MenuBarText.barText(.starting, showsText: true))
        XCTAssertEqual(MenuBarText.barText(.recording(elapsed: 724), showsText: true), "12:04")
        XCTAssertEqual(MenuBarText.barText(.paused(elapsed: 724), showsText: true), "12:04")
        XCTAssertEqual(
            MenuBarText.barText(.processing(step: 3, of: 6, name: "Transcribing"), showsText: true),
            "3/6")
    }

    func testIdleStartsFirst() {
        let list = items()
        XCTAssertEqual(list.first?.action, .command(.start))
        XCTAssertEqual(list.filter(\.isRecordingCommand).count, 1)
    }

    func testRecordingOffersPauseThenStop() {
        let list = items(recording: true)
        XCTAssertEqual(list[0].action, .command(.pauseResume))
        XCTAssertEqual(list[0].title, "Pause")
        XCTAssertEqual(list[1].action, .command(.stop))
        XCTAssertEqual(list[2].action, .command(.abort))
        XCTAssertEqual(list[2].title, "Abort…")
        XCTAssertEqual(list[2].keys, "⌥⌘.")
        XCTAssertEqual(list.filter(\.isRecordingCommand).count, 3)
        XCTAssertFalse(items().contains { $0.action == .command(.abort) }, "no Abort while idle")
    }

    func testPausedOffersResume() {
        let list = items(recording: true, paused: true)
        XCTAssertEqual(list[0].title, "Resume")
        XCTAssertEqual(list[0].action, .command(.pauseResume))
    }

    func testEnabledFlagsPassThrough() {
        let seen = MenuBarItem.items(
            recording: true, paused: false, enabled: { $0 == .stop }, lastReport: nil)
        XCTAssertFalse(seen[0].enabled)
        XCTAssertTrue(seen[1].enabled)
        XCTAssertFalse(items(enabled: false)[0].enabled)
    }

    func testLastReportPresentOrAbsent() {
        XCTAssertFalse(items().contains { $0.action == .openLastReport })
        let with = items(last: "Standup")
        let row = with.first { $0.action == .openLastReport }
        XCTAssertEqual(row?.title, "↳ Standup")
        XCTAssertTrue(row?.enabled ?? false)
    }

    func testTailIsAlwaysOpenSettingsQuit() {
        for list in [items(), items(recording: true), items(recording: true, paused: true, last: "x")] {
            XCTAssertEqual(list.suffix(3).map(\.action), [.openWindow, .settings, .quit])
        }
    }

    func testIdsAreUnique() {
        for list in [items(), items(recording: true, last: "Pause")] {
            XCTAssertEqual(Set(list.map(\.id)).count, list.count)
        }
    }
}
