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
    /// Each part's times are offset by the real length of the parts before it.
    ///
    /// Speakers are detected separately in each part, so whoever talks first in part
    /// 2 would also be `Speaker 1`, with no link to part 1. Finding from the deep
    /// review: showing that as one speaker states a guess as fact, and a rename would
    /// then merge different people. So later parts carry their own labels, such as
    /// `Speaker 1 (part 2)`, and renaming two to one name is how they're joined.
    func transcribe(parts: [URL]) async throws -> Transcript {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var all: [LabelledSegment] = []
        var notes: [String] = []
        var offset = 0.0
        var detectedSpeakers = false
        for (index, part) in parts.enumerated() {
            // A crashed WAV reads as empty until its header is repaired. Nothing else
            // about the file changes, and a healthy one isn't touched.
            _ = try? WAVRepair.repairHeader(at: part)
            let tracks = try AudioTracks.split(part, into: work)
            if tracks.mic == nil, tracks.system == nil, tracks.noiseOnly.isEmpty {
                notes.append(
                    "\(part.lastPathComponent): no sound on either track. If that's unexpected, "
                        + "check the Screen Recording and Microphone permissions.")
            }
            var mic: [LabelledSegment] = []
            var system: [LabelledSegment] = []
            for track in tracks.noiseOnly {
                notes.append(
                    "\(part.lastPathComponent): the \(track) track held only quiet, steady noise, so it wasn't "
                        + "transcribed. The audio is kept, so you can listen to it.")
            }
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
                detectedSpeakers = detectedSpeakers || !turns.isEmpty
                if index > 0 {
                    system = system.map { SpeakerLabels.markPart($0, number: index + 1) }
                }
            }
            let merged = SpeakerLabels.merge(mic: mic, system: system)
            all += merged.map {
                LabelledSegment(start: $0.start + offset, end: $0.end + offset, speaker: $0.speaker, text: $0.text)
            }
            offset += RecordingFiles.duration(ofAudioAt: part.path) ?? merged.map(\.end).max() ?? 0
        }
        if parts.count > 1 && detectedSpeakers {
            notes.append(
                "This recording has \(parts.count) parts, and speakers are detected separately in each. "
                    + "Speaker 1 (part 2) may be the same person as Speaker 1. Give them one name to join them.")
        }
        return Transcript(segments: all, notes: notes)
    }

    /// Encodes each WAV to M4A, keeping any WAV whose M4A can't be proven good.
    /// Returns one line for each WAV that was kept, and the audio files that remain.
    static func archive(parts: [URL], encoder: AudioEncoding = AACEncoder()) -> (kept: [String], files: [URL]) {
        var kept: [String] = []
        var files: [URL] = []
        for part in parts {
            guard part.pathExtension.lowercased() == "wav" else {
                files.append(part)
                continue
            }
            switch AudioArchive.archive(wav: part, encoder: encoder) {
            case .archived(let m4a):
                files.append(m4a)
            case .keptWAV(let reason):
                kept.append("Kept \(part.lastPathComponent): \(reason).")
                files.append(part)
            }
        }
        return (kept, files)
    }

    /// Finishes a new recording. If transcription fails, the WAVs stay and the
    /// sidecar still says `recording`, so the next launch offers it again.
    ///
    /// Only a transcript with words in it sets `transcribedAt`, which is what lets
    /// retention delete the audio later (finding from the deep review). A capture
    /// with no transcript keeps its audio until the user deals with it.
    static func finish(
        parts: [URL], base: URL, pipeline: RecordingPipeline?, encoder: AudioEncoding = AACEncoder(), now: Date = Date()
    ) async throws -> Transcript? {
        var transcript: Transcript?
        if let pipeline {
            let result = try await pipeline.transcribe(parts: parts)
            try (result.formatted + "\n").write(
                to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            transcript = result
        }
        let archived = archive(parts: parts, encoder: encoder)
        let sidecarURL = RecordingSidecar.url(forBase: base)
        var sidecar = RecordingSidecar.load(at: sidecarURL) ?? RecordingSidecar(createdAt: now, state: .recording)
        sidecar.state = .processed
        sidecar.pid = nil
        sidecar.audioFiles = archived.files.map(\.lastPathComponent)
        // A WAV that couldn't be archived may hold audio the transcript never reached,
        // such as after a stale header, so it mustn't become eligible for deletion.
        if archived.kept.isEmpty, let transcript,
            !transcript.formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            sidecar.transcribedAt = now
        }
        try sidecar.save(to: sidecarURL)
        for line in archived.kept { print("⚠  \(line)") }
        return transcript
    }
}
