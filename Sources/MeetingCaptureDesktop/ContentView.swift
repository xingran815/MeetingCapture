import MeetingCaptureCore
import SwiftUI

/// Option 1 (D-91): a library sidebar, Record in the toolbar, the detail on the right.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showSpeakers = false

    var body: some View {
        @Bindable var model = model
        Group {
            if model.needsSetup {
                SetupView()
            } else {
                NavigationSplitView {
                    LibrarySidebar()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
                } detail: {
                    detail
                        .toolbar { toolbarItems }
                        .navigationTitle(title)
                        .navigationSubtitle(subtitle)
                }
            }
        }
        .sheet(isPresented: $showSpeakers) {
            if let entry = model.selectedEntry { SpeakersSheet(entry: entry) }
        }
        .alert(
            "Couldn't record",
            isPresented: Binding(get: { model.recordError != nil }, set: { if !$0 { model.recordError = nil } })
        ) {
            Button("OK") { model.recordError = nil }
        } message: {
            Text(model.recordError ?? "")
        }
    }

    @ViewBuilder private var detail: some View {
        if model.phase != .idle {
            RecordingView()
        } else if model.showsJob, model.job != nil {
            ProcessingView()
        } else if let entry = model.selectedEntry {
            EntryDetail(entry: entry)
        } else {
            IdleView()
        }
    }

    private var title: String {
        if model.phase != .idle { return "New recording" }
        if model.showsJob, let job = model.job { return job.title }
        if let e = model.selectedEntry { return e.topic ?? AppModel.title(for: e.base) }
        return "Recordings"
    }

    private var subtitle: String {
        if model.phase != .idle { return model.sourceLabel.isEmpty ? "Starting…" : model.sourceLabel }
        if let e = model.selectedEntry, model.selection != nil, !model.showsJob {
            var parts = [e.createdAt.formatted(date: .abbreviated, time: .shortened)]
            if let d = e.durationSeconds { parts.append("\(max(1, Int(d / 60))) min") }
            if let s = e.scenarioTitle { parts.append(s) }
            return parts.joined(separator: " · ")
        }
        return "\(model.entries.count) recordings"
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        if let entry = model.selectedEntry, model.phase == .idle, !model.showsJob {
            ToolbarItemGroup {
                Button {
                    showSpeakers = true
                } label: {
                    Label("Speakers", systemImage: "person.2")
                }
                .help("Rename or merge speakers")
                .disabled(!entry.hasTranscript)
                Menu {
                    Button("Transcribe Again") { model.transcribeAgain(entry) }
                        .disabled(entry.audioFiles.isEmpty || model.isProcessing)
                    Button("Write the Report Again") { model.writeReportAgain(entry) }
                        .disabled(!entry.hasTranscript || model.isProcessing)
                } label: {
                    Label("Re-run", systemImage: "arrow.clockwise")
                }
                .accessibilityLabel("Re-run")
                .help("Run a step again")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.audioFiles.first ?? entry.transcriptURL])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            switch model.phase {
            case .idle:
                Button {
                    model.startRecording()
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .help("Record (⌘R)")
            case .starting, .recording:
                Button {
                    model.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .help("Stop (⌘.)")
            }
        }
    }
}

struct LibrarySidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            if model.phase != .idle {
                Section {
                    HStack(spacing: 8) {
                        RecordingDot(paused: model.paused)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.paused ? "Paused" : "Recording").fontWeight(.semibold)
                            Text(Self.clock(model.elapsed)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            if let job = model.job, !job.finished {
                Section {
                    Button {
                        model.showsJob = true
                        model.selection = nil
                    } label: {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(job.title).lineLimit(1)
                                Text(job.steps.first { $0.status == .running }?.stage.title ?? "Working")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.entries) { entry in
                        LibraryRow(entry: entry).tag(entry.id)
                    }
                }
            }
        }
        .onChange(of: model.selection) { _, new in
            if new != nil { model.showsJob = false }
        }
        .overlay {
            if model.entries.isEmpty && model.phase == .idle && model.job == nil {
                ContentUnavailableView(
                    "No recordings yet", systemImage: "waveform", description: Text("Press Record to start."))
            }
        }
    }

    private var groups: [(title: String, entries: [LibraryEntry])] {
        let cal = Calendar.current
        let today = model.entries.filter { cal.isDateInToday($0.createdAt) }
        let earlier = model.entries.filter { !cal.isDateInToday($0.createdAt) }
        return [("Today", today), ("Earlier", earlier)].filter { !$0.entries.isEmpty }
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct LibraryRow: View {
    let entry: LibraryEntry

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.topic ?? AppModel.title(for: entry.base, short: true)).lineLimit(1)
                Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } icon: {
            Image(systemName: entry.isUnfinished ? "exclamationmark.circle" : "waveform")
                .foregroundStyle(entry.isUnfinished ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
        }
    }

    private var meta: String {
        var parts = [entry.createdAt.formatted(date: .omitted, time: .shortened)]
        if let d = entry.durationSeconds { parts.append("\(max(1, Int(d / 60))) min") }
        if entry.isUnfinished {
            parts.append("Unfinished")
        } else if let s = entry.scenarioTitle {
            parts.append(s)
        } else if !entry.hasTranscript {
            parts.append("Audio only")
        }
        return parts.joined(separator: " · ")
    }
}

struct RecordingDot: View {
    var paused: Bool
    var body: some View {
        Circle()
            .fill(paused ? Color.orange : Color.red)
            .frame(width: 9, height: 9)
            .accessibilityLabel(paused ? "Paused" : "Recording")
    }
}
