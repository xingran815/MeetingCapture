import AppKit
import Foundation
import MeetingCaptureCore
import SwiftUI
import WebKit

/// Test-only states for screenshots (spec 07's Done-when): with `MEETINGCAPTURE_E2E=1`,
/// `MEETINGCAPTURE_DEMO=recording|paused|processing` shows that screen with invented
/// numbers and no capture at all. Without `MEETINGCAPTURE_E2E=1` it does nothing, like
/// the CLI's other test-only switches.
@MainActor
enum DemoState {
    static var requested: String? {
        let env = ProcessInfo.processInfo.environment
        guard env["MEETINGCAPTURE_E2E"] == "1" else { return nil }
        return env["MEETINGCAPTURE_DEMO"]
    }

    static func applyIfAsked(to model: AppModel) {
        WindowSnapshot.scheduleIfAsked()
        DispatchQueue.main.async { MenuBarSnapshot.writeIfAsked(model: model) }
        guard let demo = requested else { return }
        switch demo {
        case "recording", "paused":
            model.needsSetup = false
            model.makeSession = { DemoSession(paused: demo == "paused") }
            model.afterRecording = { _, _ in }
            model.startRecording()
        case "processing":
            model.needsSetup = false
            let stages: [ProcessingStage] = [
                .removingEcho, .transcribing, .labellingSpeakers, .savingAudio, .writingReport,
            ]
            var steps = stages.map { AppModel.StepState(stage: $0) }
            steps[0].status = .skipped
            steps[0].detail = "no echo found"
            steps[1].status = .running
            var job = AppModel.Job(
                kind: .newRecording, base: URL(fileURLWithPath: "/tmp/20261114_100300"),
                title: "Standup (untitled)", steps: steps)
            job.fraction = 0.64
            model.showDemoJob(job)
        case "library":
            model.needsSetup = false
            model.selection = model.entries.first?.id
        default:
            break
        }
    }
}

/// A recording that never touches audio: live at once, a fixed clock, gentle levels.
@MainActor
final class DemoSession: RecordingSession {
    let base = URL(fileURLWithPath: "/tmp/mc-demo/20261114_103000")
    private var stopped: CheckedContinuation<[URL], Error>?
    private var tick = 0.0
    private(set) var isPaused: Bool

    init(paused: Bool) { isPaused = paused }

    func start() async throws -> [URL] {
        try await withCheckedThrowingContinuation { stopped = $0 }
    }

    func togglePause() -> Bool {
        isPaused.toggle()
        return isPaused
    }

    func stop() {
        stopped?.resume(returning: [])
        stopped = nil
    }

    func abort() { stop() }
    /// The demo writes no files, so there is nothing to move.
    func discard(parts: [URL]) throws -> [URL] { [] }

    var isLive: Bool { true }
    var elapsedSeconds: Double { 12 * 60 + 4 }
    var levels: (mic: Float, system: Float) {
        tick += 0.37
        return (Float(0.02 + 0.015 * sin(tick)), Float(0.05 + 0.04 * sin(tick * 0.6 + 1)))
    }
    var sourceLabel: String { "Zoom" }
}

/// Test-only: with `MEETINGCAPTURE_E2E=1` and `MEETINGCAPTURE_SNAPSHOT=<file.png>`, the
/// app draws its main window into that PNG once it has settled, then quits. The report's
/// web view draws itself apart from AppKit, so its own snapshot is laid in at its place.
@MainActor
enum WindowSnapshot {
    static var target: URL? {
        let env = ProcessInfo.processInfo.environment
        guard env["MEETINGCAPTURE_E2E"] == "1", let path = env["MEETINGCAPTURE_SNAPSHOT"], path.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    static func scheduleIfAsked() {
        guard let target else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Task { @MainActor in
                await write(to: target)
                NSApp.terminate(nil)
            }
        }
    }

    private static func write(to url: URL) async {
        guard
            let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
            let view = window.contentView?.superview ?? window.contentView
        else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        for web in webViews(in: view) {
            guard let shot = try? await web.takeSnapshot(configuration: nil) else { continue }
            let frame = web.convert(web.bounds, to: view)
            image.lockFocusFlipped(view.isFlipped)
            shot.draw(in: frame)
            image.unlockFocus()
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
    }
}

/// Test-only: `MEETINGCAPTURE_MENUBAR_SNAPSHOT=<file.png>` (with `MEETINGCAPTURE_E2E=1`)
/// draws the extra's four states as they'd sit in a light and a dark menu bar, each with
/// its menu's lines, then quits. The real menu bar tints the template glyph itself; this
/// is the closest look without a screenshot of the screen.
@MainActor
enum MenuBarSnapshot {
    static func writeIfAsked(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard env["MEETINGCAPTURE_E2E"] == "1", let path = env["MEETINGCAPTURE_MENUBAR_SNAPSHOT"], path.hasPrefix("/")
        else { return }
        let states: [AppModel.Activity] = [
            .idle, .recording(elapsed: 724), .paused(elapsed: 724),
            .processing(step: 3, of: 5, name: "Labelling speakers"),
        ]
        let sheet = HStack(alignment: .top, spacing: 24) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach([false, true], id: \.self) { dark in
                        HStack(spacing: 4) {
                            Image(nsImage: MenuBarGlyph(state).image).renderingMode(.template)
                            if let text = MenuBarText.barText(state, showsText: false) { Text(text).monospacedDigit() }
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(dark ? Color.white : Color.black)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .frame(width: 200, alignment: .trailing)
                        .background(dark ? Color(white: 0.12) : Color(white: 0.92))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(MenuBarText.status(state)).fontWeight(.semibold)
                        Text("Source: Zoom").foregroundStyle(.secondary)
                        Divider()
                        ForEach(menuLines(state), id: \.self) { Text($0) }
                    }
                    .font(.system(size: 12))
                    .padding(10)
                    .frame(width: 200, alignment: .leading)
                    .background(Color(white: 0.97))
                    .foregroundStyle(.black)
                }
            }
        }
        .padding(20)
        .background(Color.white)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }

    private static func menuLines(_ state: AppModel.Activity) -> [String] {
        var recording = false
        var paused = false
        switch state {
        case .recording, .starting: recording = true
        case .paused: (recording, paused) = (true, true)
        default: break
        }
        let items = MenuBarItem.items(
            recording: recording, paused: paused, enabled: { _ in true }, lastReport: "Atlas sprint review")
        var lines: [String] = []
        for (i, item) in items.enumerated() {
            if i > 0, items[i - 1].isRecordingCommand, !item.isRecordingCommand { lines.append("—") }
            lines.append(item.title + (item.keys.map { "  " + $0 } ?? ""))
        }
        return lines
    }
}
