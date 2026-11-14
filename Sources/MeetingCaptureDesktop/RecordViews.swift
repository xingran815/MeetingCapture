import MeetingCaptureCore
import SwiftUI

/// Ready to record: the big key, what will be heard, and the keys.
struct IdleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHead("new recording")
                HStack(alignment: .center, spacing: 28) {
                    Button {
                        model.perform(.start)
                    } label: {
                        VStack(spacing: 6) {
                            Text("● RECORD").font(.mono(18, .heavy))
                            Text("press ⌘R").font(.mono(12, .medium)).foregroundStyle(theme.dim)
                        }
                        .foregroundStyle(theme.accent)
                        .frame(width: 150, height: 150)
                        .overlay(Rectangle().strokeBorder(theme.accent, lineWidth: 2))
                        .padding(6)
                        .overlay(Rectangle().strokeBorder(theme.line2, lineWidth: 1))
                        .shadow(color: theme.isDark ? theme.accent.opacity(0.25) : .clear, radius: 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Start recording")
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canPerform(.start))

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("✓").foregroundStyle(theme.accent)
                            Text("READY").fontWeight(.bold)
                            Text(permissions).foregroundStyle(theme.dim)
                        }
                        .font(.mono(14))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("source")
                                Text(model.settings.captureAllAudio ? "(all audio)" : "(auto-detect)")
                                    .foregroundStyle(theme.dim)
                            }
                            if model.settings.captureAllAudio {
                                Text("  ● everything this Mac plays").foregroundStyle(theme.accent)
                            } else {
                                ForEach(MeetingAppChoice.all) { app in
                                    let on = model.settings.enabledMeetingAppIDs.contains(app.id)
                                    Text("  \(on ? "●" : "○") \(app.label)")
                                        .foregroundStyle(on ? theme.accent : theme.faint)
                                        .accessibilityLabel("\(app.label), \(on ? "on" : "off")")
                                }
                            }
                            Text("  \(model.settings.micEnabled ? "●" : "○") your microphone")
                                .foregroundStyle(model.settings.micEnabled ? theme.accent : theme.faint)
                        }
                        .font(.mono(12.5))
                        HStack(spacing: 10) {
                            Button {
                                model.perform(.start)
                            } label: {
                                KeyedLabel("● Record", keys: "⌘R", inverted: true)
                            }
                            .buttonStyle(.terminal(.go))
                            .disabled(!model.canPerform(.start))
                            Button {
                                openSettings()
                            } label: {
                                KeyedLabel("Change source", keys: "⌘,")
                            }
                            .buttonStyle(.terminal)
                        }
                    }
                }
                Text(
                    "Audio and transcripts stay on this Mac. Saved in 30-minute parts as it goes; echo comes off after the call, so the meeting app keeps your mic."
                )
                .font(.mono(12)).foregroundStyle(theme.dim)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(theme.line2).frame(width: 2) }
                .frame(maxWidth: 620, alignment: .leading)
            }
            .padding(.horizontal, 30).padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var permissions: String {
        let screen = model.screenAllowed ? "system audio ✓" : "system audio ✗"
        let mic = model.micStatus == .authorized ? "microphone ✓" : "microphone ✗"
        return "\(screen) · \(mic)"
    }
}

