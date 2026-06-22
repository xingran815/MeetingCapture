import Foundation

// File-based store for the LLM API key.
//
// The key lives in its own file at ~/.config/MeetingCapture/llm_api_key, kept
// OUT of config.json so the JSON stays safe to inspect/share. The file is
// written with POSIX mode 0600 (owner read/write only).
//
// This is a deliberate trade-off: a plaintext file is less protected than the
// macOS Keychain, but it avoids Keychain access prompts, is portable, and is
// the user's explicit choice. Keychain.swift remains as a legacy read path so
// keys stored by older versions are migrated forward (see Config.resolveApiKey).
enum APIKeyStore {

    static var path: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/MeetingCapture/llm_api_key")
    }

    static func read() -> String? {
        guard let data = try? Data(contentsOf: path),
              let str = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Store or replace the key. Creates the parent dir, writes atomically, then
    /// clamps permissions to 0600. Returns true on success.
    @discardableResult
    static func write(_ value: String) -> Bool {
        let url = path
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func delete() -> Bool {
        let url = path
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do { try FileManager.default.removeItem(at: url); return true }
        catch { return false }
    }

    static var isStored: Bool {
        read() != nil
    }
}
