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
        let ordered = parts.keys.sorted().compactMap { parts[$0] }.map { dir.appendingPathComponent($0).path }
        return ordered.isEmpty ? [path] : ordered
    }

    /// 1 for `meeting.wav`, N for `meeting_partN.wav`, nil if it's another recording's.
    private static func partNumber(of name: String, base: String) -> Int? {
        let stem = (name as NSString).deletingPathExtension
        if stem == base { return 1 }
        guard stem.hasPrefix(base + "_part"), let number = Int(stem.dropFirst(base.count + 5)), number >= 2 else {
            return nil
        }
        return number
    }

    /// `meeting_part2` becomes `meeting`. Anything else stays as it is.
    static func baseName(of name: String) -> String {
        name.replacingOccurrences(of: "_part\\d+$", with: "", options: .regularExpression)
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
        let taken = names.sorted().first { name in
            if name == stem + ".mcmeta.json" || name == stem + ".txt" { return true }
            return audioExtensions.contains((name as NSString).pathExtension.lowercased())
                && partNumber(of: name, base: stem) != nil
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
