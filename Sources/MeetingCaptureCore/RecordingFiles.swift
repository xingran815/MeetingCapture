import AVFoundation
import Foundation

// How one recording's files relate: meeting.wav, meeting_part2.wav, meeting_part3.wav.
enum RecordingFiles {

    /// Every part of the recording this file belongs to, in order. Given any part,
    /// or a file with no parts, this returns the whole set.
    static func allParts(of path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        let base = baseName(of: url.deletingPathExtension().lastPathComponent)
        let first = dir.appendingPathComponent(base).appendingPathExtension(ext).path

        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let prefix = base + "_part"
        let suffix = "." + ext
        let numbered: [(Int, String)] = names.compactMap { name in
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
            let digits = name.dropFirst(prefix.count).dropLast(suffix.count)
            guard let number = Int(digits), number >= 2 else { return nil }
            return (number, dir.appendingPathComponent(name).path)
        }
        let rest = numbered.sorted { $0.0 < $1.0 }.map(\.1)
        let parts = (FileManager.default.fileExists(atPath: first) ? [first] : []) + rest
        return parts.isEmpty ? [path] : parts
    }

    /// `meeting_part2` becomes `meeting`. Anything else stays as it is.
    static func baseName(of name: String) -> String {
        name.replacingOccurrences(of: "_part\\d+$", with: "", options: .regularExpression)
    }

    /// Length of an audio file in seconds, or nil if it can't be read.
    static func duration(ofAudioAt path: String) -> Double? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
            file.processingFormat.sampleRate > 0
        else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
