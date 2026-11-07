import Foundation
import SpeakerKit
import WhisperKit

// The public face of the core, for the desktop app (M5). Everything the app does goes
// through here, and the terminal uses the same pieces, so no logic lives in the app
// target (spec 05: "Core logic has no copy in the app target"). The rest of the core
// stays internal.

// MARK: - Settings

/// The settings the app shows. Loading and saving go through `Config`, so every other
/// setting (the terminal's finer ones) is kept exactly as it was.
public struct AppSettings: Equatable, Sendable {
    public var outputDirectory: String
    /// 0 keeps audio forever.
    public var audioRetentionDays: Int
    public var whisperModel: String
    public var captureAllAudio: Bool
    public var enabledMeetingAppIDs: [String]
    public var micEnabled: Bool
    /// "claude" or "codex".
    public var primaryCLI: String
    public var redactionEnabled: Bool

    public static func load() -> AppSettings { AppSettings(Config.load()) }

    init(_ c: Config) {
        outputDirectory = c.outputDirectory
        audioRetentionDays = c.audioRetentionDays
        whisperModel = c.whisperModel
        captureAllAudio = c.captureAllAudio
        enabledMeetingAppIDs = c.enabledMeetingAppIDs
        micEnabled = c.micEnabled
        primaryCLI = c.primaryCLI.rawValue
        redactionEnabled = c.redactionEnabled
    }

    /// Writes these fields over the saved config, leaving every other field alone.
    /// Values out of range are refused rather than saved.
    public func save() throws {
        try save(to: Config.path)
    }

    /// Writes only the fields that differ from `original`, the settings as they were
    /// loaded, over the config on disk now. So a change the terminal made meanwhile to
    /// another field isn't put back. From the M5 review.
    public func save(changedFrom original: AppSettings) throws {
        try save(to: Config.path, changedFrom: original)
    }

    func save(to url: URL, changedFrom original: AppSettings? = nil) throws {
        guard AudioRetention.isValid(days: audioRetentionDays) else { throw SettingsError.badRetention }
        guard let cli = CLIKind(rawValue: primaryCLI) else { throw SettingsError.badCLI }
        guard WhisperModelCatalog.isValidID(whisperModel) else { throw SettingsError.badModel }
        if let original, original == self { return }
        func changed<T: Equatable>(_ path: KeyPath<AppSettings, T>) -> Bool {
            original.map { $0[keyPath: path] != self[keyPath: path] } ?? true
        }
        var c = Config.load(at: url, legacyURL: nil)
        if changed(\.outputDirectory) { c.outputDirectory = outputDirectory }
        if changed(\.audioRetentionDays) { c.audioRetentionDays = audioRetentionDays }
        if changed(\.whisperModel) { c.whisperModel = whisperModel }
        if changed(\.captureAllAudio) { c.captureAllAudio = captureAllAudio }
        if changed(\.enabledMeetingAppIDs) {
            c.enabledMeetingAppIDs = enabledMeetingAppIDs.filter { MeetingApp.allIDs.contains($0) }
        }
        if changed(\.micEnabled) { c.micEnabled = micEnabled }
        if changed(\.primaryCLI) { c.primaryCLI = cli }
        if changed(\.redactionEnabled) { c.redactionEnabled = redactionEnabled }
        try c.save(to: url)
    }

    public enum SettingsError: Error, LocalizedError {
        case badRetention, badCLI, badModel
        public var errorDescription: String? {
            switch self {
            case .badRetention: return "Keep audio for must be 1 to 3650 days, or forever."
            case .badCLI: return "Choose Claude or Codex."
            case .badModel: return "That speech model name isn't valid."
            }
        }
    }

    /// The output folder with `~` expanded.
    /// The output folder with `~` expanded the way the terminal does it. Made if missing.
    public var resolvedOutputDirectory: URL {
        var c = Config()
        c.outputDirectory = outputDirectory
        return (try? c.resolvedOutputDirectory()) ?? URL(fileURLWithPath: outputDirectory)
    }
}

public struct MeetingAppChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public static var all: [MeetingAppChoice] {
        MeetingApp.catalog.map { MeetingAppChoice(id: $0.id, label: $0.label) }
    }
}

/// The Whisper models both front ends offer. Sizes are what the download measured on
/// this Mac in 2026-11 (about), and only a guide.
public struct WhisperModelChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let blurb: String
    public let approxMB: Int

    public init(id: String, title: String, blurb: String, approxMB: Int) {
        self.id = id
        self.title = title
        self.blurb = blurb
        self.approxMB = approxMB
    }
}

