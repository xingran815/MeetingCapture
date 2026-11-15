import SwiftUI
import XCTest

@testable import MeetingCaptureDesktop

final class ThemeTests: XCTestCase {
    private let palettes: [(String, TerminalPalette)] = [("phosphor", .phosphor), ("paper", .paper)]

    func testContrastKnownPairs() {
        XCTAssertEqual(TerminalPalette.contrast(0x000000, 0xffffff), 21, accuracy: 0.01)
        XCTAssertEqual(TerminalPalette.contrast(0xffffff, 0x000000), 21, accuracy: 0.01)
        XCTAssertEqual(TerminalPalette.contrast(0x336699, 0x336699), 1, accuracy: 0.0001)
        // Mid grey #777 on white is the textbook 4.48:1.
        XCTAssertEqual(TerminalPalette.contrast(0x777777, 0xffffff), 4.48, accuracy: 0.02)
    }

    func testBodyAndDimTextReachAA() {
        for (name, p) in palettes {
            for (label, fg) in [("text", p.text), ("dim", p.dim)] {
                for (bgName, bg) in [("ground", p.ground), ("ground2", p.ground2)] {
                    let c = TerminalPalette.contrast(fg, bg)
                    XCTAssertGreaterThanOrEqual(c, 4.5, "\(name) \(label) on \(bgName) = \(c)")
                }
            }
        }
    }

    func testTextOnSolidBlocksReachAA() {
        for (name, p) in palettes {
            let pairs = [
                ("onAccent/accent", p.onAccent, p.accent), ("onRec/rec", p.onRec, p.rec),
                ("onAmber/amber", p.onAmber, p.amber),
            ]
            for (label, fg, bg) in pairs {
                let c = TerminalPalette.contrast(fg, bg)
                XCTAssertGreaterThanOrEqual(c, 4.5, "\(name) \(label) = \(c)")
            }
        }
    }

    func testSignalColoursReach3to1OnGround() {
        for (name, p) in palettes {
            for (label, fg) in [("accent", p.accent), ("rec", p.rec), ("amber", p.amber)] {
                let c = TerminalPalette.contrast(fg, p.ground)
                XCTAssertGreaterThanOrEqual(c, 3, "\(name) \(label) on ground = \(c)")
            }
        }
    }

    func testSpecHexValues() {
        XCTAssertEqual(TerminalPalette.phosphor.ground, 0x0a0d0b)
        XCTAssertEqual(TerminalPalette.phosphor.accent, 0x4dff9a)
        XCTAssertEqual(TerminalPalette.paper.ground, 0xf2eee2)
        XCTAssertEqual(TerminalPalette.paper.accent, 0x0b6a33)
        XCTAssertEqual(TerminalPalette.css(0x0a0d0b), "#0a0d0b")
    }

    func testResolveEveryChoiceAndScheme() {
        XCTAssertEqual(TerminalTheme.resolve(.system, scheme: .dark), .phosphor)
        XCTAssertEqual(TerminalTheme.resolve(.system, scheme: .light), .paper)
        for scheme in [ColorScheme.light, .dark] {
            XCTAssertEqual(TerminalTheme.resolve(.phosphor, scheme: scheme), .phosphor)
            XCTAssertEqual(TerminalTheme.resolve(.paper, scheme: scheme), .paper)
        }
        XCTAssertTrue(TerminalTheme.phosphor.isDark)
        XCTAssertFalse(TerminalTheme.paper.isDark)
        XCTAssertEqual(TerminalTheme.phosphor.colorScheme, .dark)
        XCTAssertEqual(TerminalTheme.paper.colorScheme, .light)
    }

