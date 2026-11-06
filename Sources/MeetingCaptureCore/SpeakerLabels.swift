import Foundation

// Who said what. The mic track is `You`. Speaker detection runs on the system track
// only, and its turns become `Speaker 1`, `Speaker 2`, and so on.
//
// Known limits, from the spike and not yet tested on real speech: a third similar
// voice can merge into another, which is why rename and merge exist.
struct SpeakerTurn: Equatable {
    let start: Double
    let end: Double
    let speaker: Int
}

struct LabelledSegment: Equatable {
    let start: Double
    let end: Double
    let speaker: String
    let text: String
}

enum SpeakerLabels {

    static let you = "You"
    /// Used when speaker detection isn't available for the system track.
    static let others = "Others"
    /// The spike showed a stray 0.6 s speaker, so anything shorter goes to a neighbour.
    static let minimumTurn = 1.0

    /// Short turns join a neighbour, then runs by the same speaker join up.
    static func mergeShortTurns(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        let sorted = turns.sorted { $0.start < $1.start }
        guard sorted.count > 1 else { return sorted }
        var kept: [SpeakerTurn] = []
        for (i, turn) in sorted.enumerated() {
            if turn.end - turn.start >= minimumTurn {
                kept.append(turn)
            } else if let last = kept.last {
                kept[kept.count - 1] = SpeakerTurn(start: last.start, end: turn.end, speaker: last.speaker)
            } else if let next = sorted[(i + 1)...].first(where: { $0.end - $0.start >= minimumTurn }) {
                // A short turn at the very start goes to the next real speaker.
                kept.append(SpeakerTurn(start: turn.start, end: turn.end, speaker: next.speaker))
            }
        }
        var merged: [SpeakerTurn] = []
        for turn in kept {
            if let last = merged.last, last.speaker == turn.speaker {
                merged[merged.count - 1] = SpeakerTurn(
                    start: last.start, end: max(last.end, turn.end), speaker: last.speaker)
            } else {
                merged.append(turn)
            }
        }
        return merged
    }

    /// Numbers speakers in the order they first talk.
    private static func names(for turns: [SpeakerTurn]) -> [Int: String] {
        var names: [Int: String] = [:]
        for turn in turns where names[turn.speaker] == nil {
            names[turn.speaker] = "Speaker \(names.count + 1)"
        }
        return names
    }