public enum WhisperModelCatalog {
    public static let models: [WhisperModelChoice] = [
        .init(id: "openai_whisper-tiny.en", title: "Tiny, English", blurb: "fastest, rough", approxMB: 75),
        .init(id: "openai_whisper-base.en", title: "Base, English", blurb: "fast", approxMB: 140),
        .init(id: "openai_whisper-small.en", title: "Small, English", blurb: "English only", approxMB: 470),
        .init(id: "openai_whisper-medium.en", title: "Medium, English", blurb: "best for accents", approxMB: 1500),
        .init(id: "openai_whisper-small", title: "Small, multilingual", blurb: "for Chinese etc.", approxMB: 470),
        .init(
            id: "openai_whisper-medium", title: "Medium, multilingual", blurb: "slower, more accurate", approxMB: 1400),
    ]

    /// A model id is safe to pass on: the listed ones, or a custom one of plain characters.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 100
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
            && !id.hasPrefix(".") && !id.contains("..")
    }

    public static func choice(for id: String) -> WhisperModelChoice? { models.first { $0.id == id } }
}

// MARK: - Recording

/// A readable name for a recording before it has a report, from its file name
/// (`meeting_20261107_100200` gives "Recording, 7 Nov 2026 at 10:02").
public enum RecordingName {
    /// `short` drops the year and time, for a sidebar row whose second line shows the time.
    public static func title(for base: URL, short: Bool = false, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = base.lastPathComponent.replacingOccurrences(of: "meeting_", with: "")
        guard stamp.count >= 15, let date = f.date(from: String(stamp.prefix(15))) else {
            return base.lastPathComponent
        }
        let out = DateFormatter()
        out.locale = locale
        if short {
            out.setLocalizedDateFormatFromTemplate("dMMM")
        } else {
            out.dateStyle = .medium
            out.timeStyle = .short
        }
        return "Recording, " + out.string(from: date)
    }
}

/// One recording from start to stop. Make it with `Recorder.prepare()`, then `start()`.
public final class Recorder {
    /// `<output folder>/<timestamp>`; the files are `<base>.wav`, `<base>.txt`, and so on.
    public let base: URL
    private let capture = AudioCapture()
    private let config: Config

    private init(base: URL, config: Config) {
        self.base = base
        self.config = config
    }

    /// Makes the output folder and writes the sidecar first, so a crash leaves
    /// something the next launch can find.
    public static func prepare() throws -> Recorder {
        let config = Config.load()
        let base = try config.newMeetingBase()
        try RecordingSidecar.started().save(to: RecordingSidecar.url(forBase: base))
        return Recorder(base: base, config: config)
    }

    /// Records until `stop()` or the safety cap. Returns the WAV parts written.
    public func start() async throws -> [URL] {
        let parts = try await capture.run(
            duration: Double(config.defaultDurationMinutes * 60),
            outputPath: base.appendingPathExtension("wav").path,
            captureAllAudio: config.captureAllAudio,
            meetingApps: MeetingApp.catalog.filter { config.enabledMeetingAppIDs.contains($0.id) },
            enableMic: config.micEnabled)
        guard !parts.isEmpty else { throw RecorderError.nothingSaved }
        return parts
    }

    /// Returns true when now paused.
    @discardableResult
    public func togglePause() -> Bool { capture.pauseToggle() }
    /// Safe to call more than once, and before capture is live: the stop is held until then.
    public func stop() { capture.manualStop() }

    public var elapsedSeconds: Double { capture.elapsedSeconds }
    public var isPaused: Bool { capture.isPaused }
    public var isLive: Bool { capture.isLive }
    /// Mic and call loudness of the latest audio, 0…1.
    public var levels: (mic: Float, system: Float) { capture.levels }
    /// Such as "Zoom" or "all system audio"; empty until capture starts.
    public var sourceLabel: String { capture.targetLabel }
    public var micEnabled: Bool { config.micEnabled }
    public var captureAllAudio: Bool { config.captureAllAudio }
    /// For the terminal's keys (Space+Enter pauses, Enter stops).
    var audioCapture: AudioCapture { capture }

    public enum RecorderError: Error, LocalizedError {
        case nothingSaved
        public var errorDescription: String? { "No audio files were saved." }
    }
}

// MARK: - After the call

