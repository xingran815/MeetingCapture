import AVFoundation
import Foundation

// How one recording's files relate: meeting.wav, meeting_part2.wav, meeting_part3.wav.
// Each part may already be an M4A, because they're archived one at a time.
enum RecordingFiles {

    private static let audioExtensions: Set<String> = ["wav", "m4a"]

    /// Every part of the recording this file belongs to, in order. Given any part,
    /// or a file with no parts, this returns the whole set. If a part exists as both
    /// WAV and M4A, the extension asked for wins.
    static func allParts(of path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let dir = url.deletingLastPathComponent()
        let base = baseName(of: url.deletingPathExtension().lastPathComponent)
        let accepted = audioExtensions.contains(ext) ? audioExtensions : [ext]

        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var parts: [Int: String] = [:]
        for name in names {
            let nameExt = (name as NSString).pathExtension.lowercased()
            guard accepted.contains(nameExt), let number = partNumber(of: name, base: base) else { continue }
            if parts[number] == nil || nameExt == ext { parts[number] = name }
        }
        // The file asked for is always in the answer, even with a look-alike beside it.
        let asked = url.lastPathComponent
        if names.contains(asked), let number = partNumber(of: asked, base: base) { parts[number] = asked }
        let ordered = parts.keys.sorted().compactMap { parts[$0] }.map { dir.appendingPathComponent($0).path }
        return ordered.isEmpty ? [path] : ordered
    }

    /// 1 for `meeting.wav` or `meeting_part1.wav`, N for `meeting_partN.wav`, nil if
    /// it's another recording's.
    private static func partNumber(of name: String, base: String) -> Int? {
        let stem = (name as NSString).deletingPathExtension
        if stem == base { return 1 }
        guard stem.hasPrefix(base + "_part"), let number = Int(stem.dropFirst(base.count + 5)), number >= 1 else {
            return nil
        }
        return number
    }

    /// `meeting_part2` becomes `meeting`. Anything else stays as it is.
    static func baseName(of name: String) -> String {
        name.replacingOccurrences(of: "_part\\d+$", with: "", options: .regularExpression)
    }

    /// The recording a file stem belongs to, counting its cleaned mic: `meeting_clean` and
    /// `meeting_part2_clean` both belong to `meeting`. Only an exact `_clean` ending counts,
    /// so `meeting_clean_notes` is someone else's file.
    static func ownerBase(of stem: String) -> String {
        let suffix = "_clean"
        return baseName(of: stem.hasSuffix(suffix) ? String(stem.dropLast(suffix.count)) : stem)
    }

    /// Why a new recording can't be written here, or nil if it can. Reusing a name
    /// would truncate a WAV that may be the only copy, overwrite the transcript and
    /// M4A, and join old parts into the new recording.
    static func conflict(forNewRecordingAt base: URL) -> String? {
        let stem = base.lastPathComponent
        guard baseName(of: stem) == stem else {
            return "a name ending in _part2 is kept for the later files of a long recording. Choose another name."
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.deletingLastPathComponent().path)) ?? []
        // Compared without case, because the default Mac disk treats `A.wav` and `a.wav`
        // as one file, and writing one would erase the other.
        let lowered = stem.lowercased()
        let taken = names.sorted().first { name in
            let candidate = name.lowercased()
            if candidate == lowered + ".mcmeta.json" || candidate == lowered + ".txt" { return true }
            // The user's layer (M5.1): a new recording here would take over an old one's
            // title, edits and notes, and could send those notes out. From the M5.1 deep review.
            if [".notes.md", ".edits.json", ".report.json"].contains(where: { candidate == lowered + $0 }) {
                return true
            }
            return audioExtensions.contains((candidate as NSString).pathExtension)
                && partNumber(of: candidate, base: lowered) != nil
        }
        return taken.map { "\($0) already exists, and recording here would replace it. Choose another name." }
    }

    /// Length of an audio file in seconds, or nil if it can't be read.
    static func duration(ofAudioAt path: String) -> Double? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
            file.processingFormat.sampleRate > 0
        else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
