import Foundation

// Old recordings are never deleted automatically (D-10). `--audio-cleanup` lists
// them and acts only on an explicit answer.
enum AudioCleanup {

    /// `readLine` is injected so the prompts can be tested.
    @discardableResult
    static func run(
        in dir: URL, encoder: AudioEncoding = AACEncoder(), readLine: () -> String? = { Swift.readLine() }
    ) -> (converted: [URL], deleted: [URL]) {
        let wavs = AudioRetention.unmanagedWAVs(in: dir)
        guard !wavs.isEmpty else {
            print("No old WAV recordings in \(dir.path).")
            return ([], [])
        }
        print("Old WAV recordings in \(dir.path):")
        var total = 0
        for wav in wavs {
            let size = (try? wav.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += size
            print(String(format: "  %8.1f MB  %@", Double(size) / 1_048_576, wav.lastPathComponent))
        }
        print(String(format: "  %8.1f MB  total", Double(total) / 1_048_576))
        print("\n[c] convert to M4A and remove each WAV once its M4A is proven\n[d] delete them\n[Enter] leave them")
        print("> ", terminator: "")

        switch readLine()?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "c":
            var converted: [URL] = []
            for wav in wavs {
                switch AudioArchive.archive(wav: wav, encoder: encoder) {
                case .archived(let m4a):
                    converted.append(m4a)
                    print("✓  \(m4a.lastPathComponent)")
                case .keptWAV(let reason):
                    print("⚠  Kept \(wav.lastPathComponent): \(reason).")
                }
            }
            return (converted, [])
        case "d":
            print("This can't be undone. Type delete to confirm: ", terminator: "")
            guard readLine()?.trimmingCharacters(in: .whitespaces) == "delete" else {
                print("Nothing deleted.")
                return ([], [])
            }
            var deleted: [URL] = []
            for wav in wavs where (try? FileManager.default.removeItem(at: wav)) != nil {
                deleted.append(wav)
                print("Deleted \(wav.lastPathComponent)")
            }
            return ([], deleted)
        default:
            print("Nothing changed.")
            return ([], [])
        }
    }
}

/// A crash leaves a WAV whose header still says it holds no audio, because the
/// sizes are only written when the file closes. This writes them from the real
/// file length, so the audio can be read. Returns true if it changed the header.
enum WAVRepair {

    private static let declaresNoLength: Set<UInt32> = [0, 0xFFFF_FFFF]

    @discardableResult
    static func repairHeader(at url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 12, fileSize <= UInt64(UInt32.max) else { return false }
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: 12) ?? Data()
        guard head.count == 12, head.prefix(4) == Data("RIFF".utf8), head.suffix(4) == Data("WAVE".utf8) else {
            return false
        }

        // Walks the chunks to find `data`; WAV puts other chunks ahead of it.
        var offset: UInt64 = 12
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: 8), chunk.count == 8 else { return false }
            let size = chunk.suffix(4).reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if chunk.prefix(4) == Data("data".utf8) {
                guard declaresNoLength.contains(size) else { return false }
                let audio = UInt32(fileSize - offset - 8)
                try handle.seek(toOffset: offset + 4)
                try handle.write(contentsOf: littleEndian(audio))
                try handle.seek(toOffset: 4)
                try handle.write(contentsOf: littleEndian(UInt32(fileSize - 8)))
                return true
            }
            // Chunks are padded to an even length.
            offset += 8 + UInt64(size) + UInt64(size % 2)
        }
        return false
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
