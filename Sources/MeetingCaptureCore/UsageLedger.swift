import Foundation

// The daily call count for each CLI (D-18) and the limits each last reported.
// Every started model process counts, including failures. A file lock keeps the
// app and the terminal from undercounting each other.
final class UsageLedger {

    struct Stored: Codable, Equatable {
        var day: String = ""
        var counts: [String: Int] = [:]
        var limits: [String: RateLimitSnapshot] = [:]
    }

    static let defaultCap = 200

    static var defaultPath: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/MeetingCapture/usage.json")
    }

    let path: URL
    private let clock: () -> Date
    private let calendar: Calendar

    init(path: URL = UsageLedger.defaultPath, clock: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.path = path
        self.clock = clock
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    /// Takes one call if the CLI is under its cap. False means treat it as usage full.
    func reserve(_ cli: CLIKind, cap: Int) throws -> Bool {
        try withLock {
            var stored = self.load()
            let used = stored.counts[cli.rawValue, default: 0]
            guard used < cap else { return false }
            stored.counts[cli.rawValue] = used + 1
            try self.save(stored)
            return true
        }
    }

    func count(_ cli: CLIKind) throws -> Int {
        try withLock { self.load().counts[cli.rawValue, default: 0] }
    }

    func record(limit: RateLimitSnapshot, for cli: CLIKind) throws {
        try withLock {
            var stored = self.load()
            stored.limits[cli.rawValue] = limit
            try self.save(stored)
        }
    }

    func limit(_ cli: CLIKind) throws -> RateLimitSnapshot? {
        try withLock { self.load().limits[cli.rawValue] }
    }

    /// Whether the last report said this CLI is full and that hasn't reset yet.
    func isKnownFull(_ cli: CLIKind) throws -> Bool {
        guard let limit = try limit(cli), limit.status == "rejected" else { return false }
        guard let resetsAt = limit.resetsAt else { return false }
        return resetsAt > clock()
    }

    /// When today's counts start again: the next local midnight.
    var countResetsAt: Date {
        let start = calendar.startOfDay(for: clock())
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }

    private var today: String {
        let c = calendar.dateComponents([.year, .month, .day], from: clock())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Must be called with the lock held. Limits survive the day change, because
    /// they reset on their own clock; only the call counts restart.
    private func load() -> Stored {
        var stored = Stored()
        if let data = try? Data(contentsOf: path) {
            if let decoded = try? JSONDecoder.ledger.decode(Stored.self, from: data) {
                stored = decoded
            } else {
                // Unsure what the count was. Keep the file for a look and start over;
                // the worst case is one extra day's cap, never lost data.
                fputs("⚠  Couldn't read the usage counter; today's count restarts.\n", stderr)
                try? FileManager.default.moveItem(at: path, to: path.appendingPathExtension("corrupt"))
            }
        }
        if stored.day != today {
            stored.day = today
            stored.counts = [:]
        }
        return stored
    }

    private func save(_ stored: Stored) throws {
        let data = try JSONEncoder.ledger.encode(stored)
        try data.write(to: path, options: [.atomic])
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockPath = path.path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw LedgerError.cannotLock }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw LedgerError.cannotLock }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    enum LedgerError: Error, LocalizedError {
        case cannotLock
        var errorDescription: String? { "Couldn't lock the usage counter, so no call was started." }
    }

    /// One settings line, such as `Claude: 3/200 today · 5h 7% · 7d 66%`.
    func summaryLine(_ cli: CLIKind, cap: Int) -> String {
        let used = (try? count(cli)) ?? 0
        var line = "\(cli.label): \(used)/\(cap) today"
        if let limit = try? limit(cli) {
            if let five = limit.windows["five_hour"] { line += " · 5h \(Int(five * 100))%" }
            if let seven = limit.windows["seven_day"] { line += " · 7d \(Int(seven * 100))%" }
            if limit.status == "rejected" { line += " · full" }
        } else if cli == .codex {
            line += " · limits known only from errors"
        }
        return line
    }
}

extension JSONEncoder {
    fileprivate static var ledger: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}

extension JSONDecoder {
    fileprivate static var ledger: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}

/// Used only by the test that proves two real processes lose no calls.
public enum UsageLedgerStress {
    public static func run(path: String, calls: Int) {
        let ledger = UsageLedger(path: URL(fileURLWithPath: path))
        for _ in 0..<calls { _ = try? ledger.reserve(.claude, cap: Int.max) }
    }
}
