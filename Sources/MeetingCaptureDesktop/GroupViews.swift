import MeetingCaptureCore
import SwiftUI

// M5.2 (D-94): groups the user makes by hand. A report written in a group gets the
// group's earlier reports as context, never a transcript. Every change goes through
// `ReportGroups` in the core; these views only hold what's being typed.

/// Make a group with the selected report in it.
struct NewGroupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: LibraryEntry
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Group").font(.title2.weight(.semibold))
            TextField("Name, such as Weekly team meeting", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            Text(
                "A report written in a group gets the group's earlier reports as context: their titles, sections and items, never a transcript."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
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
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String: String] = [:]
    @State private var newName = ""
    @State private var error: String?
    @State private var deleting: ReportGroup?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Groups").font(.title2.weight(.semibold))
            Text(
                "A report written in a group gets the group's earlier reports as context, never a transcript. Put a report in a group from More › Group."
            )
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem = model.groupsProblem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
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
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 520)
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
        let global = ReportGroups.globalRedaction
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
            ForEach(ReportGroups.scenarioChoices, id: \.name) { choice in
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
