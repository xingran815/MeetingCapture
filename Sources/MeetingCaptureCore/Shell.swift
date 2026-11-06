import Foundation

// Interactive shell. Launched when MeetingCaptureCLI is invoked with no args.
//
// Menu-driven, one keystroke per action. Settings are loaded from
// ~/Library/Application Support/MeetingCapture/config.json on launch and
// saved on every change.
//
// Mid-recording stop: we install a FileHandle.readabilityHandler on stdin
// during recording. When the user presses Enter (or any key), the handler
// fires, drains the bytes, and calls capture.manualStop(). Clean removal
// on recording-end means the next readLine() sees a fresh stdin, no race.
@available(macOS 14.0, *)
final class Shell {

    private var config: Config

    init() {
        self.config = Config.load()
    }

    func run() async {
        printBanner()
        cleanOldAudio()
        await offerUnfinishedRecordings()
        loop: while true {
            let items: [MenuItem] = [
                MenuItem(key: "1", label: "Record a meeting          ← Enter to stop"),
                MenuItem(key: "2", label: "Transcribe a recording"),
                MenuItem(key: "3", label: "Summarize a .txt"),
                MenuItem(key: "4", label: "Rename or merge speakers"),
                MenuItem(key: "5", label: "Settings"),
                MenuItem(key: "q", label: "Quit"),
            ]
            let pick = Menu.pick(header: mainHeader(), items: items, allowBack: false)
            switch pick {
            case .back:
                break loop
            case .selected(let i):
                switch i {
                case 0: await recordFlow()
                case 1: await transcribeFlow()
                case 2: await summarizeFlow()
                case 3: speakersFlow()
                case 4: await settingsFlow()
                case 5: break loop
                default: break
                }
            }
        }
        print("Bye.")
    }

    // MARK: - Menu rendering

    private func printBanner() {
        print(
            """
            ╔════════════════════════════════════════════╗
            ║   MeetingCapture  ·  v0.6                  ║
            ╚════════════════════════════════════════════╝
            """)
    }

    private func mainHeader() -> String {
        let autoTS = config.autoTranscribe ? "on" : "off"
        let autoSum = config.autoSummarize ? "on" : "off"
        let mic = config.micEnabled ? "on" : "off"
        return """

              whisper: \(config.whisperModel)   ·  llm: \(routeDescription)   ·  auto-ts: \(autoTS), auto-sum: \(autoSum)
              output:  \(config.outputDirectory)          safety cap: \(config.defaultDurationMinutes) min   ·  mic: \(mic)

            """
    }

    private func promptLine(_ prompt: String = "\n> ") -> String? {
        fputs(prompt, stdout)
        return readLine()
    }

    // Like promptLine but treats `b` / `back` (case-insensitive) as cancel,
    // returning nil. Use for any input where the user might want to bail out
    // without changing anything. The prompt is decorated with a `(b = back)` hint.
    private func askLine(_ label: String) -> String? {
        fputs("\(label)  (b = back): ", stdout)
        guard let raw = readLine() else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if lower == "b" || lower == "back" {
            print("↩  Back, no change.")
            return nil
        }
        return trimmed
    }

    // MARK: - Record

    private func recordFlow() async {
        let base: URL
        do { base = try config.newMeetingBase() } catch {
            print("❌  Couldn't prepare output directory: \(error.localizedDescription)")
            return
        }
        let wavURL = base.appendingPathExtension("wav")
        do {
            // Written first, so a crash leaves something the next launch can find.
            try RecordingSidecar(createdAt: Date(), state: .recording).save(to: RecordingSidecar.url(forBase: base))
        } catch {
            print("❌  Couldn't prepare the recording: \(error.localizedDescription)")
            return
        }

        let capture = AudioCapture()
        let totalSec = Double(config.defaultDurationMinutes * 60)

        let modeHint: String = {
            if config.captureAllAudio { return "  (all system audio)" }
            return config.micEnabled ? "" : "  (system audio only — mic off)"
        }()
        print(
            """

            🔴  Recording → \(wavURL.path)\(modeHint)
                Space+Enter to pause/resume · Enter to stop.
            """)

        RecordingKeys.install(on: capture)
        defer { RecordingKeys.remove() }

        let wavFiles: [URL]
        do {
            wavFiles = try await capture.run(
                duration: totalSec,
                outputPath: wavURL.path,
                captureAllAudio: config.captureAllAudio,
                meetingApps: MeetingApp.catalog.filter { config.enabledMeetingAppIDs.contains($0.id) },
                enableMic: config.micEnabled,
                aecEnabled: config.micEnabled && config.aecEnabled
            )
        } catch {
            print("❌  Capture failed: \(error.localizedDescription)")
            return
        }

        guard !wavFiles.isEmpty else {
            print("❌  No audio files were saved.")
            return
        }

        await finishRecording(parts: wavFiles, base: base)
        cleanOldAudio()
    }

    /// Transcribes, encodes, then summarizes. If transcription fails, the WAVs stay
    /// and the next launch offers the recording again.
    private func finishRecording(parts: [URL], base: URL) async {
        var transcript: String?
        do {
            let pipeline = config.autoTranscribe ? try await makePipeline() : nil
            if let result = try await RecordingPipeline.finish(parts: parts, base: base, pipeline: pipeline) {
                transcript = show(result, txtURL: base.appendingPathExtension("txt"))
            }
        } catch {
            print("❌  Transcription failed: \(error.localizedDescription)")
            print("   The audio is kept, and the next launch offers it again.")
            return
        }

        if config.autoSummarize {
            if let text = transcript {
                await runSummarize(transcript: text, sourcePath: base.appendingPathExtension("txt").path)
            } else {
                print("ℹ  Skipping summary: auto-transcribe is off, no transcript available.")
            }
        }
    }

