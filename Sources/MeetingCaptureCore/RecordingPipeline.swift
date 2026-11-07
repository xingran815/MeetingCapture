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
    /// SpeakerKit's default of 0.6 split one synthetic voice into 3 speakers. On mixes of
    /// known voices, 0.7 and below still split it, 0.8 and 0.9 got every mix right, and 1.0
    /// merged two real voices, so this errs away from merging. Only tested on synthetic
    /// voices (`scripts/echo-lab/diar_mix.py`), so unsure for real people.
    static let defaultClusterThreshold: Float = 0.8
    var clusterThreshold = SpeakerKitDetector.defaultClusterThreshold

    func detectTurns(path: String) async throws -> [SpeakerTurn] {
        if kit == nil {
            print("🗣  Loading speaker detection… (first run downloads about 11 MB)")
            kit = try await SpeakerKit(PyannoteConfig(verbose: false))
        }
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        let options = PyannoteDiarizationOptions(clusterDistanceThreshold: clusterThreshold)
        let result = try await kit!.diarize(audioArray: audio, options: options)
        return result.segments.compactMap { segment in
            guard let id = segment.speaker.speakerId else { return nil }
            return SpeakerTurn(start: Double(segment.startTime), end: Double(segment.endTime), speaker: id)
        }
    }
}

/// The steps after a call, in order. `writingReport` belongs to the summary, after these.
public enum ProcessingStage: String, CaseIterable, Sendable {
    case removingEcho, transcribing, labellingSpeakers, savingAudio, writingReport

    public var title: String {
        switch self {
        case .removingEcho: return "Removing echo from your mic"
        case .transcribing: return "Transcribing"
        case .labellingSpeakers: return "Labelling speakers"
        case .savingAudio: return "Saving audio as M4A"
        case .writingReport: return "Writing the report"
        }
    }
}

struct RecordingPipeline {

    struct Transcript {
        let segments: [LabelledSegment]
        /// Things the user should know, such as speaker detection failing.
        var notes: [String]
        /// A track sounded like only noise, so its lines may be invented and only the
        /// audio can settle it. Finding from the deep-review re-check, D-54 and D-56.
        var hasDoubtfulTrack = false
        /// Each part as recorded but with the mic's echo gone (cleaned mic + system), if asked for.
        var cleanedAudio: [URL] = []
        /// Start times of mic lines left out as leftover echo, across the whole recording.
        var leftOutLines: [String] = []
        var formatted: String { SpeakerLabels.format(segments) }
    }

