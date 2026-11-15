import AVFoundation
import AppKit
import CoreGraphics
import MeetingCaptureCore
import Observation

/// What the app needs from a recording. `Recorder` is the real one; tests and the
/// E2E screenshots give a stand-in, so nothing but `Recorder` touches capture.
@MainActor
protocol RecordingSession: AnyObject {
    var base: URL { get }
    func start() async throws -> [URL]
    @discardableResult func togglePause() -> Bool
    /// Safe before capture is live: the real one holds the stop until then (`RecordingStopper.arm()`).
    func stop()
    /// Stop and mark the recording thrown away; `start()` still returns its parts.
    func abort()
    /// Moves an aborted recording's files to the Trash; returns what moved.
    @discardableResult func discard(parts: [URL]) throws -> [URL]
    var isLive: Bool { get }
    var elapsedSeconds: Double { get }
    var isPaused: Bool { get }
    var levels: (mic: Float, system: Float) { get }
    var sourceLabel: String { get }
}

extension Recorder: RecordingSession {}

/// The recording actions. The toolbar, the Recording menu's keys and the menu bar
/// extra all go through `AppModel.perform`, so they can't drift apart (spec 07).
/// `abort` stops and moves the recording to the Trash, after the user confirms.
enum RecordingCommand: CaseIterable {
    case start, pauseResume, stop, abort
}

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
    /// The output folder's groups (M5.2). Empty when `groups.json` can't be read; the
    /// reason is in `groupsProblem`.
    var groups: [ReportGroup] = []
    var groupsProblem: String?
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

    private var recorder: RecordingSession?
    private var meterTimer: Timer?
    /// Makes the session `startRecording` uses. Only tests and the E2E demo change it.
    var makeSession: () throws -> RecordingSession = { try Recorder.prepare() }
    /// Asks before an abort throws the recording away. Tests replace it.
    var confirmAbort: () -> Bool = AppModel.askToAbort
    /// Set once the user confirmed an abort, until the files are in the Trash.
    private(set) var aborting = false
    /// Runs after a recording ends with its parts. Tests replace it so nothing is transcribed.
    var afterRecording: ((_ parts: [URL], _ base: URL) -> Void)?

    init() {
        let s = AppSettings.load()
        needsSetup =
            !ModelStore.hasWhisperModel(s.whisperModel) || !ModelStore.hasSpeakerModel
            || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized || !CGPreflightScreenCaptureAccess()
        Library.cleanOldAudio(settings: s)
        reload()
        DemoState.applyIfAsked(to: self)
    }

    var selectedEntry: LibraryEntry? { entries.first { $0.id == selection } }

    func reload() {
        entries = Library.entries(in: settings.resolvedOutputDirectory, busy: busyBases)
        do {
            groups = try ReportGroups.all(in: settings.resolvedOutputDirectory)
            groupsProblem = nil
        } catch {
            groups = []
            groupsProblem = error.localizedDescription
        }
    }

    var outputDirectory: URL { settings.resolvedOutputDirectory }

    /// Recordings this app is still working on, so the library doesn't offer them as unfinished.
    private var busyBases: Set<String> {
        var bases = Set(waiting.map { $0.base.lastPathComponent })
        if let recorder { bases.insert(recorder.base.lastPathComponent) }
        if let job, !job.finished { bases.insert(job.base.lastPathComponent) }
        return bases
    }

    // MARK: Recording

    func canPerform(_ command: RecordingCommand) -> Bool {
        switch command {
        case .start: return phase == .idle && !needsSetup
        case .pauseResume: return phase == .recording
        case .stop, .abort: return phase != .idle && !aborting
        }
    }

    func perform(_ command: RecordingCommand) {
        guard canPerform(command) else { return }
        switch command {
        case .start: startRecording()
        case .pauseResume: togglePause()
        case .stop: stopRecording()
        case .abort: abortRecording()
        }
    }

    /// What the app is doing, for the menu bar extra and the status line. A recording
    /// wins over work after an earlier call, which goes on underneath.
    enum Activity: Equatable {
        case idle
        case starting
        case recording(elapsed: Double)
        case paused(elapsed: Double)
        /// Step `step` of `of`, such as 3 of 6, with the running step's name.
        case processing(step: Int, of: Int, name: String)
    }

    var activity: Activity {
        switch phase {
        case .starting: return .starting
        case .recording: return paused ? .paused(elapsed: elapsed) : .recording(elapsed: elapsed)
        case .idle:
            guard let job, !job.finished else { return .idle }
            let index =
                job.steps.firstIndex { $0.status == .running }
                ?? job.steps.firstIndex { $0.status == .waiting } ?? 0
            return .processing(step: index + 1, of: job.steps.count, name: job.steps[index].stage.title)
        }
    }

    /// The newest recording with a report, for the menu bar's "last report".
    var lastReport: LibraryEntry? {
        entries.filter(\.hasReport).max { $0.createdAt < $1.createdAt }
    }

    func startRecording() {
        guard phase == .idle else { return }
        recordError = nil
        let recorder: RecordingSession
        do { recorder = try makeSession() } catch {
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
                if aborting {
                    discarded(recorder, parts: parts)
                    if let quit = quitWhenStopped { quit() }
                    return
                }
                if let quit = quitWhenStopped {
                    // The files are closed; the next launch offers them as unfinished.
                    quit()
                    return
                }
                finishedRecording(parts: parts, base: recorder.base)
            } catch {
                if aborting {
                    discarded(recorder, parts: [])
                    if let quit = quitWhenStopped { quit() }
                    return
                }
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

    /// True when the window shows the recording page: a recording is on and the user
    /// hasn't picked a report or the job to read meanwhile.
    var showsRecording: Bool { phase != .idle && selection == nil && !showsJob }

    /// Back to the recording page from a report read during the recording.
    func showRecordingPage() {
        selection = nil
        showsJob = false
    }

    /// The session being recorded, for tests.
    var currentSession: RecordingSession? { recorder }

    func stopRecording() {
        recorder?.stop()
    }

    /// Stops the recording and moves it to the Trash, once the user says so. Nothing is
    /// transcribed. Before capture is live the stop is held, as with Stop.
    func abortRecording() {
        guard canPerform(.abort), let recorder, confirmAbort() else { return }
        // The modal question runs the main queue, so the recording may have ended while it
        // was open (Stop, the safety cap, an error) and its processing begun. The user said
        // to throw it away: stop that work before the transcript can go to a model, and
        // say so. From the M7 deep review.
        guard self.recorder === recorder, phase != .idle else {
            let stopped = cancelWork(for: recorder.base)
            recordError =
                stopped
                ? "The recording had already stopped, so it wasn't moved to the Trash. Its processing is cancelled; delete it from the library if you don't want it."
                : "The recording had already stopped and been processed, so it wasn't moved to the Trash. Delete it from the library if you don't want it."
            return
        }
        aborting = true
        recorder.abort()
    }

    /// Cancels the running or queued work on `base`. Returns true if there was some.
    private func cancelWork(for base: URL) -> Bool {
        let before = waiting.count
        waiting.removeAll { $0.base == base }
        var stopped = waiting.count != before
        if let job, !job.finished, job.base == base {
            jobTask?.cancel()
            stopped = true
        }
        if stopped { reload() }
        return stopped
    }

    private func discarded(_ recorder: RecordingSession, parts: [URL]) {
        stopMeters()
        phase = .idle
        paused = false
        self.recorder = nil
        aborting = false
        do { try recorder.discard(parts: parts) } catch {
            recordError = "The recording was stopped but not fully moved to the Trash: \(error.localizedDescription)"
        }
        reload()
    }

    private static func askToAbort() -> Bool {
        // From the menu bar with the window closed, the question must come to the front.
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Abort this recording?"
        alert.informativeText =
            "The recording stops and its audio goes to the Trash. Nothing is transcribed and no report is written."
        alert.addButton(withTitle: "Abort Recording")
        alert.addButton(withTitle: "Keep Recording")
        alert.buttons.first?.hasDestructiveAction = true
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
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
        if aborting {
            return "The aborted recording is being moved to the Trash. That finishes first, then the app quits."
        }
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
        if let afterRecording {
            afterRecording(parts, base)
        } else {
            process(parts: parts, base: base)
        }
    }

    // MARK: After the call

    var isProcessing: Bool { job.map { !$0.finished } ?? false }

    /// For the E2E demo only: shows a job without running one.
    func showDemoJob(_ job: Job) {
        self.job = job
        showsJob = true
        selection = nil
    }

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
        // During a recording the window stays where the user put it (M7 review).
        if phase == .idle {
            showsJob = true
            selection = nil
        }
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
        if result.failure == nil, result.reportJSON != nil, phase == .idle {
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