    private func makePipeline() async throws -> RecordingPipeline {
        let transcriber = Transcriber(model: config.whisperModel, language: config.whisperLanguage)
        try await transcriber.load()
        return RecordingPipeline(transcriber: transcriber, detector: SpeakerKitDetector())
    }

    private func show(_ result: RecordingPipeline.Transcript, txtURL: URL) -> String {
        let text = result.formatted
        print("\n──── transcript ──────────────────────────")
        print(text)
        print("──────────────────────────────────────────")
        for note in result.notes { print("⚠  \(note)") }
        print("   txt:  \(txtURL.path)")
        return text
    }

    // MARK: - Old and unfinished audio

    private var outputDirectoryURL: URL? { try? config.resolvedOutputDirectory() }

    private func cleanOldAudio() {
        guard let dir = outputDirectoryURL else { return }
        for url in AudioRetention.clean(in: dir, days: config.audioRetentionDays, now: Date()) {
            print("🧹  Deleted old audio: \(url.lastPathComponent)")
        }
    }

    /// A crash mid-recording leaves WAV chunks. Declining leaves them, and asks again.
    private func offerUnfinishedRecordings() async {
        guard let dir = outputDirectoryURL else { return }
        for first in AudioRetention.unfinished(in: dir) {
            let parts = RecordingFiles.allParts(of: first.path).map { URL(fileURLWithPath: $0) }
            let word = parts.count == 1 ? "file" : "files"
            print("\n⚠  An unfinished recording was found: \(first.lastPathComponent) (\(parts.count) \(word)).")
            guard let answer = promptLine("Process it now? [Y/n]: "), !answer.lowercased().hasPrefix("n") else {
                continue
            }
            for part in parts { _ = try? WAVRepair.repairHeader(at: part) }
            await finishRecording(parts: parts, base: first.deletingPathExtension())
        }
    }

    // MARK: - Speakers

