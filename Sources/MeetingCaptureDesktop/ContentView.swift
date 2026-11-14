import MeetingCaptureCore
import SwiftUI

/// D-91's layout in M7's Terminal Native look (D-101): a top bar with the path and the
/// report's keyed tools, the library tree on the left, the detail on the right, and a
/// status line at the bottom that says the state in words.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
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
                VStack(spacing: 0) {
                    TopBar(
                        title: title, tools: toolsEntry,
                        actions: TopBarActions(
                            speakers: { showSpeakers = true }, rename: { showRename = true },
                            edit: { showEdit = true }, writeAgain: writeAgain, newGroup: { showNewGroup = true },
                            groups: { showGroups = true }, trash: askTrash))
                    HStack(spacing: 0) {
                        LibrarySidebar().frame(width: 264)
                        Rectangle().fill(theme.line2).frame(width: 1)
                        detail
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .onChange(of: model.showsNotes) { _, open in
                                if !open { model.reportRevision += 1 }
                            }
                    }
                    StatusLine()
                }
                .ignoresSafeArea(edges: .top)
            }
        }
        .background(theme.ground)
        .sheet(isPresented: $showSpeakers) {
            if let entry = model.selectedEntry { SpeakersSheet(entry: entry).terminalThemed() }
        }
        .sheet(isPresented: $showRename) {
            if let entry = model.selectedEntry { RenameSheet(entry: entry).terminalThemed() }
        }
        .sheet(isPresented: $showEdit) {
            if let entry = model.selectedEntry { EditReportSheet(entry: entry).terminalThemed() }
        }
        .sheet(isPresented: $showNewGroup) {
            if let entry = model.selectedEntry { NewGroupSheet(entry: entry).terminalThemed() }
        }
        .sheet(isPresented: $showGroups) { GroupsSheet().terminalThemed() }
        .sheet(item: $trash) { request in
            TrashConfirmation(entry: request.entry, plan: request.plan).terminalThemed()
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

    /// The recording whose tools the top bar shows, if the report pane is showing.
    private var toolsEntry: LibraryEntry? {
        guard let entry = model.selectedEntry, model.phase == .idle, !model.showsJob else { return nil }
        return entry
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
        if model.phase != .idle { return "recording…" }
        if model.showsJob, let job = model.job { return job.title }
        if let e = model.selectedEntry { return e.topic ?? AppModel.title(for: e.base) }
        return "new recording"
    }
}

struct TopBarActions {
    var speakers: () -> Void
    var rename: () -> Void
    var edit: () -> Void
    var writeAgain: (LibraryEntry) -> Void
    var newGroup: () -> Void
    var groups: () -> Void
    var trash: (LibraryEntry) -> Void
}

