import MeetingCaptureCore
import SwiftUI

// M5.2 (D-94): groups the user makes by hand. A report written in a group gets the
// group's earlier reports as context, never a transcript. Every change goes through
// `ReportGroups` in the core; these views only hold what's being typed.

/// Make a group with the selected report in it.
struct NewGroupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let entry: LibraryEntry
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHead("new group")
            TerminalField(prompt: "Name, such as Weekly team meeting", text: $name, submit: save)
            Text(
                "A report written in a group gets the group's earlier reports as context: their titles, sections and items, never a transcript."
            )
            .font(.mono(11.5)).foregroundStyle(theme.dim).fixedSize(horizontal: false, vertical: true)
            if let error { Text("! " + error).foregroundStyle(theme.rec).font(.mono(12.5)) }
            SheetButtons(cancel: { dismiss() }, confirm: ("Create", save))
        }
        .padding(20)
        .frame(width: 460)
        .background(theme.ground)
    }

    private func save() {
        do {
            let group = try ReportGroups.create(named: name, in: model.outputDirectory)
            try ReportGroups.add(entry, to: group)
            model.notebook {}
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Every group: rename, the redaction switch, a pinned scenario, delete.
struct GroupsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String: String] = [:]
    @State private var newName = ""
    @State private var error: String?
    @State private var deleting: ReportGroup?
    /// Read once, not on every redraw. From the M5.2 review.
    @State private var global = true
    @State private var scenarios: [(name: String, title: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHead("groups")
            Text(
                "A report written in a group gets the group's earlier reports as context, never a transcript. Put a report in a group from More › Group."
            )
            .font(.mono(12.5)).foregroundStyle(theme.dim).fixedSize(horizontal: false, vertical: true)
            if let problem = model.groupsProblem {
                Text("! " + problem).font(.mono(12.5)).foregroundStyle(theme.amber)
            }
            Form {
                ForEach(model.groups) { group in
                    Section {
                        row(group)
                    }
                }
                Section {
                    HStack {
                        TextField("New group", text: $newName).onSubmit(create)
                        Button("Add") { create() }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            if let error { Text("! " + error).foregroundStyle(theme.rec).font(.mono(12.5)) }
            SheetButtons(cancel: nil, confirm: ("Done", { dismiss() }))
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 520)
        .background(theme.ground)
        .onAppear {
            global = ReportGroups.globalRedaction
            scenarios = ReportGroups.scenarioChoices
        }
        .confirmationDialog(
            "Delete this group?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { group in
            Button("Delete Group", role: .destructive) {
                change { try ReportGroups.delete(group, in: model.outputDirectory) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Only the group goes. Its reports stay as they are.")
        }
    }

    @ViewBuilder private func row(_ group: ReportGroup) -> some View {
        HStack {
            TextField(
                "Name", text: Binding(get: { names[group.id] ?? group.name }, set: { names[group.id] = $0 })
            )
            .onSubmit { rename(group) }
            Button("Rename") { rename(group) }.disabled((names[group.id] ?? group.name) == group.name)
        }
        LabeledContent("Reports", value: "\(group.members.count)")
        Toggle(
            "Redact the context",
            isOn: Binding(
                get: { global && group.redactContext },
                set: { on in change { try ReportGroups.setRedactContext(group, on, in: model.outputDirectory) } })
        )
        .disabled(!global)
        .help(
            global
                ? "On: names and numbers in earlier reports are redacted with the transcript. Off: they go as written."
                : "Redaction is off in Settings, so nothing is redacted.")
        Picker(
            "Scenario",
            selection: Binding(
                get: { group.scenario ?? "" },
                set: { name in
                    change { try ReportGroups.setScenario(group, name.isEmpty ? nil : name, in: model.outputDirectory) }
                })
        ) {
            Text("Classify each report").tag("")
            ForEach(scenarios, id: \.name) { choice in
                Text(choice.title).tag(choice.name)
            }
        }
        Button("Delete Group…", role: .destructive) { deleting = group }
    }

    private func change(_ f: () throws -> Void) {
        do {
            try f()
            error = nil
        } catch { self.error = error.localizedDescription }
        model.notebook {}
    }

    private func rename(_ group: ReportGroup) {
        guard let name = names[group.id], name != group.name else { return }
        change { try ReportGroups.rename(group, to: name, in: model.outputDirectory) }
        names[group.id] = nil
    }

    private func create() {
        change { try ReportGroups.create(named: newName, in: model.outputDirectory) }
        if error == nil { newName = "" }
    }
}