    private static func speaker(from start: Double, to end: Double, in turns: [SpeakerTurn]) -> Int? {
        var overlap: [Int: Double] = [:]
        for turn in turns {
            let shared = min(end, turn.end) - max(start, turn.start)
            if shared > 0 { overlap[turn.speaker, default: 0] += shared }
        }
        if let best = overlap.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }) { return best.key }
        // Whisper's timing can land in a gap between turns, so use the closest turn.
        let middle = (start + end) / 2
        return turns.min {
            min(abs($0.start - middle), abs($0.end - middle)) < min(abs($1.start - middle), abs($1.end - middle))
        }?.speaker
    }

    /// Each segment goes to the speaker with the most overlap, and splits at word
    /// timestamps where it spans two speakers. With no turns at all, it's `Others`.
    static func label(_ segments: [Transcriber.Segment], turns rawTurns: [SpeakerTurn]) -> [LabelledSegment] {
        let turns = mergeShortTurns(rawTurns)
        guard !turns.isEmpty else {
            return segments.map { LabelledSegment(start: $0.start, end: $0.end, speaker: others, text: $0.text) }
        }
        let names = names(for: turns)
        var out: [LabelledSegment] = []
        for segment in segments {
            let bySegment = speaker(from: segment.start, to: segment.end, in: turns)
            let name = bySegment.flatMap { names[$0] } ?? others
            guard !segment.words.isEmpty else {
                out.append(LabelledSegment(start: segment.start, end: segment.end, speaker: name, text: segment.text))
                continue
            }
            var run: (speaker: Int, start: Double, end: Double, text: String)?
            for word in segment.words {
                let who = speaker(from: word.start, to: word.end, in: turns) ?? bySegment ?? -1
                if let current = run, current.speaker == who {
                    run = (who, current.start, word.end, current.text + word.text)
                } else {
                    if let current = run {
                        out.append(
                            LabelledSegment(
                                start: current.start, end: current.end, speaker: names[current.speaker] ?? others,
                                text: current.text))
                    }
                    run = (who, word.start, word.end, word.text)
                }
            }
            if let current = run {
                out.append(
                    LabelledSegment(
                        start: current.start, end: current.end, speaker: names[current.speaker] ?? others,
                        text: current.text))
            }
        }
        return out
    }

    static func labelMic(_ segments: [Transcriber.Segment]) -> [LabelledSegment] {
        segments.map { LabelledSegment(start: $0.start, end: $0.end, speaker: you, text: $0.text) }
    }

    /// Both tracks in time order. On a tie the mic goes first, for a stable result.
    static func merge(mic: [LabelledSegment], system: [LabelledSegment]) -> [LabelledSegment] {
        let tagged = mic.map { (0, $0) } + system.map { (1, $0) }
        return tagged.sorted { ($0.1.start, $0.0) < ($1.1.start, $1.0) }.map(\.1)
    }

    /// Whisper's own word for nothing being said. Anything else in brackets stays,
    /// such as `[laughter]`, since it may be real.
    static func isSilenceMarker(_ text: String) -> Bool {
        ["[BLANK_AUDIO]", "(BLANK_AUDIO)"].contains(text.trimmingCharacters(in: .whitespaces).uppercased())
    }

    /// `[00:01:12] Speaker 1: text`, one per line.
    static func format(_ segments: [LabelledSegment]) -> String {
        segments.compactMap { segment in
            let text = Transcriber.cleanSegmentText(segment.text)
            guard !text.isEmpty, !isSilenceMarker(text) else { return nil }
            let t = Int(segment.start)
            return String(format: "[%02d:%02d:%02d] ", t / 3600, (t % 3600) / 60, t % 60)
                + "\(segment.speaker): \(text)"
        }.joined(separator: "\n")
    }

    /// Renames a speaker throughout a transcript. Renaming to a name already in use
    /// merges the two. Only the label is touched, never what was said.
    static func rename(_ from: String, to: String, in transcript: String) -> String {
        let prefix = try! NSRegularExpression(
            pattern: #"^(\[\d{2}:\d{2}:\d{2}\] )(.+?)(: )"#, options: .anchorsMatchLines)
        let ns = transcript as NSString
        var out = ""
        var cursor = 0
        for match in prefix.matches(in: transcript, range: NSRange(location: 0, length: ns.length)) {
            let label = match.range(at: 2)
            guard ns.substring(with: label) == from else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: label.location - cursor)) + to
            cursor = label.location + label.length
        }
        return out + ns.substring(from: cursor)
    }

    /// A trimmed name, or nil if it would break the `[time] name: text` format.
    static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains(":"), !name.contains(where: \.isNewline) else { return nil }
        return name
    }

    /// Renames in the file, and remembers it in the recording's sidecar if it has one.
    static func rename(_ from: String, to: String, transcriptAt url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        try rename(from, to: to, in: text).write(to: url, atomically: true, encoding: .utf8)
        let sidecarURL = RecordingSidecar.url(forBase: url.deletingPathExtension())
        if var sidecar = RecordingSidecar.load(at: sidecarURL) {
            sidecar.speakerNames[from] = to
            try sidecar.save(to: sidecarURL)
        }
    }

    /// The labels in a transcript, in order of first appearance.
    static func speakers(in transcript: String) -> [String] {
        let prefix = try! NSRegularExpression(pattern: #"^\[\d{2}:\d{2}:\d{2}\] (.+?): "#, options: .anchorsMatchLines)
        let ns = transcript as NSString
        var seen: [String] = []
        for match in prefix.matches(in: transcript, range: NSRange(location: 0, length: ns.length)) {
            let label = ns.substring(with: match.range(at: 1))
            if !seen.contains(label) { seen.append(label) }
        }
        return seen
    }
}