/// `~/MeetingCapture/<title>` beside the window buttons, then the report's tools, each
/// with its key, like the mock-up's title bar. It also drags the window.
struct TopBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let title: String
    let tools: LibraryEntry?
    let actions: TopBarActions

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                Text("~/MeetingCapture/").foregroundStyle(theme.dim)
                Text(title).foregroundStyle(theme.text).fontWeight(.medium)
            }
            .lineLimit(1).truncationMode(.middle)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            if let entry = tools {
                toolRow(entry)
            } else if model.phase != .idle || model.showsJob {
                Button {
                    model.showsJob = false
                } label: {
                    tool("⌘O", "library")
                }
                .buttonStyle(.plain)
                .disabled(model.phase != .idle)
            }
        }
        .font(.mono(12))
        .padding(.leading, 84).padding(.trailing, 12)
        .frame(height: 38)
        .background(theme.ground2)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line2).frame(height: 1) }
        .gesture(WindowDragGesture())
    }

    @ViewBuilder private func toolRow(_ entry: LibraryEntry) -> some View {
        HStack(spacing: 4) {
            Menu {
                Button("Transcribe Again") { model.transcribeAgain(entry) }
                    .disabled(entry.audioFiles.isEmpty || model.isProcessing)
                Button("Write the Report Again") { actions.writeAgain(entry) }
                    .disabled(!entry.hasTranscript || model.isProcessing)
            } label: {
                tool("↻", "re-run ▾")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Re-run")
            .help("Run a step again")
            Button(action: actions.speakers) { tool("", "speakers") }
                .disabled(!entry.hasTranscript)
                .help("Rename or merge speakers")
            Button {
                model.showsNotes.toggle()
            } label: {
                tool("⌥⌘N", "notes")
            }
            .help("Show or hide notes")
            Menu {
                Button("Rename…", action: actions.rename)
                // Not during a re-run of this recording: the report is about to change.
                Button("Edit Report…", action: actions.edit).disabled(!entry.hasReport || model.isBusy(entry))
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
                    Button("New Group…", action: actions.newGroup)
                    Button("No Group") { model.notebook { try ReportGroups.remove(entry) } }
                        .disabled(entry.group == nil)
                    Divider()
                    Button("Manage Groups…", action: actions.groups)
                }
                .disabled(model.groupsProblem != nil)
            } label: {
                tool("", "more ▾")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More")
            .help("Rename, edit or group")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.audioFiles.first ?? entry.transcriptURL])
            } label: {
                tool("", "finder")
            }
            .help("Show in Finder")
            Button {
                actions.trash(entry)
            } label: {
                tool("⌘⌫", "trash", danger: true)
            }
            .disabled(entry.isUnfinished || model.isBusy(entry))
            .help("Move to Trash")
        }
        .buttonStyle(.plain)
    }

    /// `[⌘E] edit`: the key in the accent colour, the word after it.
    private func tool(_ key: String, _ word: String, danger: Bool = false) -> some View {
        HStack(spacing: 5) {
            if !key.isEmpty {
                Text(key).fontWeight(.bold).foregroundStyle(danger ? theme.rec : theme.accent)
            }
            Text(word).foregroundStyle(theme.text)
        }
        .font(.mono(11.5, .medium))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(theme.ground)
        .overlay(Rectangle().strokeBorder(theme.line, lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(word.replacingOccurrences(of: " ▾", with: ""))
    }
}

/// The vim-style line at the bottom: a mode block, the facts, the keys.
struct StatusLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Text(mode.text)
                .fontWeight(.heavy)
                .foregroundStyle(mode.fg)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(mode.bg)
            ForEach(facts, id: \.self) { fact in
                Text(fact).padding(.horizontal, 12).padding(.vertical, 4)
                    .overlay(alignment: .trailing) { Rectangle().fill(theme.line).frame(width: 1) }
            }
            Spacer(minLength: 8)
            Text(keys)
                .foregroundStyle(theme.dim)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .overlay(alignment: .leading) { Rectangle().fill(theme.line).frame(width: 1) }
        }
        .font(.mono(11.5))
        .lineLimit(1)
        .background(theme.ground2)
        .overlay(alignment: .top) { Rectangle().fill(theme.line2).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status")
    }

    private var mode: (text: String, fg: Color, bg: Color) {
        switch model.activity {
        case .idle: return ("READY", theme.onAccent, theme.accent)
        case .starting: return ("● STARTING", theme.onRec, theme.rec)
        case .recording: return ("● REC", theme.onRec, theme.rec)
        case .paused: return ("‖ PAUSED", theme.onAmber, theme.amber)
        case .processing(let step, let of, _): return ("WORK \(step)/\(of)", theme.ground, theme.text)
        }
    }

    private var facts: [String] {
        let source = model.settings.captureAllAudio ? "src: all audio" : "src: meeting apps (auto)"
        let route = "route: \(model.settings.primaryCLI)"
        switch model.activity {
        case .idle:
            return [source, route, "\(model.entries.count) recordings"]
        case .starting:
            return ["waiting for audio", route]
        case .recording(let t), .paused(let t):
            let mic = model.settings.micEnabled ? "mic ✓" : "mic off"
            let src = model.sourceLabel.isEmpty ? "sys …" : "sys ✓ \(model.sourceLabel)"
            return ["\(mic) · \(src)", MenuBarText.clock(t)]
        case .processing(_, _, let name):
            var line = name.lowercased()
            if let job = model.job, job.steps.contains(where: { $0.stage == .transcribing && $0.status == .running }) {
                line += " \(Int((job.fraction * 100).rounded()))%"
            }
            return [line, route]
        }
    }

    private var keys: String {
        switch model.phase {
        case .idle: return "⌘R rec · ⇧⌘P pause · ⌘. stop · ⌘, settings"
        case .starting, .recording: return model.paused ? "⇧⌘P resume · ⌘. stop" : "⇧⌘P pause · ⌘. stop"
        }
    }
}

