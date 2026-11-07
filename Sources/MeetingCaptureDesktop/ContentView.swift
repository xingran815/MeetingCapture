import MeetingCaptureCore
import SwiftUI

/// Option 1 (D-91): a library sidebar, Record in the toolbar, the detail on the right.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showSpeakers = false
    @State private var showRename = false
    @State private var showEdit = false
    @State private var trash: TrashRequest?
    @State private var askKeepEdits = false
    @State private var showNewGroup = false
    @State private var showGroups = false

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
                        .onChange(of: model.showsNotes) { _, open in
                            if !open { model.reportRevision += 1 }
                        }
                        .toolbar { toolbarItems }
                        .navigationTitle(title)
                        .navigationSubtitle(subtitle)
                }
            }
        }
        .sheet(isPresented: $showSpeakers) {
            if let entry = model.selectedEntry { SpeakersSheet(entry: entry) }
        }
        .sheet(isPresented: $showRename) {
            if let entry = model.selectedEntry { RenameSheet(entry: entry) }
        }
        .sheet(isPresented: $showEdit) {
            if let entry = model.selectedEntry { EditReportSheet(entry: entry) }
        }
        .sheet(isPresented: $showNewGroup) {
            if let entry = model.selectedEntry { NewGroupSheet(entry: entry) }
        }
        .sheet(isPresented: $showGroups) { GroupsSheet() }
        .sheet(item: $trash) { request in
            TrashConfirmation(entry: request.entry, plan: request.plan)
        }
        .confirmationDialog(
            "Keep your edits?", isPresented: $askKeepEdits, titleVisibility: .visible, presenting: model.selectedEntry
        ) { entry in
            Button("Keep Edits") { model.writeReportAgain(entry, keepEdits: true) }
            Button("Drop Edits", role: .destructive) { model.writeReportAgain(entry, keepEdits: false) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(
                "The report is written again from the transcript. Kept edits apply only where the text they replaced is still there; the rest are listed so you can keep or drop them. Your title and notes stay either way."
            )
        }
        .alert(
            "Notebook",
            isPresented: Binding(
                get: { model.notebookMessage != nil }, set: { if !$0 { model.notebookMessage = nil } })
        ) {
            Button("OK") { model.notebookMessage = nil }
        } message: {
            Text(model.notebookMessage ?? "")
        }
        .focusedSceneValue(\.notebookActions, notebookActions)
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

    private func writeAgain(_ entry: LibraryEntry) {
        if entry.hasContentEdits { askKeepEdits = true } else { model.writeReportAgain(entry) }
    }

    private func askTrash(_ entry: LibraryEntry) {
        if let plan = model.trashPlan(entry) { trash = TrashRequest(entry: entry, plan: plan) }
    }

    private var notebookActions: NotebookActions? {
        guard let entry = model.selectedEntry, model.phase == .idle, !model.showsJob else { return nil }
        return NotebookActions(
            rename: { showRename = true },
            edit: entry.hasReport && !model.isBusy(entry) ? { showEdit = true } : nil,
            notes: { model.showsNotes.toggle() },
            writeAgain: { writeAgain(entry) },
            groups: { showGroups = true },
            trash: entry.isUnfinished || model.isBusy(entry) ? nil : { askTrash(entry) })
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
                    Button("Write the Report Again") { writeAgain(entry) }
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
                Menu {
                    Button("Rename…") { showRename = true }
                    // Not during a re-run of this recording: the report is about to change.
                    Button("Edit Report…") { showEdit = true }.disabled(!entry.hasReport || model.isBusy(entry))
                    Divider()
                    Menu("Group") {
                        ForEach(model.groups) { group in
                            Toggle(
                                group.name,
                                isOn: Binding(
                                    get: { entry.group?.id == group.id },
                                    set: { on in
                                        model.notebook {
                                            if on {
                                                try ReportGroups.add(entry, to: group)
                                            } else {
                                                try ReportGroups.remove(entry)
                                            }
                                        }
                                    }))
                        }
                        if !model.groups.isEmpty { Divider() }
                        Button("New Group…") { showNewGroup = true }
                        Button("No Group") { model.notebook { try ReportGroups.remove(entry) } }
                            .disabled(entry.group == nil)
                        Divider()
                        Button("Manage Groups…") { showGroups = true }
                    }
                    .disabled(model.groupsProblem != nil)
                    Divider()
                    Button("Move to Trash…", role: .destructive) { askTrash(entry) }
                        .disabled(entry.isUnfinished || model.isBusy(entry))
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("Rename, edit, group or delete")
                Button {
                    model.showsNotes.toggle()
                } label: {
                    Label("Notes", systemImage: "note.text")
                }
                .help("Show or hide notes (⌥⌘N)")
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
            ForEach(groups, id: \.id) { group in
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

    /// The user's groups first (M5.2), each with its reports, newest first; then the
    /// reports in no group, by day. A report shows once.
    /// A group named "Today" mustn't share an id with the day section, so ids are kept apart.
    private var groups: [(id: String, title: String, entries: [LibraryEntry])] {
        let cal = Calendar.current
        let grouped = model.groups.map { g in
            (id: "group:" + g.id, title: g.name, entries: model.entries.filter { $0.group?.id == g.id })
        }
        let loose = model.entries.filter { $0.group == nil }
        let today = loose.filter { cal.isDateInToday($0.createdAt) }
        let earlier = loose.filter { !cal.isDateInToday($0.createdAt) }
        return (grouped + [("day:today", "Today", today), ("day:earlier", "Earlier", earlier)])
            .filter { !$0.entries.isEmpty }
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct TrashRequest: Identifiable {
    let entry: LibraryEntry
    let plan: TrashPlan
    var id: String { entry.id }
}

/// The selected recording's notebook actions, for the menu bar's commands.
struct NotebookActions {
    var rename: () -> Void
    var edit: (() -> Void)?
    var notes: () -> Void
    var writeAgain: () -> Void
    var groups: () -> Void
    var trash: (() -> Void)?
}

struct NotebookActionsKey: FocusedValueKey {
    typealias Value = NotebookActions
}

extension FocusedValues {
    var notebookActions: NotebookActions? {
        get { self[NotebookActionsKey.self] }
        set { self[NotebookActionsKey.self] = newValue }
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