/// What happens after a call, step by step. The terminal and the app both run it.
public final class MeetingProcessor {
    public enum Event: Sendable {
        /// A stage started, in part `part` of `parts`.
        case stage(ProcessingStage, part: Int, parts: Int)
        /// Transcription of the current file, 0…1.
        case progress(Double)
        /// The transcript is written; the report, if any, comes next.
        case transcribed(String)
        /// The report is being written by this backend, such as "Claude CLI".
        case reportBackend(String)
        /// A step inside writing the report.
        case reportStep(ReportStep)
    }

    public struct Result: Sendable {
        /// The transcript text, if transcription ran.
        public var transcript: String?
        public var transcriptURL: URL?
        /// Things to tell the user, such as a speaker detection failure.
        public var notes: [String] = []
        public var reportJSON: URL?
        public var reportHTML: URL?
        public var reportMarkdown: URL?
        /// Set when a step failed. Earlier steps' files are kept.
        public var failure: String?
        /// Which stage failed.
        public var failedStage: ProcessingStage?
    }

    private let config: Config

    public init() { self.config = Config.load() }
    init(config: Config) { self.config = config }

    public var autoTranscribe: Bool { config.autoTranscribe }
    public var autoSummarize: Bool { config.autoSummarize }

    /// The stages `finish` will go through with these settings, for a progress list.
    public var plannedStages: [ProcessingStage] {
        var stages: [ProcessingStage] = []
        if config.autoTranscribe { stages += [.removingEcho, .transcribing, .labellingSpeakers] }
        stages.append(.savingAudio)
        if config.autoTranscribe && config.autoSummarize { stages.append(.writingReport) }
        return stages
    }

    /// Finishes a new recording: transcript, M4A, then the report when the settings say so.
    /// A transcription failure keeps the WAVs, and the next launch offers them again.
    public func finish(parts: [URL], base: URL, onEvent: @escaping (Event) -> Void = { _ in }) async -> Result {
        var result = Result()
        do {
            let transcriber = config.autoTranscribe ? try await loadTranscriber() : nil
            let pipeline = transcriber.map { makePipeline($0, onEvent: onEvent) }
            let watch = transcriber.map { watchProgress($0, onEvent: onEvent) }
            defer { watch?.cancel() }
            if let transcript = try await RecordingPipeline.finish(
                parts: parts, base: base, pipeline: pipeline,
                onStage: { onEvent(.stage($0, part: $1, parts: $2)) })
            {
                result.transcript = transcript.formatted
                result.transcriptURL = base.appendingPathExtension("txt")
                result.notes = transcript.notes
                onEvent(.transcribed(transcript.formatted))
            }
        } catch {
            result.failure =
                "Transcription failed: \(error.localizedDescription) The audio is kept, and it is offered again."
            result.failedStage = .transcribing
            return result
        }
        if config.autoSummarize, let text = result.transcript, let source = result.transcriptURL {
            await writeReport(transcript: text, source: source, into: &result, onEvent: onEvent)
        }
        return result
    }

    /// Transcribes existing audio again (a re-run). Writes `<base>.txt` next to it.
    public func transcribe(audio first: URL, onEvent: @escaping (Event) -> Void = { _ in }) async -> Result {
        var result = Result()
        let parts = RecordingFiles.allParts(of: first.path).map { URL(fileURLWithPath: $0) }
        let name = RecordingFiles.baseName(of: first.deletingPathExtension().lastPathComponent)
        let txt = first.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension("txt")
        do {
            let transcriber = try await loadTranscriber()
            let watch = watchProgress(transcriber, onEvent: onEvent)
            defer { watch.cancel() }
            let transcript = try await makePipeline(transcriber, onEvent: onEvent).transcribe(parts: parts)
            try (transcript.formatted + "\n").write(to: txt, atomically: true, encoding: .utf8)
            result.transcript = transcript.formatted
            result.transcriptURL = txt
            result.notes = transcript.notes
        } catch {
            result.failure = "Transcription failed: \(error.localizedDescription)"
            result.failedStage = .transcribing
        }
        return result
    }