/// The library as a tree: the record key on top, groups first (M5.2), then the
/// reports in no group, by day. ↑↓ (or j k) move, as in the terminal's picker.
struct LibrarySidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecordKey().padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 14)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let job = model.job, !job.finished {
                            JobRow(job: job, selected: model.showsJob)
                                .padding(.bottom, 10)
                        }
                        ForEach(sections, id: \.id) { section in
                            head(section.title, count: section.isGroup ? section.entries.count : nil)
                            ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                                LibraryRow(
                                    entry: entry,
                                    tree: section.isGroup ? (index == section.entries.count - 1 ? "└─ " : "├─ ") : nil,
                                    selected: model.selection == entry.id && !model.showsJob
                                ) {
                                    model.selection = entry.id
                                    focused = true
                                }
                                .id(entry.id)
                            }
                            Spacer().frame(height: 12)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .onChange(of: model.selection) { _, new in
                    if new != nil { model.showsJob = false }
                    if let new { withAnimation(nil) { proxy.scrollTo(new) } }
                }
            }
            Text("↑↓ j k move · ⌘R record")
                .font(.mono(11)).foregroundStyle(theme.faint)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(theme.ground2)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, "j", "k"]) { press in
            move(press.key == .upArrow || press.key == "k" ? -1 : 1)
            return .handled
        }
        .overlay {
            if model.entries.isEmpty && model.phase == .idle && model.job == nil {
                VStack(spacing: 6) {
                    Text("no recordings yet").foregroundStyle(theme.dim)
                    Text("press ⌘R to start").foregroundStyle(theme.faint)
                }
                .font(.mono(12))
            }
        }
    }

    private func head(_ title: String, count: Int?) -> some View {
        HStack {
            Text(count == nil ? title.uppercased() : "▾ " + title)
                .foregroundStyle(count == nil ? theme.faint : theme.text)
                .tracking(count == nil ? 1 : 0)
                .lineLimit(1)
            Spacer()
            if let count { Text("\(count)").foregroundStyle(theme.dim) }
        }
        .font(.mono(count == nil ? 11.5 : 12.5))
        .padding(.horizontal, 14).padding(.vertical, 3)
        .accessibilityAddTraits(.isHeader)
    }

    private func move(_ step: Int) {
        let all = sections.flatMap(\.entries)
        guard !all.isEmpty else { return }
        let now = all.firstIndex { $0.id == model.selection }
        let next = now.map { min(max($0 + step, 0), all.count - 1) } ?? 0
        model.selection = all[next].id
    }

    /// A group named "Today" mustn't share an id with the day section, so ids are kept apart.
    private var sections: [(id: String, title: String, isGroup: Bool, entries: [LibraryEntry])] {
        let cal = Calendar.current
        let grouped = model.groups.map { g in
            (id: "group:" + g.id, title: g.name, isGroup: true, entries: model.entries.filter { $0.group?.id == g.id })
        }
        let loose = model.entries.filter { $0.group == nil }
        let today = loose.filter { cal.isDateInToday($0.createdAt) }
        let earlier = loose.filter { !cal.isDateInToday($0.createdAt) }
        return (grouped + [("day:today", "Today", false, today), ("day:earlier", "Earlier", false, earlier)])
            .filter { !$0.entries.isEmpty }
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// `● RECORD ⌘R`, which turns into `■ STOP 12:04 ⌘.` or `‖ PAUSED 12:04 ⇧⌘P`.
struct RecordKey: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let (left, key, color, wash, command) = look
        Button {
            model.perform(command)
        } label: {
            HStack {
                Text(left)
                Spacer()
                Text(key)
            }
            .font(.mono(12.5, .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(wash)
            .overlay(Rectangle().strokeBorder(color, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canPerform(command))
        .accessibilityLabel(accessibility)
    }

    private var look: (String, String, Color, Color, RecordingCommand) {
        switch model.activity {
        case .idle: return ("● RECORD", "⌘R", theme.accent, .clear, .start)
        case .starting: return ("■ STOP  starting", "⌘.", theme.rec, theme.recWash, .stop)
        case .recording(let t): return ("■ STOP  \(MenuBarText.clock(t))", "⌘.", theme.rec, theme.recWash, .stop)
        case .paused(let t):
            return ("‖ PAUSED  \(MenuBarText.clock(t))", "⇧⌘P", theme.amber, theme.amberWash, .pauseResume)
        case .processing(let step, let of, _):
            return ("● RECORD  · \(step)/\(of) working", "⌘R", theme.accent, .clear, .start)
        }
    }

    private var accessibility: String {
        switch model.activity {
        case .idle, .processing: return "Record"
        case .starting, .recording: return "Stop recording"
        case .paused: return "Resume recording"
        }
    }
}

/// The job running after a call, in the tree.
struct JobRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let job: AppModel.Job
    let selected: Bool

    var body: some View {
        Button {
            model.showsJob = true
            model.selection = nil
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Spinner().foregroundStyle(theme.amber)
                    Text(job.title).lineLimit(1)
                }
                Text("   " + (job.steps.first { $0.status == .running }?.stage.title.lowercased() ?? "working"))
                    .font(.mono(11.5)).foregroundStyle(theme.dim).lineLimit(1)
            }
            .font(.mono(12.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 3)
            .background(selected ? theme.selection : .clear)
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(theme.accent).frame(width: 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Working on \(job.title)")
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
    @Environment(\.theme) private var theme
    let entry: LibraryEntry
    var tree: String?
    var selected: Bool
    var select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    HStack(spacing: 0) {
                        if let tree { Text(tree).foregroundStyle(theme.line2) }
                        if entry.isUnfinished { Text("! ").foregroundStyle(theme.amber) }
                        Text(entry.topic ?? AppModel.title(for: entry.base, short: true))
                    }
                    .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(Self.tag(entry)).font(.mono(11)).foregroundStyle(theme.dim)
                }
                .font(.mono(12.5))
                Text((tree == nil ? "" : "   ") + meta)
                    .font(.mono(11.5)).foregroundStyle(entry.isUnfinished ? theme.amber : theme.dim).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 3)
            .background(selected ? theme.selection : .clear)
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(theme.accent).frame(width: 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// A three-letter kind, like the terminal's: `mtg`, `1:1`, `int`, `lec`, `thr`, `gen`.
    static func tag(_ entry: LibraryEntry) -> String {
        if entry.isUnfinished { return "…" }
        guard let s = entry.scenarioTitle?.lowercased() else { return entry.hasTranscript ? "txt" : "wav" }
        if s.contains("one") || s.contains("1:1") || s.contains("1-on-1") { return "1:1" }
        if s.contains("meeting") { return "mtg" }
        if s.contains("interview") { return "int" }
        if s.contains("lecture") { return "lec" }
        if s.contains("therapy") { return "thr" }
        return "gen"
    }

    private var meta: String {
        var parts = [
            entry.createdAt.formatted(.dateTime.day().month(.abbreviated)) + " "
                + entry.createdAt.formatted(date: .omitted, time: .shortened)
        ]
        if let d = entry.durationSeconds { parts.append(MenuBarText.clock(d)) }
        if entry.isUnfinished {
            parts.append("unfinished")
        } else if !entry.hasTranscript {
            parts.append("audio only")
        } else if !entry.hasReport {
            parts.append("no report")
        }
        return parts.joined(separator: " · ")
    }
}
