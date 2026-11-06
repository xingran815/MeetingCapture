import Foundation
import XCTest

/// Base class for any test that could reach a model. It fails the test unless
/// `claude` and `codex` on PATH are the fakes from Tests/FakeBin, and it refuses
/// URLSession traffic. `scripts/check.sh --live` is the only way to real models.
class GuardedTestCase: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(NetworkRefusal.self)
        for name in ["claude", "codex"] {
            let found = Self.firstOnPath(name)
            guard let found, found.contains("/Tests/FakeBin/") else {
                XCTFail("\(name) on PATH is not the fake (run tests through scripts/check.sh): \(found ?? "not found")")
                throw XCTSkip("refusing to continue without fake CLIs")
            }
        }
    }

    override func tearDown() {
        URLProtocol.unregisterClass(NetworkRefusal.self)
        super.tearDown()
    }

    static func firstOnPath(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// Fails every request made through URLSession.shared during a guarded test.
final class NetworkRefusal: URLProtocol {
    struct Refused: Error {}

    /// Requests refused so far, so a test can prove none was even tried.
    private(set) static var attempts = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.attempts += 1
        client?.urlProtocol(self, didFailWithError: Refused())
    }
    override func stopLoading() {}
}