    /// Writes the report for a transcript file (a re-run, or `--summarize-only`'s work).
    public func summarize(transcriptAt source: URL, onEvent: @escaping (Event) -> Void = { _ in }) async -> Result {
        var result = Result()
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            result.failure = "Couldn't read \(source.lastPathComponent)."
            result.failedStage = .writingReport
            return result
        }
        result.transcript = text
        result.transcriptURL = source
        await writeReport(transcript: text, source: source, into: &result, onEvent: onEvent)
        return result
    }

    /// The report itself, kept for the terminal, which prints it.
    var lastReport: Report?

    private func writeReport(
        transcript: String, source: URL, into result: inout Result, onEvent: @escaping (Event) -> Void
    ) async {
        onEvent(.stage(.writingReport, part: 1, parts: 1))
        do {
            let backend = try await SummaryRoute.backend(config: config)
            onEvent(.reportBackend(backend.label))
            let scenarios = ScenarioCatalog.load()
            result.notes += scenarios.warnings
            var pipeline = SummaryPipeline(
                backend: backend, redaction: config.redactionEnabled, catalog: scenarios.catalog)
            pipeline.onStep = { onEvent(.reportStep($0)) }
            let outcome = try await pipeline.run(transcript: transcript)
            // Kept before the write: if writing fails, the terminal can still show the
            // report the calls paid for. From the M5 review.
            lastReport = outcome.report
            let written = try ReportFiles.write(outcome.report, nextTo: source, fileTopic: outcome.fileTopic)
            result.reportJSON = written.json
            result.reportHTML = written.html
            result.reportMarkdown = written.markdown
        } catch {
            result.failure = "The report failed: \(error.localizedDescription) The transcript is kept."
            result.failedStage = .writingReport
        }
    }

    private func loadTranscriber() async throws -> Transcriber {
        let transcriber = Transcriber(model: config.whisperModel, language: config.whisperLanguage)
        try await transcriber.load()
        return transcriber
    }

    private func makePipeline(_ transcriber: Transcriber, onEvent: @escaping (Event) -> Void) -> RecordingPipeline {
        var pipeline = RecordingPipeline(
            transcriber: transcriber, detector: SpeakerKitDetector(), removeEcho: config.aecEnabled)
        pipeline.onStage = { onEvent(.stage($0, part: $1, parts: $2)) }
        return pipeline
    }

    /// WhisperKit reports progress on a property, so it's read a few times a second.
    private func watchProgress(_ transcriber: Transcriber, onEvent: @escaping (Event) -> Void) -> Task<Void, Never> {
        Task.detached {
            while !Task.isCancelled {
                onEvent(.progress(transcriber.fractionCompleted))
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }
}

// MARK: - Library

/// One recording in the output folder, as the app's library lists it.
public struct LibraryEntry: Identifiable, Hashable, Sendable {
    /// `<folder>/<timestamp>`, which every file of the recording starts with.
    public let base: URL
    public var id: String { base.path }
    public let createdAt: Date
    /// The report's topic, or nil before there is a report.
    public let topic: String?
    public let scenarioTitle: String?
    public let durationSeconds: Double?
    public let hasTranscript: Bool
    public let hasReport: Bool
    /// Still recording, or a crash left it unprocessed.
    public let isUnfinished: Bool
    /// The audio files the recording kept (raw first), for "Show in Finder".
    public let audioFiles: [URL]

    public var transcriptURL: URL { base.appendingPathExtension("txt") }
    public var reportJSONURL: URL { base.appendingPathExtension("report.json") }

    /// The report page, rendered from `<base>.report.json` the same way the terminal writes it.
    public func reportHTML() -> String? {
        guard let data = try? Data(contentsOf: reportJSONURL),
            let report = try? JSONDecoder().decode(Report.self, from: data)
        else { return nil }
        return ReportRenderer.html(report)
    }

    /// Speaker labels in the transcript, such as You, Speaker 1.
    public func speakers() -> [String] {
        guard let text = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return [] }
        return SpeakerLabels.speakers(in: text)
    }

    /// Renames a speaker in the transcript. Another speaker's name merges the two.
    /// Returns false when the name isn't allowed (empty, or has a colon).
    public func renameSpeaker(_ from: String, to raw: String) throws -> Bool {
        guard let name = SpeakerLabels.validName(raw) else { return false }
        try SpeakerLabels.rename(from, to: name, transcriptAt: transcriptURL)
        return true
    }

    /// Renames several speakers at once, each from its label as it is now, so a swap
    /// (Speaker 1 to Speaker 2 and back) stays a swap. Returns false, changing nothing,
    /// when any name isn't allowed. From the M5 review.
    public func applySpeakerNames(_ mapping: [String: String]) throws -> Bool {
        var names: [String: String] = [:]
        for (from, raw) in mapping {
            guard let name = SpeakerLabels.validName(raw) else { return false }
            if name != from { names[from] = name }
        }
        guard !names.isEmpty else { return true }
        try SpeakerLabels.rename(names, transcriptAt: transcriptURL)
        return true
    }

    /// The first part of an unfinished recording's audio, to process it.
    public var unfinishedParts: [URL] {
        guard let first = audioFiles.first else { return [] }
        return RecordingFiles.allParts(of: first.path).map { URL(fileURLWithPath: $0) }
    }
}

