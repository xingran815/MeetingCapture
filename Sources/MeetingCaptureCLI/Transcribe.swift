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
    private var pipe: WhisperKit?

    /// `language` is a 2-letter code like "en" or "zh". Pass nil to let
    /// WhisperKit auto-detect via a one-shot detection pass (`detectLanguage:
    /// true`). `.en` models ignore both — they're English-only.
    init(model: String, language: String? = nil) {
        self.modelName = model
        self.language = language
    }

    private var isMultilingual: Bool { !modelName.contains(".en") }

    func load() async throws {
        let t0 = Date()
        print("🧠  Loading model \(modelName)… (first run may download ~ hundreds of MB)")
        let config = WhisperKitConfig(model: modelName, verbose: false, logLevel: .error)
        pipe = try await WhisperKit(config)
        let dt = Date().timeIntervalSince(t0)
        print(String(format: "   ready in %.1fs", dt))
    }

    struct Segment {
        let start: Double
        let end: Double
        let text: String
    }

    func transcribe(wavPath: String) async throws -> (text: String, segments: [Segment]) {
        guard let pipe else { throw NSError(
            domain: "Transcriber", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Transcriber.load() was not called"]
        ) }

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

        // Two-track decoding strategy:
        //
        // - `.en` models: VAD chunking ON. Documented fix for cross-30s
        //   boundary speech loss in English (see CLAUDE.md). The default
        //   quality thresholds (compressionRatio, logProb, firstTokenLogProb)
        //   are tuned on English statistics and catch real hallucinations.
        //
        // - Multilingual models: VAD chunking OFF (use default 30s windowing).
        //   Empirically, VAD-chunked decoding on Chinese audio with the
        //   multilingual `small` model returns zero segments — VAD's energy
        //   threshold appears to misclassify a lot of speech as silence on
        //   our SCStream + mic mix. Default windowing produces clean output.
        //   We also disable the English-tuned quality guards: they routinely
        //   reject valid CJK / Turkish / Arabic / Thai / Hindi / Vietnamese
        //   output as "low confidence," yielding empty transcripts.
        //
        // `usePrefillPrompt: true` ensures the language token reaches the
        // decoder in both paths.
        let options: DecodingOptions
        if isMultilingual {
            options = DecodingOptions(
                task: .transcribe,
                language: resolvedLanguage,
                usePrefillPrompt: true,
                detectLanguage: resolvedLanguage == nil,
                compressionRatioThreshold: nil,
                logProbThreshold: nil,
                firstTokenLogProbThreshold: nil,
                chunkingStrategy: ChunkingStrategy.none
            )
        } else {
            options = DecodingOptions(
                task: .transcribe,
                usePrefillPrompt: true,
                chunkingStrategy: .vad
            )
        }

        let results = try await pipe.transcribe(audioPath: wavPath, decodeOptions: options)
        let dt = Date().timeIntervalSince(t0)

        let text = results.map(\.text).joined(separator: " ")
        let segments: [Segment] = results.flatMap { r in
            r.segments.map {
                Segment(start: Double($0.start), end: Double($0.end), text: $0.text)
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
    private func detectLanguage(pipe: WhisperKit, audioPath: String) async -> String? {
        do {
            let result = try await pipe.detectLanguage(audioPath: audioPath)
            print(String(format: "🌐  Detected language: %@ (%.2f)", result.language, result.langProbs[result.language] ?? 0))
            return result.language
        } catch {
            // Older WhisperKit versions used a different method name.
            return nil
        }
    }

    /// Transcribe multiple WAV files, adjusting timestamps for continuity.
    /// Returns combined text and segments with correct absolute timestamps.
    func transcribe(wavPaths: [String]) async throws -> (text: String, segments: [Segment]) {
        guard !wavPaths.isEmpty else {
            return ("", [])
        }

        var allText: [String] = []
        var allSegments: [Segment] = []
        var timeOffset: Double = 0

        for path in wavPaths {
            let (text, segments) = try await transcribe(wavPath: path)

            // Adjust segment timestamps by the offset
            let adjustedSegments = segments.map { seg in
                Segment(start: seg.start + timeOffset, end: seg.end + timeOffset, text: seg.text)
            }

            allText.append(text)
            allSegments.append(contentsOf: adjustedSegments)

            // Update offset: use the last segment's end time, or estimate from duration
            if let last = segments.last {
                timeOffset += last.end
            }
        }

        return (allText.joined(separator: " "), allSegments)
    }

    /// Format segments as `[HH:MM:SS] text` one per line.
    static func format(segments: [Segment]) -> String {
        segments.map { seg in
            let h = Int(seg.start) / 3600
            let m = (Int(seg.start) % 3600) / 60
            let s = Int(seg.start) % 60
            return String(format: "[%02d:%02d:%02d] %@", h, m, s, cleanSegmentText(seg.text))
        }.joined(separator: "\n")
    }

    /// Strip Whisper special tokens (`<|startoftranscript|>`, `<|12.34|>`, …) from segment text.
    private static func cleanSegmentText(_ s: String) -> String {
        let stripped = s.replacingOccurrences(
            of: #"<\|[^|]*\|>"#,
            with: "",
            options: .regularExpression
        )
        return stripped.trimmingCharacters(in: .whitespaces)
    }
}
