import Foundation
import WhisperKit

// Thin WhisperKit wrapper.
//
// First run for a given model: downloads CoreML weights from Hugging Face
// (argmaxinc/whisperkit-coreml) into WhisperKit's default cache, then
// compiles them. Subsequent runs load from cache.
//
// Output: combined text + per-segment timestamps. We keep structured
// segments around so the eventual LLM-summary step can slice by time.
@available(macOS 14.0, *)
final class Transcriber {

    let modelName: String
    let language: String?
    let modelFolder: String?
    private var pipe: WhisperKit?

    /// `language` is a 2-letter code like "en" or "zh". Pass nil to let
    /// WhisperKit auto-detect via a one-shot detection pass (`detectLanguage:
    /// true`). `.en` models ignore both — they're English-only.
    /// `modelFolder` loads an already-downloaded model and skips the download.
    init(model: String, language: String? = nil, modelFolder: String? = nil) {
        self.modelName = model
        self.language = language
        self.modelFolder = modelFolder
    }

    private var isMultilingual: Bool { !modelName.contains(".en") }

    func load() async throws {
        let t0 = Date()
        print("🧠  Loading model \(modelName)… (first run may download ~ hundreds of MB)")
        let config = WhisperKitConfig(
            model: modelName,
            modelFolder: modelFolder,
            verbose: false,
            logLevel: .error,
            download: modelFolder == nil
        )
        pipe = try await WhisperKit(config)
        let dt = Date().timeIntervalSince(t0)
        print(String(format: "   ready in %.1fs", dt))
    }

    struct Word: Equatable {
        let start: Double
        let end: Double
        let text: String
    }

    struct Segment {
        let start: Double
        let end: Double
        let text: String
        /// Empty if the model gave no word timings.
        var words: [Word] = []
    }

    func transcribe(wavPath: String) async throws -> (text: String, segments: [Segment]) {
        guard let pipe else {
            throw NSError(
                domain: "Transcriber", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Transcriber.load() was not called"]
            )
        }

        let t0 = Date()
        print("📝  Transcribing \(wavPath)…")

        // Resolve the language to pin. For multilingual models with no
        // user-supplied language, run a one-shot detection pass *before* the
        // main transcribe call. Doing detection in-line via
        // `DecodingOptions.detectLanguage = true` interacts badly with VAD
        // chunking and tends to drop the first chunk's content.
        var resolvedLanguage = language
        if isMultilingual && resolvedLanguage == nil {
            if let detected = await detectLanguage(pipe: pipe, audioPath: wavPath) {
                resolvedLanguage = detected
            }
            // If detection failed, fall through with language = nil and let
            // DecodingOptions.detectLanguage = true handle it (degraded path).
        }

        if isMultilingual {
            print("   language: \(resolvedLanguage ?? "auto-detect (in-line)")")
        }

        // One decoding setup for every model, with WhisperKit's VAD chunking off.
        //
        // - VAD chunking silently lost speech after silence on `.en` models: a short
        //   sentence after 6, 60 or 120 s of silence came back empty. Mixed recordings
        //   rarely hit that, but a separated track is mostly silence. On Chinese with
        //   the multilingual model, VAD returned zero segments.
        // - The default quality thresholds are tuned on English and reject valid CJK,
        //   Turkish, Arabic, Thai, Hindi and Vietnamese output, so they're off.
        //
        // Measured on 30 min of real English speech with `.en`: 3,179 words with VAD,
        // 3,148 with this setup. An earlier 22 s dropout at a 30 s window boundary was
        // the reason for VAD. It isn't proven gone: with `logProbThreshold` off, any
        // window scored as no speech is skipped whole, however confident the words, and
        // that may explain the 29 s gap in dev/evidence/2026-11-06-m3-real-audio.md.
        //
        // `usePrefillPrompt: true` ensures the language token reaches the decoder.
        let options = DecodingOptions(
            task: .transcribe,
            language: isMultilingual ? resolvedLanguage : nil,
            usePrefillPrompt: true,
            detectLanguage: isMultilingual && resolvedLanguage == nil,
            wordTimestamps: true,
            compressionRatioThreshold: nil,
            logProbThreshold: nil,
            firstTokenLogProbThreshold: nil,
            chunkingStrategy: ChunkingStrategy.none
        )

        let results = try await pipe.transcribe(audioPath: wavPath, decodeOptions: options)
        let dt = Date().timeIntervalSince(t0)

        let text = results.map(\.text).joined(separator: " ")
        let segments: [Segment] = results.flatMap { r in
            r.segments.map {
                Segment(
                    start: Double($0.start), end: Double($0.end), text: $0.text,
                    words: ($0.words ?? []).map { Word(start: Double($0.start), end: Double($0.end), text: $0.word) })
            }
        }

        print(String(format: "   done in %.1fs (%d segments)", dt, segments.count))

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("⚠  Transcription produced no text. Try --language <code> to pin, or check audio with `afinfo`.")
        }

        return (text, segments)
    }

    /// Best-effort language detection. Returns nil on any failure so the
    /// caller can fall back to in-line detection.
    ///
    /// Finding from the deep review: WhisperKit listens to the first 30 s only, and
    /// on a mic track that's often just room noise, which came back as Welsh and took
    /// the English speech after it with it. So this listens where the track is loudest.
    private func detectLanguage(pipe: WhisperKit, audioPath: String) async -> String? {
        do {
            let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath)
            let window = Self.loudestWindow(in: samples, length: Self.detectionWindow, step: WhisperKit.sampleRate)
            let result = try await pipe.detectLangauge(audioArray: Array(samples[window]))
            print(
                String(
                    format: "🌐  Detected language: %@ (%.2f)", result.language, result.langProbs[result.language] ?? 0))
            return result.language
        } catch {
            // Older WhisperKit versions used a different method name.
            return nil
        }
    }

    /// What Whisper hears at once: 30 s at its 16 kHz.
    private static let detectionWindow = 30 * WhisperKit.sampleRate

    /// The window with the most energy, moving `step` samples at a time. The first
    /// wins a tie, so all-silent audio gives the start.
    static func loudestWindow(in samples: [Float], length: Int, step: Int) -> Range<Int> {
        guard samples.count > length, step > 0 else { return 0..<min(length, samples.count) }
        var running: Float = 0
        for sample in samples[0..<length] { running += sample * sample }
        var best = running
        var bestStart = 0
        var start = 0
        while start + step + length <= samples.count {
            for sample in samples[start..<(start + step)] { running -= sample * sample }
            for sample in samples[(start + length)..<(start + length + step)] { running += sample * sample }
            start += step
            if running > best {
                best = running
                bestStart = start
            }
        }
        return bestStart..<(bestStart + length)
    }

    /// Strip Whisper special tokens (`<|startoftranscript|>`, `<|12.34|>`, …) from segment text.
    static func cleanSegmentText(_ s: String) -> String {
        let stripped = s.replacingOccurrences(
            of: #"<\|[^|]*\|>"#,
            with: "",
            options: .regularExpression
        )
        return stripped.trimmingCharacters(in: .whitespaces)
    }
}