public enum Library {
    /// Every recording with a sidecar in `directory`, newest first, plus reports made
    /// from a transcript alone (`<base>.report.json` with no sidecar).
    ///
    /// `busy` names the bases this process is still recording or processing. Any other
    /// recording this process left in the recording state (a cancelled or failed job)
    /// counts as unfinished, so it can be processed again without a relaunch. A sidecar
    /// from another process that is still running is left alone. From the M5 review.
    public static func entries(in directory: URL, busy: Set<String> = []) -> [LibraryEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let me = getpid()
        let unfinished = Set(
            AudioRetention.unfinished(in: directory, isRunning: { $0 != me && AudioRetention.isRunning(pid: $0) })
                .map { RecordingFiles.baseName(of: $0.deletingPathExtension().lastPathComponent) }
        ).subtracting(busy)
        var bases = Set<String>()
        for name in names {
            if name.hasSuffix(".mcmeta.json") { bases.insert(String(name.dropLast(".mcmeta.json".count))) }
            if name.hasSuffix(".report.json") { bases.insert(String(name.dropLast(".report.json".count))) }
        }
        var entries: [LibraryEntry] = []
        for name in bases {
            let base = directory.appendingPathComponent(name)
            let sidecar = RecordingSidecar.load(at: RecordingSidecar.url(forBase: base))
            let report = (try? Data(contentsOf: base.appendingPathExtension("report.json")))
                .flatMap { try? JSONDecoder().decode(Report.self, from: $0) }
            let created =
                sidecar?.createdAt
                ?? (try? fm.attributesOfItem(atPath: base.appendingPathExtension("report.json").path)[.creationDate]
                    as? Date) ?? Date.distantPast
            var audio = (sidecar?.audioFiles ?? []).map { directory.appendingPathComponent($0) }
            if audio.isEmpty, unfinished.contains(name) {
                audio = RecordingFiles.allParts(of: base.appendingPathExtension("wav").path).map {
                    URL(fileURLWithPath: $0)
                }
            }
            let hasTranscript = fm.fileExists(atPath: base.appendingPathExtension("txt").path)
            // A recording stopped before any audio was written (say the app quit at the
            // permission prompt) leaves only its sidecar: nothing to open or redo, so skip it.
            if audio.isEmpty, !hasTranscript, report == nil, !unfinished.contains(name) { continue }
            entries.append(
                LibraryEntry(
                    base: base, createdAt: created, topic: report?.topic, scenarioTitle: report?.scenarioTitle,
                    durationSeconds: report?.durationSeconds,
                    hasTranscript: hasTranscript, hasReport: report != nil, isUnfinished: unfinished.contains(name),
                    audioFiles: audio))
        }
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    /// Deletes audio past the retention period, by the same rules as the terminal.
    /// Returns what was deleted.
    @discardableResult
    public static func cleanOldAudio(settings: AppSettings, now: Date = Date()) -> [URL] {
        AudioRetention.clean(in: settings.resolvedOutputDirectory, days: settings.audioRetentionDays, now: now)
    }
}

// MARK: - Models

/// The Whisper and speaker models, downloaded on first use and never bundled.
/// They go where WhisperKit and SpeakerKit keep them, so the terminal finds them too.
public enum ModelStore {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models/argmaxinc")
    }

    static func whisperFolder(_ model: String) -> URL {
        root.appendingPathComponent("whisperkit-coreml").appendingPathComponent(model)
    }

    /// True when the model's folder has its weights. An interrupted download leaves
    /// files under `.cache` only, so it reads as not there yet.
    public static func hasWhisperModel(_ model: String) -> Bool {
        let folder = whisperFolder(model)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { $0.hasSuffix(".mlmodelc") } && names.contains("config.json")
            || names.filter { $0.hasSuffix(".mlmodelc") }.count >= 3
    }

    public static var hasSpeakerModel: Bool {
        let folder = root.appendingPathComponent("speakerkit-coreml")
        guard let e = FileManager.default.enumerator(atPath: folder.path) else { return false }
        for case let name as String in e where name.hasSuffix(".mlmodelc") { return true }
        return false
    }