    let transcriber: SpeechTranscribing
    let detector: SpeakerDetecting?
    /// Off for `--no-aec` and the AEC setting.
    var removeEcho = true
    /// Told as each stage starts, with the part number (1-based) and the part count.
    /// The app shows it; the terminal leaves it nil.
    var onStage: ((ProcessingStage, Int, Int) -> Void)? = nil

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
    ///
    /// The mic goes through `EchoRemover` first, working on copies, so the raw part is
    /// never changed. If that fails, the raw mic is transcribed instead and a note says so.
    func transcribe(parts: [URL], keepingCleanedAudio: Bool = false) async throws -> Transcript {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var all: [LabelledSegment] = []
        var notes: [String] = []
        var offset = 0.0
        var detectedSpeakers = false
        var hasDoubtfulTrack = false
        var cleanedAudio: [URL] = []
        var leftOutLines: [String] = []
        var pendingClean: [(mic: URL, system: URL, to: URL)] = []
        for (index, part) in parts.enumerated() {
            // A crashed WAV reads as empty until its header is repaired. Nothing else
            // about the file changes, and a healthy one isn't touched.
            _ = try? WAVRepair.repairHeader(at: part)
            let tracks = try AudioTracks.split(part, into: work)
            if tracks.mic == nil, tracks.system == nil {
                notes.append(
                    "\(part.lastPathComponent): no sound on either track. If that's unexpected, "
                        + "check the Screen Recording and Microphone permissions.")
            }
            var mic: [LabelledSegment] = []
            var system: [LabelledSegment] = []
            for track in tracks.soundsLikeNoise {
                hasDoubtfulTrack = true
                notes.append(
                    "\(part.lastPathComponent): the \(track) track sounded like only quiet, steady noise, so any "
                        + "lines from it may be invented. This recording's audio won't be deleted automatically, "
                        + "so you can check them against it.")
            }
            if let url = tracks.mic {
                var source = url
                var evidence: EchoEvidence?
                if removeEcho, let system = tracks.system {
                    onStage?(.removingEcho, index + 1, parts.count)
                    do {
                        let cleaned = work.appendingPathComponent(UUID().uuidString + ".wav")
                        if let result = try EchoRemover.clean(mic: url, system: system, to: cleaned) {
                            source = result.cleaned
                            evidence = result.evidence
                            if result.lagMoved {
                                notes.append(
                                    "\(part.lastPathComponent): the delay between the tracks moved during this part, "
                                        + "so some of the other side's voice may remain under You.")
                            }
                        } else if tracks.soundsLikeNoise.isEmpty {
                            // A noise track has its own note, and wouldn't show an echo anyway.
                            notes.append(
                                "\(part.lastPathComponent): no echo could be measured between the tracks, "
                                    + "so the mic was used as recorded, and its lines may include the other side.")
                        }
                    } catch {
                        notes.append(
                            "\(part.lastPathComponent): echo removal failed, so the raw mic was transcribed, "
                                + "and its lines may include the other side: \(error.localizedDescription)")
                    }
                }
                onStage?(.transcribing, index + 1, parts.count)
                mic = SpeakerLabels.labelMic(try await transcriber.transcribeSegments(path: source.path))
                if let evidence {
                    let dropped = mic.filter { evidence.looksLikeEcho(start: $0.start, end: $0.end) }
                    let kept = mic.filter { !evidence.looksLikeEcho(start: $0.start, end: $0.end) }
                    leftOutLines += dropped.map { Self.clock($0.start + offset) }
                    if !dropped.isEmpty {
                        // Times only: a note can reach a log, and a line's words must not.
                        let times = dropped.map { Self.clock($0.start) }
                        notes.append(
                            "\(part.lastPathComponent): left out \(dropped.count) mic line(s) at "
                                + "\(times.joined(separator: ", ")) that were only "
                                + "leftover echo, judged by timing and level, not by their words.")
                    }
                    mic = kept
                }
                if keepingCleanedAudio, source != url, let system = tracks.system {
                    pendingClean.append((source, system, Self.cleanedURL(for: part)))
                }
            }
            if let url = tracks.system {
                onStage?(.transcribing, index + 1, parts.count)
                let segments = try await transcriber.transcribeSegments(path: url.path)
                var turns: [SpeakerTurn] = []
                if let detector {
                    onStage?(.labellingSpeakers, index + 1, parts.count)
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
        // The file to listen to: the recording's two channels, with the mic's echo gone,
        // the way the call sounded minus the echo. The user asked for it (M3.2). Only now: if a later
        // part throws, a file written earlier would be listed nowhere, and retention would
        // never remove it. From the M3.2 deep review.
        for clean in pendingClean {
            // Never over a file that may be something else of the user's.
            guard !FileManager.default.fileExists(atPath: clean.to.path),
                !FileManager.default.fileExists(
                    atPath: clean.to.deletingPathExtension().appendingPathExtension("m4a").path)
            else { continue }
            // Written in the temporary folder and moved in whole: a mix that fails partway, on a
            // full disk say, then leaves nothing half-written that retention could never remove.
            // From the M3.2 post-listen review.
            let scratch = work.appendingPathComponent(UUID().uuidString + ".wav")
            do {
                try EchoRemover.mix(mic: clean.mic, system: clean.system, to: scratch)
                try FileManager.default.moveItem(at: scratch, to: clean.to)
                cleanedAudio.append(clean.to)
            } catch {
                // Only a file this run made: the name was free a moment ago.
                try? FileManager.default.removeItem(at: clean.to)
            }
        }
        if parts.count > 1 && detectedSpeakers {
            notes.append(
                "This recording has \(parts.count) parts, and speakers are detected separately in each. "
                    + "Speaker 1 (part 2) may be the same person as Speaker 1. Give them one name to join them.")
        }
        return Transcript(
            segments: all, notes: notes, hasDoubtfulTrack: hasDoubtfulTrack, cleanedAudio: cleanedAudio,
            leftOutLines: leftOutLines)
    }

    private static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return whole < 3600
            ? String(format: "%d:%02d", whole / 60, whole % 60)
            : String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
    }

    /// Where the listening copy goes: the recording with the mic's echo removed.
    /// `meeting.wav` gives `meeting_clean.wav`, and `meeting_part2.wav` gives
    /// `meeting_part2_clean.wav`. Neither reads as a part of the recording.
    static func cleanedURL(for part: URL) -> URL {
        part.deletingLastPathComponent()
            .appendingPathComponent(part.deletingPathExtension().lastPathComponent + "_clean")
            .appendingPathExtension("wav")
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
        parts: [URL], base: URL, pipeline: RecordingPipeline?, encoder: AudioEncoding = AACEncoder(),
        now: Date = Date(),
        onStage: ((ProcessingStage, Int, Int) -> Void)? = nil
    ) async throws -> Transcript? {
        var transcript: Transcript?
        if let pipeline {
            let result = try await pipeline.transcribe(parts: parts, keepingCleanedAudio: true)
            try (result.formatted + "\n").write(
                to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            transcript = result
        }
        onStage?(.savingAudio, 1, 1)
        let archived = archive(parts: parts, encoder: encoder)
        let sidecarURL = RecordingSidecar.url(forBase: base)
        var sidecar = RecordingSidecar.load(at: sidecarURL) ?? RecordingSidecar(createdAt: now, state: .recording)
        sidecar.state = .processed
        sidecar.pid = nil
        // The cleaned mic is extra, made from the raw part, which is archived on its own
        // above. So a problem here can't cost the recording, or block retention's proof.
        let cleaned = archive(parts: transcript?.cleanedAudio ?? [], encoder: encoder)
        sidecar.audioFiles = (archived.files + cleaned.files).map(\.lastPathComponent)
        // Lasts past the terminal. Retention isn't held for these, as it is for a doubtful
        // track: most calls have some, so it would never run (D-73).
        sidecar.leftOutLines = transcript?.leftOutLines
        // A WAV that couldn't be archived may hold audio the transcript never reached,
        // such as after a stale header, so it mustn't become eligible for deletion. The
        // same goes for a doubtful track, because only the audio can settle its lines.
        if archived.kept.isEmpty, let transcript, !transcript.hasDoubtfulTrack,
            !transcript.formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            sidecar.transcribedAt = now
        }
        try sidecar.save(to: sidecarURL)
        // With a transcript these go in its notes, so the app shows them too; the terminal
        // prints notes. From the M5 review.
        let kept = archived.kept + cleaned.kept
        if transcript != nil {
            transcript?.notes += kept
        } else {
            for line in kept { print("⚠  \(line)") }
        }
        return transcript
    }
}
