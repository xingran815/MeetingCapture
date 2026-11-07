import MeetingCaptureCore
import SwiftUI

@main
struct MeetingCaptureDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("MeetingCapture", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1160, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Recording") {
                Button(model.phase == .idle ? "Record" : "Recording…") { model.startRecording() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.phase != .idle || model.needsSetup)
                Button(model.paused ? "Resume" : "Pause") { model.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.phase != .recording)
                Button("Stop") { model.stopRecording() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.phase == .idle)
                Divider()
                Button("Transcribe Again") { if let e = model.selectedEntry { model.transcribeAgain(e) } }
                    .disabled(model.selectedEntry?.audioFiles.isEmpty ?? true || model.isProcessing)
                Button("Write the Report Again") { if let e = model.selectedEntry { model.writeReportAgain(e) } }
                    .disabled(!(model.selectedEntry?.hasTranscript ?? false) || model.isProcessing)
            }
            CommandGroup(after: .sidebar) {
                Button("Reload Library") { model.reload() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Opened from Finder, the app has a short PATH; the summary CLIs live in the user's folders.
        LaunchEnvironment.addUserToolFolders()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
