import XCTest

@testable import MeetingCaptureCore

/// M6: `--help` names the installed binary, not `swift run`, mentions no removed provider,
/// and lists only flags App.swift parses. Runs the built binary in a throwaway home.
final class HelpTextTests: XCTestCase {

    private var binary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("MeetingCaptureCLI")
    }

    private func help() throws -> String {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("MeetingCaptureCLI isn't built beside the tests: \(binary.path)")
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("help-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let p = Process()
        p.executableURL = binary
        p.arguments = ["--help"]
        p.currentDirectoryURL = home
        p.environment = [
            "PATH": "/usr/bin:/bin", "HOME": home.path, "MEETINGCAPTURE_HOME": home.path, "TMPDIR": home.path + "/",
        ]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let killer = DispatchWorkItem { p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        XCTAssertEqual(p.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self)
    }

    func testHelpNamesNoSwiftRunAndNoRemovedProvider() throws {
        let text = try help()
        XCTAssertTrue(text.contains("Usage:"), text)
        XCTAssertTrue(text.contains("meetingcapture"), text)
        XCTAssertTrue(text.contains(".build/debug/MeetingCaptureCLI"), text)
        for banned in ["swift run", "qianfan", "kimi"] {
            XCTAssertFalse(text.lowercased().contains(banned), "--help mentions “\(banned)”:\n\(text)")
        }
    }

    func testEveryFlagTheHelpListsIsOneAppSwiftParses() throws {
        let text = try help()
        let listed = Set(
            text.components(separatedBy: "\n").compactMap { line -> String? in
                guard let r = line.range(of: #"^\s{2,}(--[a-z][a-z-]*)"#, options: .regularExpression) else {
                    return nil
                }
                return line[r].trimmingCharacters(in: .whitespaces)
            })
        XCTAssertGreaterThanOrEqual(listed.count, 20, "the help's flag list wasn't found:\n\(text)")
        let appURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MeetingCaptureCore/App.swift")
        let app = try String(contentsOf: appURL, encoding: .utf8)
        for flag in listed.sorted() {
            XCTAssertTrue(app.contains("\"\(flag)\""), "--help lists \(flag), but App.swift never parses it")
        }
    }

    /// M6 review L1: the menu is "API configurations" now.
    func testM6ReviewL1_helpNamesAPIConfigurationsNotLLMConfigurations() throws {
        let text = try help()
        XCTAssertTrue(text.contains("API configurations"), text)
        XCTAssertFalse(text.contains("LLM configurations"), text)
    }
}
