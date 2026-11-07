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
        var base: URL
        var title: String
        var steps: [StepState]
        var fraction: Double = 0
        var finished = false
        var failure: String?
        var notes: [String] = []
    }

    // Settings and library
    var settings = AppSettings.load()
    var entries: [LibraryEntry] = []
    var selection: LibraryEntry.ID?
    var showsJob = false

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
        entries = Library.entries(in: settings.resolvedOutputDirectory)
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
                finishedRecording(parts: parts, base: recorder.base)
            } catch {
                stopMeters()
                phase = .idle
                self.recorder = nil
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
        var stages: [ProcessingStage] = []
        if processor.autoTranscribe { stages += [.removingEcho, .transcribing, .labellingSpeakers] }
        stages.append(.savingAudio)
        if processor.autoSummarize && processor.autoTranscribe { stages.append(.writingReport) }
        startJob(base: base, title: Self.title(for: base), stages: stages) { onEvent in
            await processor.finish(parts: parts, base: base, onEvent: onEvent)
        }
    }

    func transcribeAgain(_ entry: LibraryEntry) {
        guard let first = entry.audioFiles.first else { return }
        startJob(
            base: entry.base, title: entry.topic ?? Self.title(for: entry.base),
            stages: [.removingEcho, .transcribing, .labellingSpeakers]
        ) { onEvent in
            await MeetingProcessor().transcribe(audio: first, onEvent: onEvent)
        }
    }

    func writeReportAgain(_ entry: LibraryEntry) {
        startJob(base: entry.base, title: entry.topic ?? Self.title(for: entry.base), stages: [.writingReport]) {
            onEvent in
            await MeetingProcessor().summarize(transcriptAt: entry.transcriptURL, onEvent: onEvent)
        }
    }

    func processUnfinished(_ entry: LibraryEntry) {
        let parts = entry.unfinishedParts
        guard !parts.isEmpty else { return }
        process(parts: parts, base: entry.base)
    }

    func cancelJob() {
        jobTask?.cancel()
    }

    private func startJob(
        base: URL, title: String, stages: [ProcessingStage],
        run: @escaping (@escaping (MeetingProcessor.Event) -> Void) async -> MeetingProcessor.Result
    ) {
        guard !isProcessing else { return }
        job = Job(base: base, title: title, steps: stages.map { StepState(stage: $0) })
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
        reload()
        if result.failure == nil, result.reportJSON != nil {
            showsJob = false
            selection = job.base.path
        }
    }

    // MARK: Settings

    var settingsError: String?

    func saveSettings() {
        do {
            try settings.save()
            settingsError = nil
            reload()
        } catch {
            settingsError = error.localizedDescription
        }
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