    /// Speaker detection's model is small; the measured download was about 11 MB.
    public static let speakerModelApproxMB = 11

    /// Downloads a Whisper model. Progress is 0…1 by files, so it can move in steps.
    /// Cancelling the task stops it; files already fetched are kept, and a file cut
    /// off partway resumes from where it stopped next time.
    public static func downloadWhisper(_ model: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard WhisperModelCatalog.isValidID(model) else { throw AppSettings.SettingsError.badModel }
        _ = try await WhisperKit.download(variant: model) { p in progress(p.fractionCompleted) }
        try Task.checkCancellation()
    }

    /// SpeakerKit downloads on init and reports no progress, so progress goes 0 then 1.
    /// It's about 11 MB, so the app shows it as a short indeterminate step.
    public static func downloadSpeakerModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0)
        _ = try await SpeakerKit(PyannoteConfig(verbose: false))
        try Task.checkCancellation()
        progress(1)
    }
}

// MARK: - Summaries

public enum SummaryService {
    /// The two subscription CLIs, as the settings show them.
    public static let cliChoices: [(id: String, label: String)] = CLIKind.allCases.map { ($0.rawValue, $0.label) }

    /// Calls made today and the daily cap, for the usage line.
    public static func usageToday(cli: String) -> (count: Int, cap: Int) {
        let cap = Config.load().dailyCLICallCap
        guard let kind = CLIKind(rawValue: cli) else { return (0, cap) }
        return ((try? UsageLedger().count(kind)) ?? 0, cap)
    }

    /// The terminal's usage line, such as "Claude: 12 of 200 calls today".
    public static func usageLine(cli: String) -> String {
        guard let kind = CLIKind(rawValue: cli) else { return "" }
        return UsageLedger().summaryLine(kind, cap: Config.load().dailyCLICallCap)
    }

    /// Installed, logged in and on the subscription. Spends no usage. Nil means ready;
    /// otherwise the reason it can't run.
    public static func connectionProblem(cli: String) async -> String? {
        guard let kind = CLIKind(rawValue: cli) else { return "Unknown CLI." }
        let config = Config.load()
        let runner = CLIRunner(
            models: [.claude: config.claudeModels, .codex: config.codexModels],
            allowAPIBilling: config.allowCLIAPIBilling && !SummaryRoute.cliOnly)
        switch await runner.availability(kind) {
        case .ready: return nil
        case .missing(let error): return error.errorDescription ?? "Not ready."
        }
    }
}

// MARK: - Launch environment

public enum LaunchEnvironment {
    /// An app opened from Finder gets a short PATH without the user's own tool folders,
    /// so `claude` and `codex` wouldn't be found. This adds the usual install places,
    /// after what's already there. Only folders that exist are added.
    public static func addUserToolFolders(home: String = NSHomeDirectory()) {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        setenv("PATH", extendedPATH(current: current, home: home), 1)
    }

    static func extendedPATH(current: String, home: String) -> String {
        var parts = current.split(separator: ":").map(String.init)
        let extra = [
            "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "\(home)/.bun/bin",
            "/opt/homebrew/bin", "/usr/local/bin",
        ]
        for dir in extra where !parts.contains(dir) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue { parts.append(dir) }
        }
        return parts.joined(separator: ":")
    }
}

// MARK: - Report navigation

/// What the app's report view does with a navigation. Only the page itself (`about:blank`
/// from loadHTMLString, and its `#anchors`) loads in the view. A clicked web link opens in
/// the browser; everything else (file:, javascript:, data:, custom schemes, redirects and
/// scripted loads of web pages) is refused.
public enum ReportNavigation: Equatable {
    case allow
    case openInBrowser(URL)
    case refuse

    public static func decide(url: URL?, isLinkClick: Bool) -> ReportNavigation {
        guard let url, let scheme = url.scheme?.lowercased() else { return .refuse }
        if scheme == "about" { return .allow }
        if isLinkClick, scheme == "http" || scheme == "https" { return .openInBrowser(url) }
        return .refuse
    }

    /// A `target=_blank` link asks for a new view; it never gets one, a web link opens outside.
    public static func decideNewWindow(url: URL?) -> ReportNavigation {
        guard case .openInBrowser(let u) = decide(url: url, isLinkClick: true) else { return .refuse }
        return .openInBrowser(u)
    }
}
