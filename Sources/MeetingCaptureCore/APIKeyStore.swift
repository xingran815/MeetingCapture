import Foundation

// File-based store for LLM API keys, one per saved LLMProfile.
//
// Keys live in a single JSON map at ~/.config/MeetingCapture/llm_api_keys.json,
// keyed by LLMProfile.id, kept OUT of config.json so the JSON stays safe to
// inspect/share. The file is written with POSIX mode 0600 (owner read/write only).
//
// This is a deliberate trade-off: a plaintext file is less protected than the
// macOS Keychain, but it avoids Keychain access prompts, is portable, and is
// the user's explicit choice.
enum APIKeyStore {

    /// Tests point this at a temp file, so they never touch the real keys.
    static var pathOverride: URL?

    static var path: URL {
        pathOverride
            ?? AppHome.url()
            .appendingPathComponent(".config/MeetingCapture/llm_api_keys.json")
    }

    /// Nil if a file exists that can't be understood, which is different from no keys.
    private static func readAll() -> [String: String]? {
        guard let data = try? Data(contentsOf: path) else {
            return FileManager.default.fileExists(atPath: path.path) ? nil : [:]
        }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    @discardableResult
    private static func writeAll(_ map: [String: String]) -> Bool {
        let url = path
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(map)
            // The mode is set as the file is created, then it's moved into place, so the
            // keys are never readable by others, even briefly. Finding from the
            // deep-review re-check: `createFile(attributes:)` writes first and restricts
            // afterwards, which a watcher caught.
            let temporary = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
            guard descriptor >= 0 else { return false }
            defer { try? FileManager.default.removeItem(at: temporary) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.close()
            return rename(temporary.path, url.path) == 0
        } catch {
            return false
        }
    }

    static func read(profileID: String) -> String? {
        guard let v = readAll()?[profileID] else { return nil }
        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Store or replace the key for one profile. Returns true on success.
    /// Refuses to replace a file it can't read: the other keys in it may be recoverable.
    @discardableResult
    static func write(_ value: String, forProfile profileID: String) -> Bool {
        guard var map = readAll() else { return false }
        map[profileID] = value
        return writeAll(map)
    }

    @discardableResult
    static func delete(profileID: String) -> Bool {
        guard var map = readAll() else { return false }
        guard map.removeValue(forKey: profileID) != nil else { return true }
        return writeAll(map)
    }

    static func isStored(profileID: String) -> Bool {
        read(profileID: profileID) != nil
    }
}
