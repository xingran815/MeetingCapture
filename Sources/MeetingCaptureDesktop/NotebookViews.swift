import MeetingCaptureCore
import SwiftUI

// M5.1 (D-93): rename, notes, editing (desktop only) and delete. Every change goes
// through `LibraryEntry` in the core; these views only hold what's being typed.

/// The notes beside the report, edited in place and saved a moment after typing stops.
struct NotesInspector: View {
    @Environment(AppModel.self) private var model
    let entry: LibraryEntry
    @State private var text = ""
    @State private var sendToLLM = false
    @State private var saveTask: Task<Void, Never>?
    /// The recording whose notes are in the editor, which may differ from `entry` for a
    /// moment after the selection changes.
    @State private var loaded: LibraryEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notes").font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Notes")
                .onChange(of: text) { _, new in scheduleSave(new) }
            Toggle("Use notes when writing the report", isOn: $sendToLLM)
                .onChange(of: sendToLLM) { _, on in
                    guard on != entry.sendsNotesToLLM else { return }
                    model.notebook { try entry.setSendNotesToLLM(on) }
                }
            Text(
                "Notes stay on this Mac unless this is on. When it is, they go to the model with the transcript, redacted the same way."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .onAppear(perform: load)
        .onChange(of: entry.id) { _, _ in
            flush()
            load()
        }
        .onDisappear(perform: flush)
        // ⌘Q may not run onDisappear. From the M5.1 deep review.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            flush()
        }
    }

    private func load() {
        text = entry.notes()
        sendToLLM = entry.sendsNotesToLLM
        loaded = entry
    }

    private func scheduleSave(_ new: String) {
        saveTask?.cancel()
        let target = entry
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, loaded?.id == target.id else { return }
            save(new, to: target)
        }
    }

    /// Saves what's typed to the recording it was typed for, when leaving the notes or
    /// switching recordings.
    private func flush() {
        saveTask?.cancel()
        // A recording just moved to the Trash keeps nothing: saving would put the notes
        // back as an orphan. From the M5.1 deep review.
        guard let loaded, loaded.stillExists, text != loaded.notes() else { return }
        save(text, to: loaded)
    }

    private func save(_ value: String, to target: LibraryEntry) {
        guard value != target.notes() else { return }
        model.notebook(redraw: false) { try target.saveNotes(value) }
    }
}

/// Says when edits no longer match the report, and lets the user keep or drop them.
struct StaleEditsBanner: View {
    @Environment(AppModel.self) private var model
    let entry: LibraryEntry
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(
                count == 1
                    ? "1 edit no longer matches the report, so it isn't shown."
                    : "\(count) edits no longer match the report, so they aren't shown."
            )
            Spacer()
            Button("Keep") { model.notebook { try entry.resolveStaleEdits(keep: true) } }
                .help("Put your edits back over the text that's there now")
            Button("Drop") { model.notebook { try entry.resolveStaleEdits(keep: false) } }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }
}

/// Edit the report's text (desktop only). Each field shows the page's text now; a field
/// set back to the model's words loses its edit.
struct EditReportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: LibraryEntry
    @State private var fields: [EditableField] = []
    @State private var values: [String: String] = [:]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Report").font(.title2.weight(.semibold))
            Text(
                "Your edits are kept beside the report. If the report is written again, an edit applies only where the text it replaced is still there."
            )
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                ForEach(sections, id: \.self) { section in
                    Section(fields.first { $0.section == section }?.sectionTitle ?? section) {
                        ForEach(fields.filter { $0.section == section }) { field in
                            row(field)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 620)
        .onAppear {
            fields = entry.editableFields()
            values = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0.current) })
        }
    }

    private var sections: [String] {
        var seen: [String] = []
        for f in fields where !seen.contains(f.section) { seen.append(f.section) }
        return seen
    }

    @ViewBuilder private func row(_ field: EditableField) -> some View {
        let binding = Binding(get: { values[field.id] ?? field.current }, set: { values[field.id] = $0 })
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(field.field == .text ? "Item \(field.item + 1)" : field.field.label)
                    .font(.caption).foregroundStyle(.secondary)
                if binding.wrappedValue != field.modelText {
                    Text("Edited").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                    Spacer()
                    Button("Reset") { values[field.id] = field.modelText }
                        .buttonStyle(.link).font(.caption)
                }
            }
            if field.isMultiline {
                TextField("", text: binding, axis: .vertical).lineLimit(1...8).labelsHidden()
            } else {
                TextField("", text: binding).labelsHidden()
            }
        }
    }

    private func save() {
        let changes = values.filter { id, value in fields.first { $0.id == id }?.current != value }
        do {
            try entry.saveEdits(changes, readFrom: fields)
            model.notebook {}
            dismiss()
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

/// Rename: an empty title goes back to the report's own topic.
struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: LibraryEntry
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename").font(.title2.weight(.semibold))
            TextField("Title", text: $title).textFieldStyle(.roundedBorder).onSubmit(save)
            Text("Leave it empty to use the report's own title.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { title = entry.userTitle ?? entry.topic ?? "" }
    }

    private func save() {
        model.notebook { try entry.rename(to: title) }
        dismiss()
    }
}

/// What a delete moves, asked before anything moves.
struct TrashConfirmation: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: LibraryEntry
    let plan: TrashPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move to the Trash?").font(.title2.weight(.semibold))
            Text(
                "These \(plan.files.count) files of this recording go to the Trash. Nothing is deleted for good; you can put them back from the Trash."
            )
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(plan.files, id: \.self) { url in
                        Text(url.lastPathComponent).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            ForEach(plan.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) {
                    dismiss()
                    model.moveToTrash(entry, confirmed: plan)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
