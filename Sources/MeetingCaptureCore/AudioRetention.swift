import Foundation

/// `<base>.mcmeta.json`, next to a recording made by this version. Its presence is
/// what makes audio eligible for automatic deletion: recordings without one are
/// never touched (D-10).
struct RecordingSidecar: Codable, Equatable {
    enum State: String, Codable {
        case recording
        case processed
    }

    var version = 1
    var createdAt: Date
    var state: State
    /// Label as first assigned, such as "Speaker 1", to the name the user chose.
    var speakerNames: [String: String] = [:]
    /// The process writing this recording, so another one doesn't take it for a crash.
    var pid: Int32?
    /// When a transcript with words in it was saved. Retention counts from here, and
    /// audio without it is never deleted, because the audio would be all there is.
    var transcribedAt: Date?
    /// Exactly the audio files this recording ended with. Retention deletes these and
    /// nothing else, so a similar name can't bring another recording's files with it.
    var audioFiles: [String]?

    /// The sidecar for a recording this process is about to start.
    static func started(now: Date = Date()) -> RecordingSidecar {
        RecordingSidecar(createdAt: now, state: .recording, pid: getpid())
    }

    static func url(forBase base: URL) -> URL {
        base.appendingPathExtension("mcmeta.json")
    }

    static func load(at url: URL) -> RecordingSidecar? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingSidecar.self, from: data)
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

enum AudioRetention {

    static let validDays = 1...3650
    /// `0` means keep forever.
    static func isValid(days: Int) -> Bool { days == 0 || validDays.contains(days) }

    private static let sidecarSuffix = ".mcmeta.json"
    private static let audioExtensions: Set<String> = ["wav", "m4a"]

    /// Deletes audio older than the limit, for recordings with a readable sidecar.
    /// Returns what it deleted. Transcripts, summaries and reports stay, and so does
    /// the sidecar, because it still holds the speaker names.
    ///
    /// Audio stays if the sidecar can't be read, because the age is unknown. It also
    /// stays if the recording has no transcript with words in it, which covers one
    /// still marked `recording` and one captured with transcription off.
    @discardableResult
    static func clean(in dir: URL, days: Int, now: Date) -> [URL] {
        guard days > 0 else { return [] }
        let limit = now.addingTimeInterval(-Double(days) * 86_400)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var deleted: [URL] = []
        for name in names where name.hasSuffix(sidecarSuffix) {
            guard let sidecar = RecordingSidecar.load(at: dir.appendingPathComponent(name)),
                sidecar.state == .processed,
                let transcribedAt = sidecar.transcribedAt, transcribedAt < limit,
                let files = sidecar.audioFiles
            else { continue }
            // Names come from the sidecar, so each must be a real entry in this folder.
            // That also rules out a path pointing anywhere else.
            for file in files where names.contains(file) && isAudio(file) {
                let url = dir.appendingPathComponent(file)
                if (try? FileManager.default.removeItem(at: url)) != nil { deleted.append(url) }
            }
        }
        return deleted.sorted { $0.path < $1.path }
    }

    /// WAVs that belong to no recording made by this version, which only
    /// `--audio-cleanup` may touch, after asking.
    static func unmanagedWAVs(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let sidecars = names.filter { $0.hasSuffix(sidecarSuffix) }.map { name in
            (
                base: String(name.dropLast(sidecarSuffix.count)),
                files: RecordingSidecar.load(at: dir.appendingPathComponent(name))?.audioFiles
            )
        }
        return
            names
            .filter { name in
                guard (name as NSString).pathExtension.lowercased() == "wav" else { return false }
                let stem = (name as NSString).deletingPathExtension
                return !sidecars.contains { sidecar in
                    if sidecar.base == stem { return true }
                    // No list yet means it's unfinished or unreadable, so any of its parts count.
                    guard let files = sidecar.files else { return RecordingFiles.baseName(of: stem) == sidecar.base }
                    return files.contains(name)
                }
            }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    /// Whether a process is alive. `EPERM` still means it exists.
    static func isRunning(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Recordings a crash left unfinished: the sidecar still says `recording` and the
    /// process that wrote it is gone. Returns each one's first remaining part, which
    /// is an M4A if a crash came partway through archiving.
    ///
    /// A process id can be reused, in which case the offer waits until that process
    /// ends. That delays it and loses nothing.
    static func unfinished(in dir: URL, isRunning: (Int32) -> Bool = isRunning(pid:)) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(sidecarSuffix) }.sorted().compactMap { name in
            guard let sidecar = RecordingSidecar.load(at: dir.appendingPathComponent(name)),
                sidecar.state == .recording
            else { return nil }
            if let pid = sidecar.pid, isRunning(pid) { return nil }
            let base = String(name.dropLast(sidecarSuffix.count))
            let wanted = dir.appendingPathComponent(base + ".wav").path
            let first = RecordingFiles.allParts(of: wanted)[0]
            return FileManager.default.fileExists(atPath: first) ? URL(fileURLWithPath: first) : nil
        }
    }

    private static func isAudio(_ name: String) -> Bool {
        audioExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}
