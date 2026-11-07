import MeetingCaptureCore
import SwiftUI

struct IdleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 18) {
            Button {
                model.startRecording()
            } label: {
                Circle().fill(.white).frame(width: 30, height: 30)
                    .frame(width: 84, height: 84)
                    .background(Circle().fill(Color.red))
                    .overlay(Circle().stroke(Color.red.opacity(0.18), lineWidth: 12).padding(-6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start recording")
            .keyboardShortcut(.defaultAction)

            Text("Ready to record").font(.title.weight(.bold))
            Text(sourceText)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack(spacing: 8) {
                Text(model.settings.captureAllAudio ? "All system audio" : "Meeting apps, detected")
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                Text(model.settings.micEnabled ? "Microphone on" : "Microphone off")
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
                Button("Change…") { openSettings() }.buttonStyle(.link)
            }
            .font(.callout)
            Text("Record ⌘R · Pause ⇧⌘P · Stop ⌘.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourceText: String {
        let apps = MeetingAppChoice.all.filter { model.settings.enabledMeetingAppIDs.contains($0.id) }.map(\.label)
        let what =
            model.settings.captureAllAudio
            ? "Records everything the Mac plays"
            : "Records the call's audio from \(ListFormatter.localizedString(byJoining: apps.isEmpty ? ["any app"] : apps))"
        let mic = model.settings.micEnabled ? ", plus your microphone" : ""
        return "\(what)\(mic). Audio and transcripts stay on this Mac."
    }
}

struct RecordingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 10) {
                RecordingDot(paused: model.paused)
                Text(model.phase == .starting ? "Starting…" : (model.paused ? "Paused" : "Recording"))
                    .font(.headline)
                    .foregroundStyle(model.paused ? .orange : .red)
            }
            Text(LibrarySidebar.clock(model.elapsed))
                .font(.system(size: 64, weight: .light))
                .monospacedDigit()
            VStack(spacing: 12) {
                WaveformView(levels: model.levelHistory, paused: model.paused)
                    .frame(width: 480, height: 72)
                HStack(spacing: 18) {
                    Speaking(label: "You", active: model.micActive && !model.paused)
                    Speaking(
                        label: model.sourceLabel.isEmpty ? "Others" : "Others on \(model.sourceLabel)",
                        active: model.callActive && !model.paused)
                }
                .font(.caption)
            }
            HStack(spacing: 10) {
                Button(model.paused ? "Resume" : "Pause") { model.togglePause() }
                    .controlSize(.large)
                    .disabled(model.phase != .recording)
                Button("Stop") { model.stopRecording() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            Text("Saved in 30-minute parts as it goes, so a crash keeps what was recorded.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct Speaking: View {
        let label: String
        let active: Bool
        var body: some View {
            HStack(spacing: 6) {
                Circle().fill(active ? Color.red : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                Text(label).foregroundStyle(active ? .primary : .secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(active ? "talking" : "quiet")
        }
    }
}

/// D-91's balanced waveform: one calm row of thin rounded bars for the whole call,
/// older audio fading, the newest few red while live, grey when paused.
struct WaveformView: View {
    static let barCount = 60
    let levels: [Double]
    let paused: Bool

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            guard count > 0 else { return }
            let gap: CGFloat = 3
            let width = max(2, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            for (i, level) in levels.enumerated() {
                let h = max(3, CGFloat(level) * size.height)
                let x = CGFloat(i) * (width + gap)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: width, height: h)
                let live = i >= count - 6
                let fade = 0.45 + 0.55 * Double(i) / Double(count)
                let color: Color = paused ? .secondary.opacity(0.35) : (live ? .red : .secondary.opacity(fade))
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(color))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Recording level")
    }
}

struct ProcessingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let job = model.job {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(heading(job)).font(.title.weight(.bold))
                    Text(job.finished ? (job.failure ?? "Everything finished.") : explanation(job))
                        .foregroundStyle(job.failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                        .padding(.bottom, 14)
                    GroupBox {
                        VStack(spacing: 0) {
                            ForEach(Array(job.steps.enumerated()), id: \.element.id) { index, step in
                                if index > 0 { Divider() }
                                StepRow(
                                    step: step, job: job,
                                    cancel: job.finished ? nil : { model.cancelJob() })
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    .frame(maxWidth: 620)
                    if model.waitingCount > 0 {
                        Label(
                            model.waitingCount == 1
                                ? "1 more is waiting and starts after this one."
                                : "\(model.waitingCount) more are waiting and start after this one.",
                            systemImage: "clock"
                        )
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.top, 12)
                    }
                    if !job.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(job.notes, id: \.self) {
                                Label($0, systemImage: "exclamationmark.triangle").font(.callout)
                            }
                        }
                        .padding(.top, 12)
                        .frame(maxWidth: 620, alignment: .leading)
                    }
                }
                .padding(.horizontal, 60).padding(.vertical, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func heading(_ job: AppModel.Job) -> String {
        if job.finished { return job.failure == nil ? "Done" : "Stopped" }
        switch job.kind {
        case .newRecording: return "Making the report"
        case .transcript: return "Transcribing again"
        case .report: return "Writing the report"
        }
    }

    private func explanation(_ job: AppModel.Job) -> String {
        switch job.kind {
        case .newRecording:
            return "The audio is saved already. You can record again or close this window; the work goes on."
        case .transcript:
            return "The audio stays as it is. The new transcript replaces the old one when it's done."
        case .report:
            return "The transcript is saved. Only its text is sent, with names and emails hidden. "
                + "This takes a minute or two; you can keep using the app."
        }
    }

    private struct StepRow: View {
        let step: AppModel.StepState
        let job: AppModel.Job
        let cancel: (() -> Void)?

        private var detail: String {
            if step.stage == .writingReport, step.status == .running, let current = job.reportStep {
                let via = job.reportBackend.map { " · \($0)" } ?? ""
                return "\(current.title) (\(current.rawValue) of \(ReportStep.allCases.count))\(via)"
            }
            return step.detail
        }

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                icon.frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(step.stage.title).fontWeight(.semibold)
                            .foregroundStyle(step.status == .waiting || step.status == .skipped ? .secondary : .primary)
                        if !detail.isEmpty { Text("· \(detail)").foregroundStyle(.secondary) }
                    }
                    if step.status == .running {
                        if step.stage == .transcribing {
                            ProgressView(value: min(max(job.fraction, 0), 1))
                        } else if step.stage == .writingReport, let current = job.reportStep {
                            ProgressView(value: current.fraction + 0.5 / Double(ReportStep.allCases.count))
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                    }
                    if step.stage == .savingAudio {
                        Text("The WAV is removed only once the M4A is checked").font(.caption).foregroundStyle(
                            .secondary)
                    } else if step.stage == .writingReport {
                        Text("Names and emails are hidden first, then put back on this Mac").font(.caption)
                            .foregroundStyle(
                                .secondary)
                    }
                }
                Spacer()
                if step.status == .running, let cancel { Button("Cancel", action: cancel) }
            }
            .padding(.vertical, 10)
        }

        @ViewBuilder private var icon: some View {
            switch step.status {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .running: ProgressView().controlSize(.small)
            case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
            case .skipped: Image(systemName: "minus.circle").foregroundStyle(.tertiary)
            }
        }
    }
}
