import XCTest

@testable import MeetingCaptureCore

/// M6 finding: picker keys. "Test CLI connection" had the shortcut `k`, but on a real TTY
/// `Menu.run` and `Menu.pick` read `k`/`j` as up/down, `b` as back and `q` as quit before
/// they look at item keys, so the row could not be reached. These tests read the sources
/// (the menus are built inside Shell methods that need a terminal), so no real TTY is needed.
final class PickerKeysTests: XCTestCase {

    private var sourcesDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MeetingCaptureCore")
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: sourcesDir.appendingPathComponent(name), encoding: .utf8)
    }

    private func captures(_ pattern: String, in text: String) -> [[String]] {
        let re = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
        }
    }

    /// Letters `Menu.swift` handles before looking at an item's key.
    private func interceptedLetters() throws -> Set<String> {
        Set(captures(#"case UInt8\(ascii: "([a-z])"\):"#, in: try source("Menu.swift")).map { $0[1] })
    }

    func testReservedSetMatchesWhatMenuSwiftIntercepts() throws {
        XCTAssertEqual(
            try interceptedLetters(), ["j", "k", "b", "q"],
            "Menu.swift intercepts a different set of letters: update the reserved set in this file and the CLAUDE.md note"
        )
    }

    func testNoShellMenuItemUsesAKeyThePickerReserves() throws {
        let reserved = try interceptedLetters()
        var seen = 0
        for file in try FileManager.default.contentsOfDirectory(atPath: sourcesDir.path).sorted()
        where file.hasSuffix(".swift") && file != "Menu.swift" {
            let text = try source(file)
            // MenuItem(key: "x", label: ...) and the multi-line form; label up to the next comma.
            for m in captures(#"MenuItem\(\s*key:\s*"(.)",\s*label:\s*"([^"]*)""#, in: text) {
                seen += 1
                let key = m[1]
                let isMainQuit = key == "q" && file == "Shell.swift" && m[2] == "Quit"
                if reserved.contains(key) && !isMainQuit {
                    XCTFail("\(file): menu row “\(m[2])” has key \(key), which the picker intercepts on a TTY")
                }
            }
        }
        XCTAssertGreaterThan(seen, 30, "the scan found too few MenuItem rows; the pattern has gone stale")
    }

    func testOnlyTheMainMenusQuitRowMayUseQ() throws {
        var qRows: [String] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: sourcesDir.path).sorted()
        where file.hasSuffix(".swift") && file != "Menu.swift" {
            for m in captures(#"MenuItem\(\s*key:\s*"q",\s*label:\s*"([^"]*)""#, in: try source(file)) {
                qRows.append("\(file):\(m[1])")
            }
        }
        XCTAssertEqual(qRows, ["Shell.swift:Quit"])
    }

    func testTestCLIConnectionRowUsesPAndIsHandledByP() throws {
        let shell = try source("Shell.swift")
        XCTAssertTrue(shell.contains(#"MenuItem(key: "p", label: "Test CLI connection")"#))
        XCTAssertFalse(shell.contains(#"MenuItem(key: "k", label: "Test CLI connection")"#))
        XCTAssertTrue(
            shell.range(of: #"case "p":\s*testCLIConnection\(\)"#, options: .regularExpression) != nil,
            "the handler must dispatch p to testCLIConnection")
    }
}
