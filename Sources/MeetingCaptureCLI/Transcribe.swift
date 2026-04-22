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
    private var pipe: WhisperKit?

    init(model: String) {
        self.modelName = model
    }

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
        // VAD chunking: split at silence instead of at hard 30 s boundaries, so
        // speech that straddles a boundary doesn't get dropped as "no speech".
        let options = DecodingOptions(chunkingStrategy: .vad)
        let results = try await pipe.transcribe(audioPath: wavPath, decodeOptions: options)
        let dt = Date().timeIntervalSince(t0)

        let text = results.map(\.text).joined(separator: " ")
        let segments: [Segment] = results.flatMap { r in
            r.segments.map {
                Segment(start: Double($0.start), end: Double($0.end), text: $0.text)
            }
        }

        print(String(format: "   done in %.1fs (%d segments)", dt, segments.count))
        return (text, segments)
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
