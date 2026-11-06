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
            ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/MeetingCapture/llm_api_keys.json")
    }

    private static func readAll() -> [String: String] {
        guard let data = try? Data(contentsOf: path),
            let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    @discardableResult
    private static func writeAll(_ map: [String: String]) -> Bool {
        let url = path
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(map)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    static func read(profileID: String) -> String? {
        guard let v = readAll()[profileID] else { return nil }
        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Store or replace the key for one profile. Returns true on success.
    @discardableResult
    static func write(_ value: String, forProfile profileID: String) -> Bool {
        var map = readAll()
        map[profileID] = value
        return writeAll(map)
    }

    @discardableResult
    static func delete(profileID: String) -> Bool {
        var map = readAll()
        guard map.removeValue(forKey: profileID) != nil else { return true }
        return writeAll(map)
    }

    static func isStored(profileID: String) -> Bool {
        read(profileID: profileID) != nil
    }
}