    func testThemeOverrideIgnoredWithoutE2E() {
        let saved = (
            getenv("MEETINGCAPTURE_E2E").map { String(cString: $0) },
            getenv("MEETINGCAPTURE_THEME").map { String(cString: $0) }
        )
        defer {
            for (k, v) in [("MEETINGCAPTURE_E2E", saved.0), ("MEETINGCAPTURE_THEME", saved.1)] {
                if let v { setenv(k, v, 1) } else { unsetenv(k) }
            }
        }
        unsetenv("MEETINGCAPTURE_E2E")
        setenv("MEETINGCAPTURE_THEME", "paper", 1)
        XCTAssertNil(ThemeChoice.testOverride)
        setenv("MEETINGCAPTURE_E2E", "0", 1)
        XCTAssertNil(ThemeChoice.testOverride)
        setenv("MEETINGCAPTURE_E2E", "1", 1)
        XCTAssertEqual(ThemeChoice.testOverride, .paper)
        setenv("MEETINGCAPTURE_THEME", "nonsense", 1)
        XCTAssertNil(ThemeChoice.testOverride)
    }

    func testBlocks() {
        XCTAssertEqual(Blocks.meter(0.5, width: 10), "█████░░░░░")
        XCTAssertEqual(Blocks.meter(-3, width: 4), "░░░░")
        XCTAssertEqual(Blocks.meter(9, width: 4), "████")
        XCTAssertTrue(Blocks.progress(0.64).hasSuffix(" 64%"))
    }
}

final class ReportThemeTests: XCTestCase {
    private let csp =
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\">"
    private var page: String {
        "<!doctype html><html><head><meta charset=\"utf-8\">\(csp)<style>body{margin:0}</style></head><body><h1>Invented</h1></body></html>"
    }
    private let themes: [TerminalTheme] = [.phosphor, .paper]

    private func count(_ needle: String, in s: String) -> Int { s.components(separatedBy: needle).count - 1 }

    func testInsertsOneStyleRightBeforeHead() {
        for theme in themes {
            let out = ReportTheme.apply(theme, to: page)
            XCTAssertEqual(count("<style id=\"mc-theme\">", in: out), 1)
            let style = "<style id=\"mc-theme\">\(ReportTheme.css(theme))</style>"
            XCTAssertTrue(out.contains(style + "</head>"))
            // Removing the inserted text gives back the original bytes.
            XCTAssertEqual(out.replacingOccurrences(of: style, with: ""), page)
            XCTAssertTrue(out.contains(csp))
        }
    }

    func testNoHeadPrependsStyle() {
        let bare = "<p>no head here</p>"
        let out = ReportTheme.apply(.paper, to: bare)
        XCTAssertTrue(out.hasPrefix("<style id=\"mc-theme\">"))
        XCTAssertTrue(out.hasSuffix(bare))
        XCTAssertEqual(count("mc-theme", in: out), 1)
    }

    func testUppercaseHeadAndFirstHeadWins() {
        let html = "<HTML><HEAD></HEAD><body>text &lt;/head&gt; </body></HTML>"
        let out = ReportTheme.apply(.phosphor, to: html)
        XCTAssertTrue(out.contains("</style></HEAD>"))
        // Review: the real head closes first; a `</head>` later in the body must not move the insertion point.
        let body = "<html><head></head><body><pre></head></pre></body></html>"
        let out2 = ReportTheme.apply(.phosphor, to: body)
        XCTAssertTrue(out2.contains("</style></head><body>"), "forward search takes the first one")
        XCTAssertFalse(out2.contains("</style></head></pre>"))
    }

    func testCSSHoldsPaletteAndCannotBreakOut() {
        for theme in themes {
            let css = ReportTheme.css(theme)
            let p = theme.palette
            for hex in [p.ground, p.text, p.dim, p.line, p.ground2, p.accent, p.amber, p.selection] {
                XCTAssertTrue(css.contains(TerminalPalette.css(hex)), "\(theme.name) lacks \(TerminalPalette.css(hex))")
            }
            XCTAssertTrue(css.contains("color-scheme:\(theme.isDark ? "dark" : "light")"))
            XCTAssertFalse(css.contains("<"))
            XCTAssertFalse(css.contains("</style"))
        }
    }
}
