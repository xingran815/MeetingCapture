import AVFoundation
import MeetingCaptureCore
import SwiftUI

/// Settings (⌘,). The terminal has every one of these, plus finer ones (spec 05's table).
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Recording", systemImage: "mic") { RecordingSettings() }
            Tab("Summaries", systemImage: "doc.text") { SummarySettings() }
            Tab("Terminal", systemImage: "terminal") { TerminalSettings() }
        }
        .frame(width: 560, height: 420)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    private let retention = [7, 14, 30, 90, 365, 0]

    var body: some View {
        @Bindable var model = model
        Form {
            LabeledContent("Save recordings in") {
                HStack {
                    Text(model.settings.outputDirectory).lineLimit(1).truncationMode(.middle).foregroundStyle(
                        .secondary)
                    Button("Choose…") { chooseFolder() }
                }
            }
            Picker("Keep audio for", selection: $model.settings.audioRetentionDays) {
                ForEach(retentionChoices, id: \.self) { days in
                    Text(days == 0 ? "Forever" : "\(days) days").tag(days)
                }
            }
            Text("Transcripts and reports are always kept.").font(.caption).foregroundStyle(.secondary)
            Picker("Speech model", selection: $model.settings.whisperModel) {
                ForEach(modelChoices, id: \.id) { m in
                    Text(
                        "\(m.title), about \(m.approxMB >= 1000 ? String(format: "%.1f GB", Double(m.approxMB) / 1000) : "\(m.approxMB) MB")"
                    ).tag(m.id)
                }
            }
            if !ModelStore.hasWhisperModel(model.settings.whisperModel) {
                Text("This model isn't downloaded yet; it downloads before the next transcript.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error = model.settingsError { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
    }

    /// The listed days, plus whatever the terminal saved if it's another value.
    private var retentionChoices: [Int] {
        retention.contains(model.settings.audioRetentionDays)
            ? retention : retention + [model.settings.audioRetentionDays]
    }

    private var modelChoices: [WhisperModelChoice] {
        let id = model.settings.whisperModel
        return WhisperModelCatalog.choice(for: id) == nil
            ? WhisperModelCatalog.models + [WhisperModelChoice(id: id, title: id, blurb: "custom", approxMB: 0)]
            : WhisperModelCatalog.models
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.settings.resolvedOutputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            let home = NSHomeDirectory()
            model.settings.outputDirectory =
                url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
        }
    }
}

private struct RecordingSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Audio source", selection: $model.settings.captureAllAudio) {
                Text("Meeting apps, detected automatically").tag(false)
                Text("All system audio").tag(true)
            }
            .pickerStyle(.radioGroup)
            Section("Meeting apps") {
                ForEach(MeetingAppChoice.all) { app in
                    Toggle(
                        app.label,
                        isOn: Binding(
                            get: { model.settings.enabledMeetingAppIDs.contains(app.id) },
                            set: { on in
                                if on {
                                    model.settings.enabledMeetingAppIDs.append(app.id)
                                } else {
                                    model.settings.enabledMeetingAppIDs.removeAll { $0 == app.id }
                                }
                            }))
                }
            }
            .disabled(model.settings.captureAllAudio)
            Toggle("Record my microphone", isOn: $model.settings.micEnabled)
        }
        .formStyle(.grouped)
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
    }
}

private struct SummarySettings: View {
    @Environment(AppModel.self) private var model
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Write reports with", selection: $model.settings.primaryCLI) {
                ForEach(SummaryService.cliChoices, id: \.id) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.segmented)
            Text("Uses your subscription through its command-line tool. If it's full, the other one takes over.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Used today") {
                let usage = SummaryService.usageToday(cli: model.settings.primaryCLI)
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: Double(min(usage.count, usage.cap)), total: Double(max(usage.cap, 1)))
                        .frame(width: 180)
                    Text("\(usage.count) of \(usage.cap) calls").font(.caption).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            LabeledContent("Connection") {
                HStack {
                    if testing { ProgressView().controlSize(.small) }
                    Text(testResult ?? "Not tested yet").foregroundStyle(.secondary).lineLimit(2)
                    Button("Test") { test() }.disabled(testing)
                }
            }
            Toggle("Hide names, emails and numbers before sending", isOn: $model.settings.redactionEnabled)
            Text("They're replaced with tokens like <EMAIL_1> and put back on this Mac.").font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
        .onChange(of: model.settings.primaryCLI) { _, _ in testResult = nil }
    }

    private func test() {
        testing = true
        let cli = model.settings.primaryCLI
        Task {
            let problem = await SummaryService.connectionProblem(cli: cli)
            testResult = problem ?? "Ready, on your subscription."
            testing = false
        }
    }
}

private struct TerminalSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("More settings live in the terminal").font(.headline)
            Text("The terminal can do everything this app does, plus finer control. Run this, then choose Settings:")
                .foregroundStyle(.secondary)
            HStack {
                Text("meetingcapture").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("meetingcapture", forType: .string)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
            VStack(alignment: .leading, spacing: 4) {
                Text("• Models per step, and reasoning depth")
                Text("• API profiles (DeepSeek, OpenAI, Anthropic, Ollama, custom)")
                Text("• Force a report type, pin the language")
                Text("• Echo removal, recording part length, daily call cap")
            }
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
    }
}

