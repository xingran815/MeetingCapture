import MeetingCaptureCore
import SwiftUI

@main
struct MeetingCaptureDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @FocusedValue(\.notebookActions) private var notebook
    /// D-102: on by default, and the user can hide it in Settings.
    @AppStorage(MenuBarPreference.key) private var showsMenuBarExtra = true

    var body: some Scene {
        Window("MeetingCapture", id: "main") {
            ContentView()
                .environment(model)
                .terminalThemed()
                .frame(minWidth: 900, minHeight: 580)
                .task { delegate.model = model }
        }
        // The top bar draws the path where the title was (D-101); the window buttons stay.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1160, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Recording") {
                Button(model.phase == .idle ? "Record" : "Recording…") { model.perform(.start) }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.canPerform(.start))
                Button(model.paused ? "Resume" : "Pause") { model.perform(.pauseResume) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!model.canPerform(.pauseResume))
                Button("Stop") { model.perform(.stop) }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.canPerform(.stop))
                Divider()
                Button("Transcribe Again") { if let e = model.selectedEntry { model.transcribeAgain(e) } }
                    .disabled(model.selectedEntry?.audioFiles.isEmpty ?? true || model.isProcessing)
                Button("Write the Report Again") { notebook?.writeAgain() }
                    .disabled(!(model.selectedEntry?.hasTranscript ?? false) || model.isProcessing || notebook == nil)
                Divider()
                Button("Rename…") { notebook?.rename() }.disabled(notebook == nil)
                Button("Edit Report…") { notebook?.edit?() }.disabled(notebook?.edit == nil)
                Button("Show Notes") { notebook?.notes() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(notebook == nil)
                Button("Manage Groups…") { notebook?.groups() }.disabled(notebook == nil)
                Button("Move to Trash…") { notebook?.trash?() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(notebook?.trash == nil)
            }
            CommandGroup(after: .sidebar) {
                Button("Reload Library") { model.reload() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .terminalThemed()
        }

        MenuBarExtra(isInserted: $showsMenuBarExtra) {
            MenuBarMenu().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Opened from Finder, the app has a short PATH; the summary CLIs live in the user's folders.
        LaunchEnvironment.addUserToolFolders()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.refreshFromDisk()
    }

    /// ⌘Q during a recording would cut it off; ask first, then close the files before
    /// quitting. From the M5 review.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, let warning = model.quitWarning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit MeetingCapture?"
        alert.informativeText = warning
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Quit")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        // Only a recording needs its files closed first; work after the call just stops.
        // A reply must come after `.terminateLater` is returned, so it's never sent from
        // here directly. From the M5 re-check.
        guard model.phase != .idle else {
            model.stopEverythingForQuit {}
            return .terminateNow
        }
        model.stopEverythingForQuit {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
