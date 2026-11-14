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

    func testFourTemplateGlyphsAreDistinct() throws {
        XCTAssertEqual(MenuBarGlyph.allCases.count, 4)
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
        XCTAssertEqual(labels.count, 4)
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
        XCTAssertEqual(list.filter(\.isRecordingCommand).count, 2)
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