/// First run: the two models, then the two permissions, each explained before macOS asks.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 1
    @State private var whisper = 0.0
    @State private var speaker = 0.0
    @State private var downloading = false
    @State private var failure: String?
    @State private var task: Task<Void, Never>?
    @State private var asked = false

    private var modelsReady: Bool {
        ModelStore.hasWhisperModel(model.settings.whisperModel) && ModelStore.hasSpeakerModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "waveform").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 13).fill(Color.red.gradient))
                VStack(alignment: .leading) {
                    Text(step == 1 ? "Get the speech models" : "Let it hear the call").font(.title.weight(.bold))
                    Text("Step \(step) of 2 · Audio and transcripts stay on this Mac").foregroundStyle(.secondary)
                }
            }
            if step == 1 { models } else { permissions }
        }
        .padding(40)
        .frame(maxWidth: 640, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if modelsReady { step = 2 } }
    }

    private var choice: WhisperModelChoice? { WhisperModelCatalog.choice(for: model.settings.whisperModel) }

    @ViewBuilder private var models: some View {
        Text(
            "MeetingCapture turns speech into text on this Mac. It needs two models first. They're downloaded once, not bundled with the app."
        )
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                ModelRow(
                    title: "Speech model", subtitle: choice?.title ?? model.settings.whisperModel,
                    sizeMB: choice?.approxMB,
                    fraction: ModelStore.hasWhisperModel(model.settings.whisperModel) ? 1 : whisper)
                Divider()
                ModelRow(
                    title: "Speaker model", subtitle: "tells voices apart on the call's side",
                    sizeMB: ModelStore.speakerModelApproxMB, fraction: ModelStore.hasSpeakerModel ? 1 : speaker)
            }
            .padding(8)
        }
        if let failure { Text(failure).foregroundStyle(.red) }
        Text(
            downloading
                ? "If you quit, the download picks up where it stopped next time."
                : "Sizes are about; the download says how far it is as it goes."
        )
        .font(.caption).foregroundStyle(.secondary)
        Spacer()
        HStack {
            if downloading {
                Button("Cancel") { task?.cancel() }
            }
            Spacer()
            if modelsReady {
                Button("Continue") { step = 2 }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Button(downloading ? "Downloading…" : (whisper > 0 ? "Resume Download" : "Download")) { download() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(downloading)
            }
        }
    }

    @ViewBuilder private var permissions: some View {
        Text("macOS asks you about two permissions. Here is why, before it asks.").foregroundStyle(.secondary)
        GroupBox {
            VStack(spacing: 12) {
                PermissionRow(
                    icon: "mic", title: "Microphone", detail: "To record your side of the call",
                    allowed: model.micStatus == .authorized,
                    action: model.micStatus == .notDetermined
                        ? ("Allow…", { model.requestMicrophone() })
                        : ("Open System Settings", { openPane("Privacy_Microphone") }))
                Divider()
                PermissionRow(
                    icon: "rectangle.on.rectangle", title: "Screen & System Audio Recording",
                    detail: "To hear the call's audio. Nothing on screen is recorded.",
                    allowed: model.screenAllowed,
                    action: (
                        asked ? "Check Again" : "Allow…",
                        {
                            if asked {
                                model.refreshPermissions()
                            } else {
                                asked = true
                                model.requestScreenRecording()
                            }
                        }
                    ))
            }
            .padding(8)
        }
        Text(
            asked && !model.screenAllowed
                ? "Turn on MeetingCapture in Privacy & Security › Screen & System Audio Recording, then press Check Again. macOS may ask you to reopen the app."
                : "You can change both later in System Settings › Privacy & Security."
        )
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Spacer()
        HStack {
            Button("Back") { step = 1 }
            Spacer()
            Button("Later") { model.needsSetup = false }
            Button("Start Using MeetingCapture") { model.needsSetup = false }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!(model.micStatus == .authorized && model.screenAllowed))
        }
    }

    private func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func download() {
        failure = nil
        downloading = true
        let id = model.settings.whisperModel
        task = Task {
            do {
                if !ModelStore.hasWhisperModel(id) {
                    try await ModelStore.downloadWhisper(id) { f in Task { @MainActor in whisper = f } }
                }
                if !ModelStore.hasSpeakerModel {
                    try await ModelStore.downloadSpeakerModel { f in Task { @MainActor in speaker = f } }
                }
                downloading = false
                if modelsReady { step = 2 }
            } catch is CancellationError {
                downloading = false
                failure = "Cancelled. What was downloaded is kept, so starting again is quick."
            } catch {
                downloading = false
                failure =
                    Task.isCancelled
                    ? "Cancelled. What was downloaded is kept, so starting again is quick."
                    : "The download stopped: \(error.localizedDescription)"
            }
        }
    }

    private struct ModelRow: View {
        let title: String
        let subtitle: String
        let sizeMB: Int?
        let fraction: Double

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).fontWeight(.semibold)
                    Text(subtitle).foregroundStyle(.secondary)
                    Spacer()
                    Text(status).foregroundStyle(.secondary).monospacedDigit()
                }
                ProgressView(value: fraction)
            }
        }

        private var status: String {
            if fraction >= 1 { return "Ready" }
            guard let sizeMB, sizeMB > 0 else { return "\(Int(fraction * 100))%" }
            return fraction > 0 ? "\(Int(fraction * 100))% of about \(sizeMB) MB" : "about \(sizeMB) MB"
        }
    }

    private struct PermissionRow: View {
        let icon: String
        let title: String
        let detail: String
        let allowed: Bool
        let action: (String, () -> Void)

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 28)
                VStack(alignment: .leading) {
                    Text(title).fontWeight(.semibold)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if allowed {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button(action.0, action: action.1)
                }
            }
        }
    }
}
