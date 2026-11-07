import AVFoundation
import AppKit
import CoreGraphics
import MeetingCaptureCore
import Observation

/// The app's state. Every action calls into `MeetingCaptureCore`; nothing here decides
/// how audio, transcripts or reports are made.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
    }

    struct StepState: Identifiable, Equatable {
        let stage: ProcessingStage
        var status: Status = .waiting
        var detail = ""
        var id: ProcessingStage { stage }
        enum Status { case waiting, running, done, skipped }
    }

    /// One after-call run, shown while it works and kept until the next one.
    struct Job: Equatable {
        enum Kind { case newRecording, transcript, report }
        var kind: Kind
        var base: URL
        var title: String
        var steps: [StepState]
        /// Transcription of the current file, 0…1.
        var fraction: Double = 0
        /// Where the report is, while it's being written.
        var reportStep: ReportStep?
        /// Which CLI or API writes the report, such as "Claude CLI".
        var reportBackend: String?
        var finished = false
        var failure: String?
        var notes: [String] = []
    }

    /// A job asked for while another runs. It waits its turn; a finished recording is
    /// never dropped. From the M5 review.
    private struct Waiting {
        let base: URL
        let start: () -> Void
    }

    // Settings and library
    var settings = AppSettings.load()
    /// The settings as last loaded or saved, so a save writes only what changed.
    private var savedSettings = AppSettings.load()
    var entries: [LibraryEntry] = []
    var selection: LibraryEntry.ID?
    var showsJob = false
    /// Bumped when the user's layer changes (title, edits, notes), so the page is drawn again.
    var reportRevision = 0
    /// The notes pane beside the report.
    var showsNotes = false
    /// Something to tell the user after a notebook action, such as a page that was left.
    var notebookMessage: String?

    // Recording
    var phase: Phase = .idle
    var paused = false
    var elapsed: Double = 0
    var sourceLabel = ""
    /// Recent loudness, oldest first, 0…1, for the waveform. One sample every 0.1 s.
    var levelHistory: [Double] = Array(repeating: 0, count: WaveformView.barCount)
    var micActive = false
    var callActive = false
    var recordError: String?

    // After the call
    var job: Job?
    private var jobTask: Task<Void, Never>?
    private var waiting: [Waiting] = []
    var waitingCount: Int { waiting.count }
    /// Set when the user quits during a recording: runs once the files are closed.
    private var quitWhenStopped: (() -> Void)?

    // First run
    var needsSetup: Bool
    var micStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    var screenAllowed = CGPreflightScreenCaptureAccess()

    private var recorder: Recorder?
    private var meterTimer: Timer?

    init() {
        let s = AppSettings.load()
        needsSetup =
            !ModelStore.hasWhisperModel(s.whisperModel) || !ModelStore.hasSpeakerModel
            || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized || !CGPreflightScreenCaptureAccess()
        Library.cleanOldAudio(settings: s)
        reload()
    }

    var selectedEntry: LibraryEntry? { entries.first { $0.id == selection } }

    func reload() {
        entries = Library.entries(in: settings.resolvedOutputDirectory, busy: busyBases)
    }

    /// Recordings this app is still working on, so the library doesn't offer them as unfinished.
    private var busyBases: Set<String> {
        var bases = Set(waiting.map { $0.base.lastPathComponent })
        if let recorder { bases.insert(recorder.base.lastPathComponent) }
        if let job, !job.finished { bases.insert(job.base.lastPathComponent) }
        return bases
    }

    // MARK: Recording

    func startRecording() {
        guard phase == .idle else { return }
        recordError = nil
        let recorder: Recorder
        do { recorder = try Recorder.prepare() } catch {
            recordError = "Couldn't prepare the recording: \(error.localizedDescription)"
            return
        }
        self.recorder = recorder
        phase = .starting
        paused = false
        elapsed = 0
        levelHistory = Array(repeating: 0, count: WaveformView.barCount)
        selection = nil
        showsJob = false
        startMeters()
        Task {
            do {
                let parts = try await recorder.start()
                if let quit = quitWhenStopped {
                    // The files are closed; the next launch offers them as unfinished.
                    quit()
                    return
                }
                finishedRecording(parts: parts, base: recorder.base)
            } catch {
                stopMeters()
                phase = .idle
                self.recorder = nil
                if let quit = quitWhenStopped {
                    quit()
                    return
                }
                recordError = "Recording failed: \(error.localizedDescription)"
                reload()
            }
        }
    }

    func togglePause() {
        guard phase == .recording, let recorder else { return }
        paused = recorder.togglePause()
    }

    func stopRecording() {
        recorder?.stop()
    }

    /// Quitting: a recording is stopped and its files closed first, then `done` runs.
    /// Work after the call is left; the audio is kept and offered again next time.
    func stopEverythingForQuit(_ done: @escaping () -> Void) {
        jobTask?.cancel()
        waiting.removeAll()
        if phase != .idle, recorder != nil {
            quitWhenStopped = done
            recorder?.stop()
        } else {
            done()
        }
    }

    /// What the quit question should say, or nil when quitting loses nothing.
    var quitWarning: String? {
        if phase != .idle {
            return
                "A recording is in progress. It stops now, the audio so far is kept, and the app offers to finish it next time."
        }
        if isProcessing {
            return
                "Work on a recording is still running. It stops now; what's saved stays, and you can run the step again from the library."
        }
        return nil
    }

    private func startMeters() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleMeters() }
        }
    }

    private func stopMeters() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func sampleMeters() {
        guard let recorder else { return }
        if recorder.isLive, phase == .starting { phase = .recording }
        elapsed = recorder.elapsedSeconds
        sourceLabel = recorder.sourceLabel
        paused = recorder.isPaused
        guard !paused else { return }
        let (mic, system) = recorder.levels
        // Speech sits roughly between -50 and -10 dBFS; map that range to 0…1.
        func scaled(_ rms: Float) -> Double {
            let db = 20 * log10(max(Double(rms), 1e-6))
            return min(1, max(0, (db + 50) / 40))
        }
        micActive = scaled(mic) > 0.35
        callActive = scaled(system) > 0.35
        levelHistory.removeFirst()
        levelHistory.append(max(scaled(mic), scaled(system)))
    }

    private func finishedRecording(parts: [URL], base: URL) {
        stopMeters()
        phase = .idle
        recorder = nil
        process(parts: parts, base: base)
    }

    // MARK: After the call

    var isProcessing: Bool { job.map { !$0.finished } ?? false }

    func process(parts: [URL], base: URL) {
        let processor = MeetingProcessor()
        startJob(kind: .newRecording, base: base, title: Self.title(for: base), stages: processor.plannedStages) {
            onEvent in
            await processor.finish(parts: parts, base: base, onEvent: onEvent)
        }
    }

    func transcribeAgain(_ entry: LibraryEntry) {
        guard let first = entry.audioFiles.first else { return }
        startJob(
            kind: .transcript, base: entry.base, title: entry.topic ?? Self.title(for: entry.base),
            stages: [.removingEcho, .transcribing, .labellingSpeakers]
        ) { onEvent in
            await MeetingProcessor().transcribe(audio: first, onEvent: onEvent)
        }
    }

    func writeReportAgain(_ entry: LibraryEntry, keepEdits: Bool = true) {
        startJob(
            kind: .report, base: entry.base, title: entry.topic ?? Self.title(for: entry.base), stages: [.writingReport]
        ) {
            onEvent in
            await MeetingProcessor().summarize(
                transcriptAt: entry.transcriptURL, keepEdits: keepEdits, onEvent: onEvent)
        }
    }

    // MARK: Notebook (M5.1)

    /// Runs a change to the user's layer, then redraws. Errors go to `notebookMessage`.
    /// `redraw` false (notes while typing) saves without reloading the page, which would
    /// lose the reader's place; the page catches up when the notes close.
    func notebook(redraw: Bool = true, _ change: () throws -> Void) {
        do { try change() } catch { notebookMessage = error.localizedDescription }
        guard redraw else { return }
        reportRevision += 1
        reload()
    }

    func trashPlan(_ entry: LibraryEntry) -> TrashPlan? {
        do { return try entry.trashPlan(busy: busyBases) } catch {
            notebookMessage = error.localizedDescription
            return nil
        }
    }

    func moveToTrash(_ entry: LibraryEntry, confirmed: TrashPlan) {
        do {
            let done = try entry.moveToTrash(confirmed: confirmed, busy: busyBases)
            if selection == entry.id { selection = nil }
            if !done.notes.isEmpty { notebookMessage = done.notes.joined(separator: "\n\n") }
        } catch {
            notebookMessage = error.localizedDescription
        }
        reload()
    }

    func isBusy(_ entry: LibraryEntry) -> Bool { busyBases.contains(entry.base.lastPathComponent) }

    func processUnfinished(_ entry: LibraryEntry) {
        let parts = entry.unfinishedParts
        guard !parts.isEmpty else { return }
        process(parts: parts, base: entry.base)
    }

    func cancelJob() {
        jobTask?.cancel()
    }

    private func startJob(
        kind: Job.Kind, base: URL, title: String, stages: [ProcessingStage],
        run: @escaping (@escaping (MeetingProcessor.Event) -> Void) async -> MeetingProcessor.Result
    ) {
        if isProcessing {
            waiting.append(
                Waiting(base: base) { [weak self] in
                    self?.startJob(kind: kind, base: base, title: title, stages: stages, run: run)
                })
            reload()
            return
        }
        job = Job(kind: kind, base: base, title: title, steps: stages.map { StepState(stage: $0) })
        showsJob = true
        selection = nil
        jobTask = Task {
            let result = await run { event in
                Task { @MainActor [weak self] in self?.apply(event) }
            }
            finish(result)
        }
    }

    private func apply(_ event: MeetingProcessor.Event) {
        guard var job else { return }
        switch event {
        case .stage(let stage, let part, let parts):
            guard let index = job.steps.firstIndex(where: { $0.stage == stage }) else { return }
            for i in job.steps.indices where i < index && job.steps[i].status != .done {
                job.steps[i].status = job.steps[i].status == .running ? .done : .skipped
            }
            for i in job.steps.indices where i != index && job.steps[i].status == .running {
                job.steps[i].status = .done
            }
            job.steps[index].status = .running
            job.steps[index].detail = parts > 1 ? "Part \(part) of \(parts)" : ""
            if stage == .transcribing { job.fraction = 0 }
        case .progress(let fraction):
            job.fraction = fraction
        case .reportStep(let step):
            job.reportStep = step
        case .reportBackend(let label):
            job.reportBackend = label
        case .transcribed:
            break
        }
        self.job = job
    }

    private func finish(_ result: MeetingProcessor.Result) {
        guard var job else { return }
        job.finished = true
        job.notes = result.notes
        job.failure = result.failure
        for i in job.steps.indices {
            if job.steps[i].stage == result.failedStage {
                job.steps[i].status = .waiting
            } else if job.steps[i].status == .running {
                job.steps[i].status = .done
            } else if job.steps[i].status == .waiting, result.failure == nil {
                job.steps[i].status = .skipped
            }
        }
        self.job = job
        if !waiting.isEmpty {
            waiting.removeFirst().start()
            reload()
            return
        }
        reload()
        if result.failure == nil, result.reportJSON != nil {
            showsJob = false
            selection = job.base.path
        }
    }

    // MARK: Settings

    var settingsError: String?

    func saveSettings() {
        guard settings != savedSettings else { return }
        do {
            try settings.save(changedFrom: savedSettings)
            savedSettings = AppSettings.load()
            settings = savedSettings
            settingsError = nil
            reload()
        } catch {
            settingsError = error.localizedDescription
        }
    }

    /// The terminal may have changed settings while the app was in the background.
    func refreshFromDisk() {
        refreshPermissions()
        guard settings == savedSettings else { return }
        let fresh = AppSettings.load()
        guard fresh != savedSettings else { return }
        settings = fresh
        savedSettings = fresh
        reload()
    }

    // MARK: Permissions

    func refreshPermissions() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        screenAllowed = CGPreflightScreenCaptureAccess()
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in self.refreshPermissions() }
        }
    }

    /// The system asks once; after that, the switch is in System Settings.
    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
        }
        refreshPermissions()
    }

    static func title(for base: URL, short: Bool = false) -> String { RecordingName.title(for: base, short: short) }
}
