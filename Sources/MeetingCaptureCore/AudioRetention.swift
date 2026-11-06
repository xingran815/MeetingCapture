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
    /// A sidecar that can't be read means the age is unknown, so that audio stays.
    /// So does a recording still marked `recording`: it hasn't been transcribed.
    @discardableResult
    static func clean(in dir: URL, days: Int, now: Date) -> [URL] {
        guard days > 0 else { return [] }
        let limit = now.addingTimeInterval(-Double(days) * 86_400)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var deleted: [URL] = []
        for name in names where name.hasSuffix(sidecarSuffix) {
            let sidecarURL = dir.appendingPathComponent(name)
            guard let sidecar = RecordingSidecar.load(at: sidecarURL),
                sidecar.state == .processed, sidecar.createdAt < limit
            else { continue }
            let base = String(name.dropLast(sidecarSuffix.count))
            for file in audioFiles(forBase: base, among: names) {
                let url = dir.appendingPathComponent(file)
                if (try? FileManager.default.removeItem(at: url)) != nil { deleted.append(url) }
            }
        }
        return deleted.sorted { $0.path < $1.path }
    }

    /// WAVs with no sidecar, which only `--audio-cleanup` may touch, after asking.
    static func unmanagedWAVs(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let bases = Set(names.filter { $0.hasSuffix(sidecarSuffix) }.map { String($0.dropLast(sidecarSuffix.count)) })
        return
            names
            .filter { name in
                guard (name as NSString).pathExtension.lowercased() == "wav" else { return false }
                let stem = (name as NSString).deletingPathExtension
                return !bases.contains(RecordingFiles.baseName(of: stem))
            }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    /// Recordings a crash left unfinished: the sidecar still says `recording`.
    static func unfinished(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(sidecarSuffix) }.sorted().compactMap { name in
            guard RecordingSidecar.load(at: dir.appendingPathComponent(name))?.state == .recording else { return nil }
            let base = String(name.dropLast(sidecarSuffix.count))
            let first = base + ".wav"
            return names.contains(first) ? dir.appendingPathComponent(first) : nil
        }
    }

    private static func audioFiles(forBase base: String, among names: [String]) -> [String] {
        names.filter { name in
            guard audioExtensions.contains((name as NSString).pathExtension.lowercased()) else { return false }
            return RecordingFiles.baseName(of: (name as NSString).deletingPathExtension) == base
        }
    }
}
