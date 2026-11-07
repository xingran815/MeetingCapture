import XCTest

@testable import MeetingCaptureCore

/// What the desktop report view does with each navigation. Only the page itself loads;
/// a clicked web link opens outside; everything else is refused.
final class ReportNavigationTests: XCTestCase {

    private func u(_ s: String) -> URL { URL(string: s)! }

    func testThePageItselfAndItsAnchorsAreAllowed() {
        for s in ["about:blank", "about:blank#x", "about:blank#section-2"] {
            XCTAssertEqual(ReportNavigation.decide(url: u(s), isLinkClick: false), .allow, s)
            XCTAssertEqual(ReportNavigation.decide(url: u(s), isLinkClick: true), .allow, s)
        }
    }

    func testAClickedWebLinkOpensInTheBrowser() {
        for s in ["http://example.org/a?b=1#c", "https://example.org/", "HTTPS://Example.org/x", "HTTP://example.org"] {
            XCTAssertEqual(ReportNavigation.decide(url: u(s), isLinkClick: true), .openInBrowser(u(s)), s)
        }
    }

    func testAWebPageWithoutAClickIsRefused() {
        for s in ["http://example.org/", "https://example.org/", "HTTP://example.org/"] {
            XCTAssertEqual(ReportNavigation.decide(url: u(s), isLinkClick: false), .refuse, s)
        }
    }

    func testOtherSchemesAreRefusedEvenOnAClick() {
        let urls = [
            "file:///etc/passwd", "FILE:///etc/passwd", "javascript:alert(1)", "JavaScript:alert(1)",
            "data:text/html,<script>alert(1)</script>", "mailto:a@example.org", "ftp://example.org/x",
            "x-meetingcapture://do", "tel:123", "blob:https://example.org/uuid", "about2:blank",
        ]
        for s in urls {
            for click in [true, false] {
                XCTAssertEqual(ReportNavigation.decide(url: u(s), isLinkClick: click), .refuse, "\(s) click=\(click)")
            }
        }
    }

    func testNoURLOrNoSchemeIsRefused() {
        XCTAssertEqual(ReportNavigation.decide(url: nil, isLinkClick: true), .refuse)
        XCTAssertEqual(ReportNavigation.decide(url: nil, isLinkClick: false), .refuse)
        XCTAssertEqual(ReportNavigation.decide(url: u("/relative/path"), isLinkClick: true), .refuse)
        XCTAssertEqual(ReportNavigation.decide(url: u("#anchor-only"), isLinkClick: true), .refuse)
    }

    func testNewWindowOnlyEverOpensWebLinksOutside() {
        XCTAssertEqual(
            ReportNavigation.decideNewWindow(url: u("https://example.org/x")),
            .openInBrowser(u("https://example.org/x")))
        XCTAssertEqual(
            ReportNavigation.decideNewWindow(url: u("HTTP://example.org")), .openInBrowser(u("HTTP://example.org")))
        for s in [
            "about:blank", "about:blank#x", "file:///etc/passwd", "javascript:alert(1)", "data:text/html,x",
            "x-app://y",
        ] {
            XCTAssertEqual(ReportNavigation.decideNewWindow(url: u(s)), .refuse, s)
        }
        XCTAssertEqual(ReportNavigation.decideNewWindow(url: nil), .refuse)
    }
}