    private func speakersFlow() {
        guard let raw = askLine("Path to the transcript .txt"), !raw.isEmpty else { return }
        let url = URL(fileURLWithPath: expand(raw))
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("❌  Couldn't read file: \(url.path)")
            return
        }
        let speakers = SpeakerLabels.speakers(in: text)
        guard !speakers.isEmpty else {
            print("No speaker labels in that file.")
            return
        }
        for (i, name) in speakers.enumerated() { print("  \(i + 1)) \(name)") }
        guard let pick = askLine("Speaker to rename (number)"), let n = Int(pick), speakers.indices.contains(n - 1)
        else {
            return
        }
        print("Type a new name. Using another speaker's name merges the two.")
        guard let raw = askLine("New name"), let name = SpeakerLabels.validName(raw) else {
            print("Nothing changed: a name can't be empty or contain a colon.")
            return
        }
        do {
            try SpeakerLabels.rename(speakers[n - 1], to: name, transcriptAt: url)
            print("✓  \(speakers[n - 1]) is now \(name).")
        } catch {
            print("❌  Couldn't save: \(error.localizedDescription)")
        }
    }

    // MARK: - Transcribe

    private func transcribeFlow() async {
        guard let raw = askLine("Path to a .wav or .m4a"), !raw.isEmpty else { return }
        let path = expand(raw)
        guard FileManager.default.fileExists(atPath: path) else {
            print("❌  File not found: \(path)")
            return
        }
        _ = await runTranscribe(wavPaths: RecordingFiles.allParts(of: path))

        // Offer to summarize the fresh transcript
        let txtPath = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent(
                RecordingFiles.baseName(of: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
            )
            .appendingPathExtension("txt").path
        guard FileManager.default.fileExists(atPath: txtPath) else { return }
        guard let yn = promptLine("Summarize the transcript now? [Y/n]: ") else { return }
        if yn.lowercased().hasPrefix("n") { return }
        guard let text = try? String(contentsOfFile: txtPath, encoding: .utf8) else { return }
        await runSummarize(transcript: text, sourcePath: txtPath)
    }

    // MARK: - Summarize

    private func summarizeFlow() async {
        guard let raw = askLine("Path to .txt"), !raw.isEmpty else { return }
        let path = expand(raw)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("❌  Couldn't read file: \(path)")
            return
        }
        await runSummarize(transcript: text, sourcePath: path)
    }

    // MARK: - Pipeline primitives

    @discardableResult
    private func runTranscribe(wavPaths: [String]) async -> String? {
        guard !wavPaths.isEmpty else { return nil }

        let first = URL(fileURLWithPath: wavPaths[0])
        let baseName = RecordingFiles.baseName(of: first.deletingPathExtension().lastPathComponent)
        let txtURL = first.deletingLastPathComponent().appendingPathComponent(baseName).appendingPathExtension("txt")
        do {
            let pipeline = try await makePipeline()
            let result = try await pipeline.transcribe(parts: wavPaths.map { URL(fileURLWithPath: $0) })
            try (result.formatted + "\n").write(to: txtURL, atomically: true, encoding: .utf8)
            return show(result, txtURL: txtURL)
        } catch {
            print("❌  Transcription failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func runSummarize(transcript: String, sourcePath: String) async {
        do {
            let backend = try await SummaryRoute.backend(config: config)
            print("🧩  Summarizing via \(backend.label)…")
            let outcome = try await SummaryPipeline(backend: backend, redaction: config.redactionEnabled)
                .run(transcript: transcript)
            print(
                outcome.style == .therapy
                    ? "🧭  Detected a therapy session — wrote Practice Notes."
                    : "🧭  Detected a meeting — wrote a summary.")
            if outcome.redactedValues > 0 {
                print(
                    "🔒  \(outcome.redactedValues) formatted values were kept out of the request. Spoken names aren't caught."
                )
            }

            let totalWidth = 50
            let labelPart = "──── summary "
            let fill = String(repeating: "─", count: max(0, totalWidth - labelPart.count))
            print("\n" + labelPart + fill)
            print(renderMarkdown(outcome.report.trimmingCharacters(in: .whitespacesAndNewlines)))
            print(String(repeating: "─", count: totalWidth))

            let mdURL = URL(fileURLWithPath: sourcePath)
                .deletingPathExtension()
                .appendingPathExtension("md")
            try (outcome.report + "\n").write(to: mdURL, atomically: true, encoding: .utf8)
            print("   md:   \(mdURL.path)")
        } catch {
            print("❌  Summarization failed: \(error.localizedDescription)\n   Transcript is still on disk.")
        }
    }

    /// The route in a few words, for the header and Settings.
    private var routeDescription: String {
        switch config.llmRoute {
        case .subscription: return "\(config.primaryCLI.label) CLI first"
        case .apiProfile:
            let active = config.activeLLMProfile
            return "API · \(active.displayName) / \(active.model)"
        }
    }

    /// Cycles: Claude first → Codex first → API profile.
    private func cycleRoute() {
        switch (config.llmRoute, config.primaryCLI) {
        case (.subscription, .claude): config.primaryCLI = .codex
        case (.subscription, .codex): config.llmRoute = .apiProfile
        case (.apiProfile, _):
            config.llmRoute = .subscription
            config.primaryCLI = .claude
        }
        persistConfig()
    }

    /// Model names change, so they're plain text. Enter keeps the current one.
    private func promptTierModels() {
        func ask(_ kp: WritableKeyPath<Config, CLITierModels>, _ name: String) {
            for (tier, field) in [
                ("cheap", \CLITierModels.cheap), ("normal", \CLITierModels.normal),
                ("frontier", \CLITierModels.frontier),
            ] as [(String, WritableKeyPath<CLITierModels, String>)] {
                let current = config[keyPath: kp][keyPath: field]
                guard let v = askLine("\(name) \(tier) model [\(current)]"), !v.isEmpty else { continue }
                guard CLIArguments.isSafeModelName(v) else {
                    print("That isn't a valid model name; keeping \(current).")
                    continue
                }
                config[keyPath: kp][keyPath: field] = v
            }
        }
        ask(\.claudeModels, "Claude")
        ask(\.codexModels, "Codex")
        persistConfig()
    }

    // MARK: - Settings

    private func settingsFlow() async {
        // Rebuilt before every redraw so the [bracketed] values reflect the
        // latest config; Menu.run keeps the menu in place across changes.
        // Grouped with dimmed separator headers. Each selectable row keeps a
        // stable shortcut key; the handler dispatches on that key (not the row
        // index) so separators can be inserted without re-numbering anything.
        func buildItems() -> [MenuItem] {
            let c = config
            let ledger = UsageLedger()
            let aecDesc =
                c.micEnabled
                ? (c.aecEnabled ? "on" : "off")
                : "n/a — mic off"
            let appsDesc =
                c.captureAllAudio
                ? "all system audio"
                : "\(c.enabledMeetingAppIDs.count) of \(MeetingApp.catalog.count) on"
            return [
                .separator("── Capture & transcription ──────────"),
                MenuItem(key: "1", label: "Whisper model           [\(c.whisperModel)]"),
                MenuItem(key: "2", label: "Safety cap (minutes)    [\(c.defaultDurationMinutes)]"),
                MenuItem(key: "3", label: "Output directory        [\(c.outputDirectory)]"),
                MenuItem(key: "4", label: "Auto-transcribe         [\(c.autoTranscribe ? "on" : "off")]"),
                .separator("── LLM (summarization) ──────────────"),
                MenuItem(key: "5", label: "Auto-summarize          [\(c.autoSummarize ? "on" : "off")]"),
                MenuItem(key: "c", label: "LLM route               [\(routeDescription)]"),
                MenuItem(
                    key: "t", label: "CLI tier models         [\(c.claudeModels.normal) · \(c.codexModels.normal)]"),
                MenuItem(key: "l", label: "Daily CLI call cap      [\(c.dailyCLICallCap) per CLI]"),
                MenuItem(key: "x", label: "Redaction               [\(c.redactionEnabled ? "on" : "off")]"),
                MenuItem(key: "6", label: "API configurations      [\(c.llmProfiles.count) saved]"),
                .separator("   \(ledger.summaryLine(.claude, cap: c.dailyCLICallCap))"),
                .separator("   \(ledger.summaryLine(.codex, cap: c.dailyCLICallCap))"),
                .separator("── Audio ────────────────────────────"),
                MenuItem(key: "a", label: "AEC (echo cancel)       [\(aecDesc)]"),
                MenuItem(key: "m", label: "Mic capture             [\(c.micEnabled ? "on" : "off")]"),
                MenuItem(key: "s", label: "Audio source            [\(appsDesc)]"),
                MenuItem(
                    key: "d",
                    label:
                        "Keep audio for          [\(c.audioRetentionDays == 0 ? "forever" : "\(c.audioRetentionDays) days")]"
                ),
                .separator("─────────────────────────────────────"),
                MenuItem(key: "r", label: "Reset to defaults"),
            ]
        }

        Menu.run(title: "\nSettings\n", items: buildItems, allowBack: true) { i in
            let items = buildItems()
            guard items.indices.contains(i) else { return }
            switch items[i].key {
            case "1": promptWhisperModel()
            case "2": promptInt(\.defaultDurationMinutes, label: "safety cap (minutes)", min: 1, max: 600)
            case "3": promptString(\.outputDirectory, label: "output directory")
            case "4": toggle(\.autoTranscribe, label: "Auto-transcribe")
            case "5": toggle(\.autoSummarize, label: "Auto-summarize")
            case "6": llmConfigsFlow()
            case "c": cycleRoute()
            case "t": promptTierModels()
            case "l": promptInt(\.dailyCLICallCap, label: "daily calls per CLI", min: 1, max: 10_000)
            case "x": toggle(\.redactionEnabled, label: "Redaction")
            case "a":
                if config.micEnabled {
                    toggle(\.aecEnabled, label: "AEC")
                } else {
                    print("AEC has no effect while mic is off — enable mic first.")
                }
            case "m": toggle(\.micEnabled, label: "Mic capture")
            case "s": promptMeetingApps()
            case "d":
                promptInt(\.audioRetentionDays, label: "days to keep audio (0 = forever)", min: 0, max: 3650)
            case "r":
                config = Config()
                persistConfig()
                print("✓  Reset to defaults.")
            default: break
            }
        }
    }

    // MARK: - LLM configurations (tree)

    /// Lists every saved LLM configuration. Enter on a row makes it the active
    /// one (instant switch, ● marker moves); n/e/d add, edit, and delete. Each
    /// configuration owns its own provider/model/base URL/reasoning + API key.
    private func llmConfigsFlow() {
        func buildItems() -> [MenuItem] {
            var items: [MenuItem] = []
            for p in config.llmProfiles {
                let marker = (p.id == config.selectedLLMProfileID) ? "●" : " "
                items.append(MenuItem(label: "\(marker) \(p.displayName)   (\(p.providerID) · \(p.model))"))
            }
            items.append(.separator("──────────────────────────────"))
            items.append(MenuItem(key: "n", label: "New configuration  (preset or custom)"))
            items.append(MenuItem(key: "e", label: "Edit a configuration"))
            items.append(MenuItem(key: "d", label: "Delete a configuration", enabled: !config.llmProfiles.isEmpty))
            return items
        }

        Menu.run(
            title: "\nAPI configurations (used on the API route, or when no CLI is ready)\n", items: buildItems,
            allowBack: true
        ) { i in
            let profileCount = config.llmProfiles.count
            if i < profileCount {
                config.selectedLLMProfileID = config.llmProfiles[i].id
                persistConfig()
                return
            }
            let items = buildItems()
            guard items.indices.contains(i) else { return }
            switch items[i].key {
            case "n": newLLMProfileFlow()
            case "e": pickProfile(title: "\nEdit which configuration?\n") { id in self.editProfileFlow(profileID: id) }
            case "d": pickProfile(title: "\nDelete which configuration?\n") { id in self.deleteProfile(id) }
            default: break
            }
        }
    }

    /// One-shot picker over the saved profiles; calls `handler` with the chosen
    /// profile's id, or does nothing on back/empty.
    private func pickProfile(title: String, handler: (String) -> Void) {
        let profiles = config.llmProfiles
        guard !profiles.isEmpty else { return }
        let items = profiles.map { MenuItem(label: "\($0.displayName)   (\($0.providerID) · \($0.model))") }
        switch Menu.pick(title: title, items: items, allowBack: true) {
        case .back: return
        case .selected(let i):
            guard profiles.indices.contains(i) else { return }
            handler(profiles[i].id)
        }
    }

    /// Walks through provider selection (preset or custom), then optionally the
    /// API key, and appends a new profile that immediately becomes active.
    private func newLLMProfileFlow() {
        guard let provider = pickProviderPreset(current: nil) else { return }
        var profile: LLMProfile
        if provider.id == "custom" {
            let name = askLine("Configuration name") ?? "Custom"
            let url = askLine("Base URL") ?? ""
            let model = askLine("Model") ?? ""
            profile = LLMProfile(
                name: name.isEmpty ? "Custom" : name, providerID: "custom",
                model: model, baseURL: url)
        } else {
            let defaultName = provider.label
            let name = askLine("Configuration name [\(defaultName)]") ?? ""
            profile = LLMProfile(
                name: name.isEmpty ? defaultName : name,
                providerID: provider.id,
                model: provider.defaultModel,
                baseURL: provider.baseURL
            )
        }
        config.llmProfiles.append(profile)
        config.selectedLLMProfileID = profile.id
        persistConfig()
        print("✓  Added \"\(profile.displayName)\" and made it active.")

        if let key = readSecret("API key for \"\(profile.displayName)\" (input hidden, blank to skip)"),
            !key.isEmpty
        {
            if APIKeyStore.write(key, forProfile: profile.id) {
                print("✓  Stored key for \"\(profile.displayName)\".")
            } else {
                print("⚠  Failed to write key file.")
            }
        }
    }

    /// Edit one saved configuration's fields. Mirrors the old flat Settings rows,
    /// scoped to a single profile.
    private func editProfileFlow(profileID: String) {
        func index() -> Int? { config.llmProfiles.firstIndex { $0.id == profileID } }
        guard index() != nil else { return }

        func buildItems() -> [MenuItem] {
            guard let idx = index() else { return [] }
            let p = config.llmProfiles[idx]
            let keyStatus = Config.apiKeySource(profileID: p.id)
            let style = p.effectiveReasoningStyle
            let reasoningDesc =
                style == .none
                ? "n/a — no reasoning format"
                : "\(p.reasoningEffort.isOn ? p.reasoningEffort.rawValue : "off") · \(style.label)"
            let detected = LLMProvider.reasoningStyle(baseURL: p.baseURL, providerID: p.providerID)
            let formatDesc =
                p.reasoningStyleOverride.map { "\($0.label) (override)" }
                ?? "auto · \(detected.label)"
            return [
                MenuItem(key: "1", label: "Name              [\(p.name.isEmpty ? p.displayName : p.name)]"),
                MenuItem(key: "2", label: "Provider          [\(p.providerID)]"),
                MenuItem(key: "3", label: "Model             [\(p.model)]"),
                MenuItem(key: "4", label: "Base URL          [\(p.baseURL)]"),
                MenuItem(key: "5", label: "Reasoning effort  [\(reasoningDesc)]"),
                MenuItem(key: "f", label: "Reasoning format  [\(formatDesc)]"),
                MenuItem(key: "l", label: "API key           [\(keyStatus)]"),
                MenuItem(key: "t", label: "Test connection & detect reasoning"),
            ]
        }

        Menu.run(title: "\nEdit configuration\n", items: buildItems, allowBack: true) { i in
            guard let idx = index() else { return }
            let items = buildItems()
            guard items.indices.contains(i) else { return }
            switch items[i].key {
            case "1":
                guard let v = askLine("Name [\(config.llmProfiles[idx].name)]"), !v.isEmpty else { return }
                config.llmProfiles[idx].name = v
                persistConfig()
            case "2":
                guard let provider = pickProviderPreset(current: config.llmProfiles[idx].providerID) else { return }
                config.llmProfiles[idx].providerID = provider.id
                if provider.id != "custom" {
                    config.llmProfiles[idx].baseURL = provider.baseURL
                    config.llmProfiles[idx].model = provider.defaultModel
                }
                // Re-detect the reasoning format for the new provider; drop the
                // effort if the new endpoint has no reasoning mode.
                config.llmProfiles[idx].reasoningStyleOverride = nil
                if !config.llmProfiles[idx].supportsReasoning {
                    config.llmProfiles[idx].reasoningEffort = .off
                }
                persistConfig()
            case "3":
                guard let v = askLine("Model [\(config.llmProfiles[idx].model)]"), !v.isEmpty else { return }
                config.llmProfiles[idx].model = v
                persistConfig()
            case "4":
                guard let v = askLine("Base URL [\(config.llmProfiles[idx].baseURL)]"), !v.isEmpty else { return }
                config.llmProfiles[idx].baseURL = v
                persistConfig()
            case "5":
                if config.llmProfiles[idx].supportsReasoning {
                    promptProfileReasoning(profileID: profileID)
                } else {
                    print(
                        "This endpoint has no reasoning format — set \"Reasoning format\" to enable it, or pick a provider that has one (e.g. DeepSeek, OpenAI, Anthropic)."
                    )
                }
            case "f": promptProfileReasoningFormat(profileID: profileID)
            case "l": promptProfileApiKey(profileID: profileID)
            case "t": testConnection(profile: config.llmProfiles[idx])
            default: break
            }
        }
    }

    private func deleteProfile(_ profileID: String) {
        guard let idx = config.llmProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        let removed = config.llmProfiles.remove(at: idx)
        if config.selectedLLMProfileID == removed.id {
            config.selectedLLMProfileID = config.llmProfiles.first?.id ?? ""
        }
        APIKeyStore.delete(profileID: removed.id)
        persistConfig()
        print("✓  Deleted \"\(removed.displayName)\".")
    }

    /// Shared preset picker used by both "new configuration" and "edit → provider".
    /// `current` (a providerID), if given, is pre-selected.
    private func pickProviderPreset(current: String?) -> LLMProvider? {
        let items = LLMProvider.catalog.enumerated().map { (i, p) -> MenuItem in
            let marker = (p.id == current) ? "●" : " "
            let label = p.id == "custom" ? p.label : "\(p.label)   (\(p.baseURL))"
            return MenuItem(key: Character("\(i + 1)"), label: "\(marker) \(label)")
        }
        let initial = LLMProvider.catalog.firstIndex { $0.id == current } ?? 0
        switch Menu.pick(title: "\nProvider\n", items: items, initialIndex: initial, allowBack: true) {
        case .back: return nil
        case .selected(let i):
            guard LLMProvider.catalog.indices.contains(i) else { return nil }
            return LLMProvider.catalog[i]
        }
    }

    /// Pick the unified reasoning depth (off/low/medium/high). The active provider
    /// maps the level to its own param (budget tokens for `.thinking`, effort otherwise).
    private func promptProfileReasoning(profileID: String) {
        guard let idx = config.llmProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        let levels = ReasoningEffort.allCases
        let current = config.llmProfiles[idx].reasoningEffort
        let items = levels.enumerated().map { (i, e) -> MenuItem in
            let marker = (e == current) ? "●" : " "
            return MenuItem(key: Character("\(i + 1)"), label: "\(marker) \(e.rawValue)")
        }
        let initial = levels.firstIndex(of: current) ?? 0
        switch Menu.pick(title: "\nReasoning effort\n", items: items, initialIndex: initial, allowBack: true) {
        case .back: return
        case .selected(let i):
            guard levels.indices.contains(i) else { return }
            config.llmProfiles[idx].reasoningEffort = levels[i]
            persistConfig()
        }
    }

    /// Override the auto-detected reasoning format. "Auto" (nil) resolves from the
    /// base URL host / preset; the explicit choices force a format on an
    /// unrecognized custom endpoint.
    private func promptProfileReasoningFormat(profileID: String) {
        guard let idx = config.llmProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        let p = config.llmProfiles[idx]
        let detected = LLMProvider.reasoningStyle(baseURL: p.baseURL, providerID: p.providerID)
        let options: [(label: String, value: ReasoningStyle?)] = [
            ("auto (detected: \(detected.label))", nil),
            (ReasoningStyle.thinking.label, .thinking),
            (ReasoningStyle.openai.label, .openai),
            (ReasoningStyle.anthropic.label, .anthropic),
            ("none (disable)", ReasoningStyle.none),
        ]
        let current = p.reasoningStyleOverride
        let items = options.enumerated().map { (i, o) -> MenuItem in
            let marker = (o.value == current) ? "●" : " "
            return MenuItem(key: Character("\(i + 1)"), label: "\(marker) \(o.label)")
        }
        let initial = options.firstIndex { $0.value == current } ?? 0
        switch Menu.pick(title: "\nReasoning format\n", items: items, initialIndex: initial, allowBack: true) {
        case .back: return
        case .selected(let i):
            guard options.indices.contains(i) else { return }
            config.llmProfiles[idx].reasoningStyleOverride = options[i].value
            persistConfig()
        }
    }

    private func promptProfileApiKey(profileID: String) {
        if ProcessInfo.processInfo.environment["LLM_API_KEY"] != nil {
            print("ℹ  An env-var key is set in this shell; it takes precedence over the stored file while present.")
        }
        let stored = APIKeyStore.isStored(profileID: profileID)
        var items: [MenuItem] = [
            MenuItem(
                key: "s", label: stored ? "Replace stored key" : "Set new key  (stored in ~/.config/MeetingCapture)")
        ]
        if stored {
            items.append(MenuItem(key: "c", label: "Clear stored key"))
        }
        switch Menu.pick(title: "\nAPI key\n", items: items, allowBack: true) {
        case .back:
            return
        case .selected(let i):
            if items[i].key == "c" {
                if APIKeyStore.delete(profileID: profileID) {
                    print("✓  Cleared stored key.")
                } else {
                    print("⚠  Failed to clear key file.")
                }
                return
            }
            guard let key = readSecret("Paste API key (input hidden)"), !key.isEmpty else {
                print("↩  No change.")
                return
            }
            if APIKeyStore.write(key, forProfile: profileID) {
                print("✓  Stored in ~/.config/MeetingCapture/llm_api_keys.json (mode 0600).")
            } else {
                print("⚠  Failed to write key file.")
            }
        }
    }

    private func promptWhisperModel() {
        let models: [(id: String, blurb: String)] = [
            ("openai_whisper-tiny.en", "~75 MB, fastest, rough"),
            ("openai_whisper-base.en", "~140 MB"),
            ("openai_whisper-small.en", "~470 MB, English only"),
            ("openai_whisper-medium.en", "~1.5 GB, best for accents"),
            ("openai_whisper-small", "multilingual, for Chinese etc."),
            ("openai_whisper-medium", "multilingual"),
        ]
        var items = models.enumerated().map { (i, m) in
            let marker = (m.id == config.whisperModel) ? "●" : " "
            return MenuItem(key: Character("\(i + 1)"), label: "\(marker) \(m.id)   (\(m.blurb))")
        }
        items.append(MenuItem(key: "c", label: "  Custom…  (type any WhisperKit model id)"))

        let initial = models.firstIndex(where: { $0.id == config.whisperModel }) ?? 0
        let pick = Menu.pick(
            title: "\nWhisper model  (current: \(config.whisperModel))\n",
            items: items,
            initialIndex: initial,
            allowBack: true
        )
        switch pick {
        case .back:
            return
        case .selected(let i):
            if i < models.count {
                config.whisperModel = models[i].id
                persistConfig()
                print("✓  Whisper model: \(config.whisperModel)")
            } else {
                guard let v = askLine("Custom Whisper model [\(config.whisperModel)]"),
                    !v.isEmpty
                else { return }
                config.whisperModel = v
                persistConfig()
            }
            promptWhisperLanguageIfNeeded()
        }
    }

    /// For multilingual models, optionally pin a language. Leaving it blank
    /// lets Whisper auto-detect on the first window — that's faster than
    /// pinning when wrong and still works. Pinning is only useful if
    /// auto-detection picks the wrong language.
    private func promptWhisperLanguageIfNeeded() {
        guard !config.whisperModel.contains(".en") else {
            // Switching back to an .en model — clear any stale language pin.
            if config.whisperLanguage != nil {
                config.whisperLanguage = nil
                persistConfig()
            }
            return
        }
        let cur = config.whisperLanguage ?? "auto-detect"
        print("Multilingual model. Language is auto-detected from the audio by default.")
        guard let v = askLine("Pin a language code (en, zh, ja, …) or blank for auto [\(cur)]")
        else { return }
        let trimmed = v.trimmingCharacters(in: .whitespaces)
        config.whisperLanguage = trimmed.isEmpty ? nil : trimmed
        persistConfig()
        print("✓  Whisper language: \(config.whisperLanguage ?? "auto-detect")")
    }

    /// Verify one configuration's provider/model/key actually work with a
    /// one-token /chat/completions ping. Bridges the callback-based
    /// Summarizer.ping from this synchronous menu handler via a semaphore —
    /// safe because URLSession runs the completion on its own queue, not the
    /// concurrency pool.
    private func testConnection(profile: LLMProfile) {
        guard let apiKey = Config.resolveApiKey(profileID: profile.id), !apiKey.isEmpty else {
            print(
                "❌  No API key for \"\(profile.displayName)\". Set one in this configuration's editor, or export LLM_API_KEY."
            )
            return
        }
        guard let baseURL = URL(string: profile.baseURL) else {
            print("❌  Invalid LLM base URL: \(profile.baseURL)")
            return
        }
        let summarizer = Summarizer(
            baseURL: baseURL, apiKeyProvider: { apiKey }, model: profile.model, apiStyle: profile.apiStyle)
        print("⏳  Testing \(profile.model) @ \(baseURL.host ?? profile.baseURL)…")

        let sem = DispatchSemaphore(value: 0)
        var result: Result<String, Error>?
        summarizer.ping { r in
            result = r
            sem.signal()
        }
        sem.wait()

        switch result {
        case .success(let s): print("✓  Connected — \(s)")
        case .failure(let e):
            print("✗  \(e.localizedDescription)")
            return
        case .none:
            print("✗  No result.")
            return
        }

        // Connection is good — probe whether this endpoint actually reasons.
        probeAndApplyReasoning(profileID: profile.id, summarizer: summarizer)
    }

    /// Second half of Test connection: actively probe whether the endpoint
    /// supports reasoning (and in which wire format) by sending a tiny
    /// reasoning-inducing request and inspecting the response. Applies a positive
    /// result only when the profile has no explicit Reasoning format override, so
    /// a "test" never clobbers a deliberate choice.
    private func probeAndApplyReasoning(profileID: String, summarizer: Summarizer) {
        guard let idx = config.llmProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        let p = config.llmProfiles[idx]
        let detected = LLMProvider.reasoningStyle(baseURL: p.baseURL, providerID: p.providerID)

        print("⏳  Probing reasoning support…")
        let sem = DispatchSemaphore(value: 0)
        var outcome: Summarizer.ReasoningProbeOutcome?
        summarizer.probeReasoning(hostDetected: detected) { o in
            outcome = o
            sem.signal()
        }
        sem.wait()

        switch outcome {
        case .supported(let style, let detail):
            print("✓  Reasoning detected: \(style.label) (\(detail))")
            if p.reasoningStyleOverride == nil {
                // Keep "auto" when host detection already agrees, else pin the format.
                config.llmProfiles[idx].reasoningStyleOverride = (style == detected) ? nil : style
                persistConfig()
                print(
                    style == detected
                        ? "   Reasoning format stays auto · \(style.label)."
                        : "   Set Reasoning format → \(style.label).")
                if !config.llmProfiles[idx].reasoningEffort.isOn {
                    print("   Tip: Reasoning effort is off — set it to actually send reasoning.")
                }
            } else if p.reasoningStyleOverride != style {
                print("   Your manual Reasoning format is \(p.effectiveReasoningStyle.label) — left unchanged.")
            }
        case .noneDetected(let inconclusive):
            print(
                inconclusive
                    ? "•  Endpoint accepted the parameter but returned no reasoning output — your model is probably not a reasoning model. You can still force a format via Reasoning format."
                    : "•  No reasoning support detected — the endpoint rejected every reasoning parameter.")
        case .failed(let msg):
            print("✗  Reasoning probe failed: \(msg)")
        case .none:
            print("✗  Reasoning probe: no result.")
        }
    }

    /// Choose the capture audio source. "All system audio" (item 0) forces
    /// capturing everything; when off, capture auto-detects the first enabled
    /// conferencing app that's running, falling back to all system audio if none
    /// are. While all-audio is on, the per-app rows are dimmed/unselectable.
    private func promptMeetingApps() {
        let title = """

            Audio source
            All system audio captures everything. Otherwise capture is scoped to the
            first enabled app that's running (or all audio if none are running).
            """
        // index 0 = All system audio · index 1 = separator · 2… = apps
        func buildItems() -> [MenuItem] {
            let all = config.captureAllAudio
            let enabled = Set(config.enabledMeetingAppIDs)
            var items: [MenuItem] = [
                MenuItem(label: "(\(all ? "●" : " ")) All system audio")
            ]
            items.append(.separator("──────────────────────"))
            for app in MeetingApp.catalog {
                items.append(
                    MenuItem(
                        label: "[\(enabled.contains(app.id) ? "on" : "off")] \(app.label)",
                        enabled: !all
                    ))
            }
            return items
        }

        Menu.run(title: title, items: buildItems, allowBack: true) { i in
            if i == 0 {
                config.captureAllAudio.toggle()
                persistConfig()
                return
            }
            let appIndex = i - 2  // account for All-audio row + separator
            guard MeetingApp.catalog.indices.contains(appIndex) else { return }
            let app = MeetingApp.catalog[appIndex]
            let enabled = Set(config.enabledMeetingAppIDs)
            if enabled.contains(app.id) {
                config.enabledMeetingAppIDs.removeAll { $0 == app.id }
            } else {
                // Preserve catalog order when re-adding.
                let next = enabled.union([app.id])
                config.enabledMeetingAppIDs = MeetingApp.allIDs.filter { next.contains($0) }
            }
            persistConfig()
        }
    }

    /// Read one line from stdin with echo suppressed. Returns nil on EOF or
    /// if the user types `b` / `back` to cancel.
    private func readSecret(_ label: String) -> String? {
        fputs("\(label)  (b = back): ", stdout)
        fflush(stdout)

        var original = termios()
        let haveTermios = (isatty(fileno(stdin)) != 0) && (tcgetattr(fileno(stdin), &original) == 0)
        if haveTermios {
            var raw = original
            raw.c_lflag &= ~UInt(ECHO)
            _ = tcsetattr(fileno(stdin), TCSANOW, &raw)
        }
        defer {
            if haveTermios {
                var r = original
                _ = tcsetattr(fileno(stdin), TCSANOW, &r)
            }
            fputs("\n", stdout)
        }

        guard let raw = readLine() else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if lower == "b" || lower == "back" { return nil }
        return trimmed
    }

    private func promptString(_ kp: WritableKeyPath<Config, String>, label: String) {
        let cur = config[keyPath: kp]
        guard let v = askLine("\(label) [\(cur)]"), !v.isEmpty else { return }
        config[keyPath: kp] = v
        persistConfig()
    }

    private func promptInt(_ kp: WritableKeyPath<Config, Int>, label: String, min lo: Int, max hi: Int) {
        let cur = config[keyPath: kp]
        guard let v = askLine("\(label) [\(cur)]"), !v.isEmpty else { return }
        guard let n = Int(v), n >= lo, n <= hi else {
            print("Expected an integer between \(lo) and \(hi).")
            return
        }
        config[keyPath: kp] = n
        persistConfig()
    }

    private func toggle(_ kp: WritableKeyPath<Config, Bool>, label: String) {
        config[keyPath: kp].toggle()
        persistConfig()
        // No confirmation print — the menu's [bracketed] value reflects the
        // change on its next (in-place) redraw.
    }

    private func persistConfig() {
        do { try config.save() } catch { print("⚠  Failed to save config: \(error.localizedDescription)") }
    }

    // MARK: - Utilities

    private func expand(_ path: String) -> String {
        if path.hasPrefix("~/") { return NSHomeDirectory() + String(path.dropFirst(1)) }
        if path == "~" { return NSHomeDirectory() }
        return path
    }

    // MARK: - Markdown rendering

    // Converts basic markdown to ANSI-styled terminal output for readability.
    // The .md file on disk always receives the raw markdown string.
    private func renderMarkdown(_ text: String) -> String {
        let reset = "\u{001B}[0m"
        let bold = "\u{001B}[1m"
        let dim = "\u{001B}[2m"

        var out: [String] = []
        var inCode = false

        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("```") {
                inCode.toggle()
                if inCode {
                    let lang = String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    out.append(dim + (lang.isEmpty ? "▸ code" : "▸ \(lang)") + reset)
                }
                continue
            }
            if inCode {
                out.append(dim + "  " + raw + reset)
                continue
            }

            if raw.hasPrefix("### ") {
                out.append("\n" + bold + String(raw.dropFirst(4)) + reset)
            } else if raw.hasPrefix("## ") {
                out.append("\n" + bold + String(raw.dropFirst(3)).uppercased() + reset)
            } else if raw.hasPrefix("# ") {
                let title = String(raw.dropFirst(2)).uppercased()
                let bar = String(repeating: "─", count: min(title.count + 4, 60))
                out.append("\n" + bold + bar + "\n  " + title + "\n" + bar + reset)
            } else if raw.hasPrefix("- ") || raw.hasPrefix("* ") {
                out.append("  •  " + inlineFmt(String(raw.dropFirst(2)), bold: bold, reset: reset))
            } else if raw.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
                out.append("  " + inlineFmt(raw, bold: bold, reset: reset))
            } else if raw == "---" || raw == "***" || raw == "___" {
                out.append(String(repeating: "─", count: 60))
            } else {
                out.append(inlineFmt(raw, bold: bold, reset: reset))
            }
        }
        return out.joined(separator: "\n")
    }

    private func inlineFmt(_ text: String, bold: String, reset: String) -> String {
        let cyan = "\u{001B}[36m"
        var s = text
        s = s.replacingOccurrences(
            of: #"\*\*(.+?)\*\*"#,
            with: bold + "$1" + reset, options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"__(.+?)__"#,
            with: bold + "$1" + reset, options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"`([^`]+)`"#,
            with: cyan + "$1" + reset, options: .regularExpression)
        return s
    }
}
