import Foundation
import SpeakerKit
import WhisperKit

// The one path from recorded files to a labelled transcript and small audio:
// transcribe and detect speakers from the WAV, encode M4A, verify it, delete the WAV.
// The WAV is the source because that guarantees no quality loss.

protocol SpeechTranscribing: AnyObject {
    func transcribeSegments(path: String) async throws -> [Transcriber.Segment]
}

protocol SpeakerDetecting: AnyObject {
    func detectTurns(path: String) async throws -> [SpeakerTurn]
}

@available(macOS 14.0, *)
extension Transcriber: SpeechTranscribing {
    func transcribeSegments(path: String) async throws -> [Segment] {
        try await transcribe(wavPath: path).segments
    }
}

/// SpeakerKit's model downloads on first use, like Whisper's.
@available(macOS 14.0, *)
final class SpeakerKitDetector: SpeakerDetecting {
    private var kit: SpeakerKit?

    func detectTurns(path: String) async throws -> [SpeakerTurn] {
        if kit == nil {
            print("🗣  Loading speaker detection… (first run downloads about 11 MB)")
            kit = try await SpeakerKit(PyannoteConfig(verbose: false))
        }
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        let result = try await kit!.diarize(audioArray: audio)
        return result.segments.compactMap { segment in
            guard let id = segment.speaker.speakerId else { return nil }
            return SpeakerTurn(start: Double(segment.startTime), end: Double(segment.endTime), speaker: id)
        }
    }
}

struct RecordingPipeline {

    struct Transcript {
        let segments: [LabelledSegment]
        /// Things the user should know, such as speaker detection failing.
        let notes: [String]
        var formatted: String { SpeakerLabels.format(segments) }
    }

    let transcriber: SpeechTranscribing
    let detector: SpeakerDetecting?

    /// Transcribes every part of a recording. A part with a silent track skips it,
    /// which is how a recording with the mic off ends up with no `You` label.
    ///
    /// Each part's times are offset by the real length of the parts before it, and
    /// speakers are numbered within the whole recording only as far as a part's
    /// model allows: `Speaker 1` in part 2 may not be `Speaker 1` in part 1. A
    /// 30-minute boundary in a long call can therefore swap labels. Unsure how often.
    func transcribe(parts: [URL]) async throws -> Transcript {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var all: [LabelledSegment] = []
        var notes: [String] = []
        var offset = 0.0
        for part in parts {
            let tracks = try AudioTracks.split(part, into: work)
            var mic: [LabelledSegment] = []
            var system: [LabelledSegment] = []
            if let url = tracks.mic {
                mic = SpeakerLabels.labelMic(try await transcriber.transcribeSegments(path: url.path))
            }
            if let url = tracks.system {
                let segments = try await transcriber.transcribeSegments(path: url.path)
                var turns: [SpeakerTurn] = []
                if let detector {
                    do {
                        turns = try await detector.detectTurns(path: url.path)
                    } catch {
                        notes.append(
                            "Speaker detection failed, so the other side is labelled Others: \(error.localizedDescription)"
                        )
                    }
                }
                system = SpeakerLabels.label(segments, turns: turns)
            }
            let merged = SpeakerLabels.merge(mic: mic, system: system)
            all += merged.map {
                LabelledSegment(start: $0.start + offset, end: $0.end + offset, speaker: $0.speaker, text: $0.text)
            }
            offset += RecordingFiles.duration(ofAudioAt: part.path) ?? merged.map(\.end).max() ?? 0
        }
        return Transcript(segments: all, notes: notes)
    }

    /// Encodes each WAV to M4A, keeping any WAV whose M4A can't be proven good.
    /// Returns one line for each WAV that was kept.
    static func archive(parts: [URL], encoder: AudioEncoding = AACEncoder()) -> [String] {
        parts.compactMap { part in
            guard part.pathExtension.lowercased() == "wav" else { return nil }
            if case .keptWAV(let reason) = AudioArchive.archive(wav: part, encoder: encoder) {
                return "Kept \(part.lastPathComponent): \(reason)."
            }
            return nil
        }
    }

    /// Finishes a new recording. If transcription fails, the WAVs stay and the
    /// sidecar still says `recording`, so the next launch offers it again.
    static func finish(
        parts: [URL], base: URL, pipeline: RecordingPipeline?, encoder: AudioEncoding = AACEncoder()
    ) async throws -> Transcript? {
        var transcript: Transcript?
        if let pipeline {
            let result = try await pipeline.transcribe(parts: parts)
            try (result.formatted + "\n").write(
                to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            transcript = result
        }
        let kept = archive(parts: parts, encoder: encoder)
        let sidecarURL = RecordingSidecar.url(forBase: base)
        var sidecar = RecordingSidecar.load(at: sidecarURL) ?? RecordingSidecar(createdAt: Date(), state: .recording)
        sidecar.state = .processed
        try sidecar.save(to: sidecarURL)
        for line in kept { print("⚠  \(line)") }
        return transcript
    }
}
