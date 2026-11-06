import Foundation

// Which CLI runs a call. One CLI runs every tier: tiers are never mixed across
// CLIs. Moving to the other one happens only when usage is full, and then it
// stays there for the rest of the run. Other errors surface as they are.
final class LLMRouter {

    enum RouterError: Error, LocalizedError, Equatable {
        case noCLI([String])
        case allUsageFull(countsResetAt: Date, limitsResetAt: Date?)

        var errorDescription: String? {
            switch self {
            case .noCLI(let reasons):
                return "No subscription CLI is ready. " + reasons.joined(separator: " ")
            case .allUsageFull(let counts, let limits):
                let f = DateFormatter()
                f.dateStyle = .medium
                f.timeStyle = .short
                var text = "Usage is full on every CLI, so nothing more was sent and no API profile was used. "
                text += "The transcript and finished steps are kept. The daily count resets \(f.string(from: counts))"
                if let limits { text += "; the reported limit resets \(f.string(from: limits))" }
                return text + "."
            }
        }
    }

    private let runner: CLIRunner
    private let ledger: UsageLedger
    private let primary: CLIKind
    private let cap: Int
    private let clock: () -> Date

    /// The CLI this run has settled on. Set once a call succeeds or a switch happens.
    private var current: CLIKind?
    private var ruledOut = Set<CLIKind>()
    private(set) var notes: [String] = []

    init(runner: CLIRunner, ledger: UsageLedger, primary: CLIKind, cap: Int, clock: @escaping () -> Date = Date.init) {
        self.runner = runner
        self.ledger = ledger
        self.primary = primary
        self.cap = cap
        self.clock = clock
    }

    /// True if at least one CLI is installed, logged in and on the subscription.
    func hasReadyCLI() async -> Bool {
        for cli in CLIKind.allCases where await runner.availability(cli) == .ready { return true }
        return false
    }

    func call(_ request: CLIRequest) async throws -> CLIResult {
        var reasons: [String] = []
        var candidates: [CLIKind] = []
        for cli in [current ?? primary, (current ?? primary).other] where !ruledOut.contains(cli) {
            switch await runner.availability(cli) {
            case .ready: candidates.append(cli)
            case .missing(let error): reasons.append(error.errorDescription ?? "")
            }
        }
        if candidates.isEmpty {
            if ruledOut.isEmpty { throw RouterError.noCLI(reasons) }
            throw allFull()
        }

        for cli in candidates {
            if try ledger.isKnownFull(cli) {
                markFull(cli, reason: "its usage limit is full")
                continue
            }
            guard try ledger.reserve(cli, cap: cap) else {
                markFull(cli, reason: "it reached the daily cap of \(cap) calls")
                continue
            }
            do {
                let result = try await runner.run(request, on: cli)
                if let limit = result.rateLimit { try? ledger.record(limit: limit, for: cli) }
                current = cli
                return result
            } catch CLIError.usageFull(_, let resetsAt) {
                lastResetsAt = resetsAt ?? lastResetsAt
                if let resetsAt {
                    try? ledger.record(
                        limit: RateLimitSnapshot(status: "rejected", resetsAt: resetsAt, windows: [:]), for: cli)
                }
                markFull(cli, reason: "its usage limit filled up")
            }
        }
        throw allFull()
    }

    private var lastResetsAt: Date?

    private func allFull() -> RouterError {
        .allUsageFull(countsResetAt: ledger.countResetsAt, limitsResetAt: lastResetsAt)
    }

    private func markFull(_ cli: CLIKind, reason: String) {
        ruledOut.insert(cli)
        if let limit = try? ledger.limit(cli), limit.status == "rejected", let resetsAt = limit.resetsAt, resetsAt > clock() {
            lastResetsAt = resetsAt
        }
        current = cli.other
        notes.append("\(cli.label) wasn't used for the remaining steps because \(reason); \(cli.other.label) ran them if it was available.")
    }
}