/// Recording and paused: the state in words, the clock, D-91's one calm waveform in
/// block style, who is talking, and the two keys.
struct RecordingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                stateLine
                Text(Self.longClock(model.elapsed))
                    .font(.mono(72, .heavy))
                    .monospacedDigit()
                    .padding(.top, 14).padding(.bottom, 4)
                    .accessibilityLabel("Elapsed \(MenuBarText.clock(model.elapsed))")
                Text("saved in 30-minute parts · safety cap 8 h · two tracks: you and the call")
                    .font(.mono(12)).foregroundStyle(theme.dim)

                TerminalBox("level") {
                    VStack(alignment: .leading, spacing: 10) {
                        WaveformView(levels: model.levelHistory, paused: model.paused)
                            .frame(height: 64)
                        HStack(spacing: 22) {
                            Speaking(label: "you", active: model.micActive && !model.paused)
                            Speaking(
                                label: model.sourceLabel.isEmpty ? "the call" : "the call · \(model.sourceLabel)",
                                active: model.callActive && !model.paused)
                        }
                        .font(.mono(12))
                    }
                }
                .padding(.top, 24)

                HStack(spacing: 10) {
                    if model.paused {
                        Button {
                            model.perform(.pauseResume)
                        } label: {
                            KeyedLabel("▶ Resume", keys: "⇧⌘P", inverted: true)
                        }
                        .buttonStyle(.terminal(.go))
                    } else {
                        Button {
                            model.perform(.pauseResume)
                        } label: {
                            KeyedLabel("‖ Pause", keys: "⇧⌘P")
                        }
                        .buttonStyle(.terminal)
                        .disabled(!model.canPerform(.pauseResume))
                    }
                    Button {
                        model.perform(.stop)
                    } label: {
                        KeyedLabel("■ Stop & write report", keys: "⌘.")
                    }
                    .buttonStyle(.terminal(.stop))
                }
                .padding(.vertical, 20)

                Text(
                    model.paused
                        ? "Nothing is saved while paused. The audio stays one piece; the pause simply isn't in it."
                        : "A crash keeps every finished part. Echo is removed after the call, never live."
                )
                .font(.mono(12)).foregroundStyle(theme.dim)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(theme.line2).frame(width: 2) }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 30).padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var stateLine: some View {
        HStack(spacing: 10) {
            switch model.activity {
            case .starting:
                Text("● STARTING").foregroundStyle(theme.rec)
                Text("waiting for the call's audio").foregroundStyle(theme.dim).fontWeight(.regular)
            case .paused:
                Text("‖ PAUSED").foregroundStyle(theme.amber)
                Text("press ⇧⌘P to go on").foregroundStyle(theme.dim).fontWeight(.regular)
            default:
                Text("● REC").foregroundStyle(theme.rec)
                BlockCursor(color: theme.rec)
                Text(model.sourceLabel.isEmpty ? "two tracks" : "\(model.sourceLabel) · two tracks")
                    .foregroundStyle(theme.dim).fontWeight(.regular)
            }
        }
        .font(.mono(14, .bold))
        .accessibilityElement(children: .combine)
    }

    static func longClock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    private struct Speaking: View {
        @Environment(\.theme) private var theme
        let label: String
        let active: Bool
        var body: some View {
            HStack(spacing: 6) {
                Text(active ? "●" : "○").foregroundStyle(active ? theme.accent : theme.faint)
                Text(label).foregroundStyle(active ? theme.text : theme.dim)
                Text(active ? "talking" : "quiet").foregroundStyle(active ? theme.accent : theme.faint)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// D-91's balanced waveform in the terminal style: one calm row of square bars for the
/// whole call, older audio fading, the newest few in the recording red while live,
/// faint when paused. The paused state is also said in words beside it.
struct WaveformView: View {
    @Environment(\.theme) private var theme
    static let barCount = 60
    let levels: [Double]
    let paused: Bool

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            guard count > 0 else { return }
            let gap: CGFloat = 3
            let width = max(2, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            // Bars snap to an 8-step grid, like block characters ▁▂▃▄▅▆▇█.
            let step = size.height / 8
            for (i, level) in levels.enumerated() {
                let h = max(step / 2, (CGFloat(level) * 8).rounded(.up) * step)
                let x = CGFloat(i) * (width + gap)
                let rect = CGRect(x: x, y: size.height - h, width: width, height: h)
                let live = i >= count - 6
                let fade = 0.35 + 0.65 * Double(i) / Double(count)
                let color: Color = paused ? theme.faint.opacity(0.5) : (live ? theme.rec : theme.accent.opacity(fade))
                context.fill(Path(rect), with: .color(color))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Recording level")
        .accessibilityValue(paused ? "paused" : "live")
    }
}

/// The steps after a call, as a checklist: `[✓] [–] [⠋] [ ]`.
struct ProcessingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        if let job = model.job {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        if job.finished {
                            Text(job.failure == nil ? "✓ DONE" : "! STOPPED")
                                .foregroundStyle(job.failure == nil ? theme.accent : theme.rec)
                        } else {
                            Spinner().foregroundStyle(theme.amber)
                            Text(heading(job))
                        }
                        Text(job.title).foregroundStyle(theme.dim).fontWeight(.regular)
                    }
                    .font(.mono(14, .bold))
                    Text(job.finished ? (job.failure ?? "Everything finished.") : explanation(job))
                        .font(.mono(12.5))
                        .foregroundStyle(job.failure == nil ? theme.dim : theme.rec)
                        .padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)

                    TerminalBox("steps") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(job.steps) { step in
                                StepRow(step: step, job: job)
                            }
                        }
                    }
                    .padding(.top, 22)

                    if let bar = progress(job) {
                        Text(bar)
                            .font(.mono(13)).foregroundStyle(theme.accent)
                            .padding(.top, 12)
                            .accessibilityLabel("Progress \(Int((currentFraction(job) ?? 0) * 100)) percent")
                    }

                    if !job.finished {
                        HStack(spacing: 10) {
                            Button {
                                model.cancelJob()
                            } label: {
                                KeyedLabel("✕ Cancel")
                            }
                            .buttonStyle(.terminal)
                            Button {
                                model.perform(.start)
                            } label: {
                                KeyedLabel("● New recording", keys: "⌘R")
                            }
                            .buttonStyle(.terminal)
                            .disabled(!model.canPerform(.start))
                        }
                        .padding(.vertical, 18)
                    }

                    if model.waitingCount > 0 {
                        Text(
                            model.waitingCount == 1
                                ? "-- 1 more is waiting and starts after this one."
                                : "-- \(model.waitingCount) more are waiting and start after this one."
                        )
                        .font(.mono(12.5)).foregroundStyle(theme.dim)
                        .padding(.top, 8)
                    }
                    if !job.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(job.notes, id: \.self) { note in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("!").foregroundStyle(theme.amber).fontWeight(.bold)
                                    Text(note).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .font(.mono(12.5))
                        .padding(.top, 12)
                    }
                    Text(
                        "Audio and transcription stay on this Mac. Only redacted text goes to your \(model.settings.primaryCLI) CLI; names and emails become tokens like <EMAIL_1> and are put back here."
                    )
                    .font(.mono(12)).foregroundStyle(theme.dim)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(theme.line2).frame(width: 2) }
                    .padding(.top, 14)
                }
                .frame(maxWidth: 660, alignment: .leading)
                .padding(.horizontal, 30).padding(.vertical, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func currentFraction(_ job: AppModel.Job) -> Double? {
        guard let running = job.steps.first(where: { $0.status == .running }) else { return nil }
        if running.stage == .transcribing { return job.fraction }
        if running.stage == .writingReport, let current = job.reportStep {
            return current.fraction + 0.5 / Double(ReportStep.allCases.count)
        }
        return nil
    }

    private func progress(_ job: AppModel.Job) -> String? {
        currentFraction(job).map { Blocks.progress($0) }
    }

    private func heading(_ job: AppModel.Job) -> String {
        switch job.kind {
        case .newRecording: return "PROCESSING"
        case .transcript: return "TRANSCRIBING AGAIN"
        case .report: return "WRITING THE REPORT"
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
        @Environment(\.theme) private var theme
        let step: AppModel.StepState
        let job: AppModel.Job

        private var detail: String {
            if step.stage == .writingReport, step.status == .running, let current = job.reportStep {
                let via = job.reportBackend.map { " · \($0)" } ?? ""
                return "\(current.title) (\(current.rawValue) of \(ReportStep.allCases.count))\(via)"
            }
            if !step.detail.isEmpty { return step.detail }
            switch step.status {
            case .waiting: return "waiting"
            case .skipped: return "skipped"
            case .done: return "done"
            case .running:
                return step.stage == .transcribing ? "\(Int((job.fraction * 100).rounded()))%" : "working"
            }
        }

        private var note: String? {
            switch step.stage {
            case .savingAudio: return "the WAV goes only once the M4A is checked"
            case .writingReport: return "redacted first, put back on this Mac"
            default: return nil
            }
        }

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                box
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.stage.title)
                        .fontWeight(step.status == .running ? .bold : .regular)
                        .foregroundStyle(step.status == .waiting || step.status == .skipped ? theme.dim : theme.text)
                    if let note, step.status != .skipped {
                        Text(note).font(.mono(11.5)).foregroundStyle(theme.faint)
                    }
                }
                Spacer(minLength: 10)
                Text(detail).font(.mono(12)).foregroundStyle(theme.dim).lineLimit(1)
            }
            .font(.mono(13.5))
            .accessibilityElement(children: .combine)
        }

        @ViewBuilder private var box: some View {
            HStack(spacing: 0) {
                Text("[")
                switch step.status {
                case .done: Text("✓").foregroundStyle(theme.accent)
                case .running: Spinner().foregroundStyle(theme.amber)
                case .waiting: Text(" ")
                case .skipped: Text("–")
                }
                Text("]")
            }
            .foregroundStyle(theme.faint)
            .font(.mono(13.5, .bold))
            .accessibilityLabel(
                {
                    switch step.status {
                    case .done: return "done"
                    case .running: return "running"
                    case .waiting: return "waiting"
                    case .skipped: return "skipped"
                    }
                }())
        }
    }
}
