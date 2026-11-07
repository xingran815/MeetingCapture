import Foundation

// Starts the official CLIs: no shell, an argument array, an allow-listed
// environment, input on stdin, and an empty temp folder as cwd. The app never
// reads, stores or forwards their login tokens.

/// A process's outcome, with both pipes fully drained.
struct ProcessOutput {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

enum ProcessExec {

    static func run(
        executable: String, arguments: [String], stdin: String = "", cwd: URL,
        environment: [String: String], timeout: TimeInterval
    ) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    continuation.resume(
                        returning: try runBlocking(
                            executable: executable, arguments: arguments, stdin: stdin, cwd: cwd,
                            environment: environment, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runBlocking(
        executable: String, arguments: [String], stdin: String, cwd: URL,
        environment: [String: String], timeout: TimeInterval
    ) throws -> ProcessOutput {
        // A child that exits before reading its input must not kill this process.
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = environment
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()

        // Drain everything at once, or a full pipe deadlocks parent and child.
        let group = DispatchGroup()
        let out = PipeDrain(outPipe, group: group)
        let err = PipeDrain(errPipe, group: group)
        DispatchQueue.global().async {
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        let lock = NSLock()
        var timedOut = false
        let killer = DispatchWorkItem {
            lock.lock()
            timedOut = true
            lock.unlock()
            process.terminate()
            // Finding from the test audit: a CLI can ignore that, so this one it can't.
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()

        // Finding from the test audit: a child left behind can hold the pipes open for
        // ever. Once the CLI has exited, stop as soon as the output has stopped arriving.
        var seen = -1
        while group.wait(timeout: .now() + drainPatience) == .timedOut {
            let now = out.count + err.count
            if now == seen { break }
            seen = now
        }
        out.stop()
        err.stop()

        lock.lock()
        defer { lock.unlock() }
        return ProcessOutput(
            status: process.terminationStatus,
            stdout: String(decoding: out.data, as: UTF8.self),
            stderr: String(decoding: err.data, as: UTF8.self),
            timedOut: timedOut)
    }

    /// How long after SIGTERM a CLI has to end. It has already run out of time.
    private static let killGrace: TimeInterval = 0.4
    /// How long output can stay still after the CLI exits before it counts as finished.
    private static let drainPatience: TimeInterval = 0.25
}

/// Reads a pipe in the background, and can be abandoned while something still holds it open.
private final class PipeDrain {
    private let lock = NSLock()
    private var buffer = Data()
    private let handle: FileHandle
    private var finished = false
    private let group: DispatchGroup

    init(_ pipe: Pipe, group: DispatchGroup) {
        handle = pipe.fileHandleForReading
        self.group = group
        group.enter()
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            self?.received(chunk)
        }
    }

    private func received(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        if chunk.isEmpty {
            finish()
        } else {
            buffer.append(chunk)
        }
    }

    /// Call with the lock held. Leaves the group exactly once.
    private func finish() {
        finished = true
        handle.readabilityHandler = nil
        group.leave()
    }

    /// Stops reading. Whatever has arrived stays in `data`.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        if !finished { finish() }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

final class CLIRunner {

    /// Only these reach a CLI, because a set `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`
    /// would bill the API instead of the subscription.
    static let allowedEnvironment = ["HOME", "PATH", "USER", "TMPDIR"]

    enum Availability: Equatable {
        case ready
        case missing(CLIError)
    }

    private let environment: [String: String]
    private let models: [CLIKind: CLITierModels]
    private let allowAPIBilling: Bool
    private let timeout: TimeInterval
    private var featuresOff: [String]?
    private var availabilityCache: [CLIKind: Availability] = [:]
    private let lock = NSLock()

    init(
        models: [CLIKind: CLITierModels],
        allowAPIBilling: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 600
    ) {
        self.models = models
        self.allowAPIBilling = allowAPIBilling
        self.environment = environment.filter { Self.allowedEnvironment.contains($0.key) }
        self.timeout = timeout
    }

    func modelName(_ cli: CLIKind, tier: ModelTier) -> String {
        (models[cli] ?? (cli == .claude ? .claudeDefault : .codexDefault)).model(for: tier)
    }

    private func executable(_ cli: CLIKind) -> String? {
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/\(cli.rawValue)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Installed, logged in, and on the subscription. Costs no model call and
    /// isn't counted against the daily cap. Cached for this runner's life.
    func availability(_ cli: CLIKind) async -> Availability {
        // withLock, because lock() and unlock() can't be called from async code.
        let cached = lock.withLock { availabilityCache[cli] }
        if let cached { return cached }
        let result = await checkAvailability(cli)
        lock.withLock { availabilityCache[cli] = result }
        return result
    }

    private func checkAvailability(_ cli: CLIKind) async -> Availability {
        guard let path = executable(cli) else { return .missing(.notInstalled(cli)) }
        guard let dir = try? makeTempDir() else { return .missing(.failed(cli, "no temp folder")) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let arguments = cli == .claude ? ["auth", "status"] : ["login", "status"]
        guard
            let out = try? await ProcessExec.run(
                executable: path, arguments: arguments, cwd: dir, environment: environment, timeout: 20)
        else { return .missing(.notLoggedIn(cli)) }

        switch cli {
        case .claude:
            guard let data = out.stdout.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                json["loggedIn"] as? Bool == true
            else { return .missing(.notLoggedIn(cli)) }
            let method = json["authMethod"] as? String ?? "unknown"
            if method == "claude.ai" || allowAPIBilling { return .ready }
            return .missing(.apiBillingRefused(cli, method))
        case .codex:
            let text = out.stdout + out.stderr
            if text.contains("ChatGPT") || (allowAPIBilling && out.status == 0) { return .ready }
            if text.localizedCaseInsensitiveContains("api key") {
                return .missing(.apiBillingRefused(cli, "API key login"))
            }
            return .missing(.notLoggedIn(cli))
        }
    }

    func run(_ request: CLIRequest, on cli: CLIKind) async throws -> CLIResult {
        guard let path = executable(cli) else { throw CLIError.notInstalled(cli) }
        let model = modelName(cli, tier: request.tier)
        guard CLIArguments.isSafeModelName(model) else {
            throw CLIError.badRequest("Invalid model name in config for \(cli.label).")
        }

        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("cwd", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let arguments: [String]
        switch cli {
        case .claude:
            arguments = CLIArguments.claude(request, model: model)
        case .codex:
            let instructions = root.appendingPathComponent("instructions.md")
            try request.system.write(to: instructions, atomically: true, encoding: .utf8)
            var schemaPath: String?
            if let schema = request.schema {
                let url = root.appendingPathComponent("schema.json")
                try schema.write(to: url, atomically: true, encoding: .utf8)
                schemaPath = url.path
            }
            arguments = CLIArguments.codex(
                request, model: model, cwd: cwd.path, schemaPath: schemaPath,
                instructionsPath: instructions.path,
                featuresOff: await codexFeaturesOff(executable: path))
        }

        let output = try await ProcessExec.run(
            executable: path, arguments: arguments, stdin: request.input, cwd: cwd,
            environment: environment, timeout: timeout)
        if output.timedOut { throw CLIError.timedOut(cli) }

        let parsed =
            cli == .claude
            ? CLIOutputParser.parseClaude(output.stdout)
            : CLIOutputParser.parseCodex(output.stdout)

        // The login check ran before the call. This catches a key arriving by
        // another route, such as a settings helper, and refuses its answer.
        if let source = parsed.apiKeySource, source != "none", !allowAPIBilling {
            throw CLIError.apiBillingRefused(cli, source)
        }

        switch CLIOutputParser.outcome(of: parsed, exitCode: output.status, stderr: output.stderr) {
        case .usageFull(let resetsAt):
            throw CLIError.usageFull(cli, resetsAt: resetsAt)
        case .failed(let message):
            // CLI errors can quote their input, so scrub before this reaches a screen or log.
            throw CLIError.failed(cli, String(Redactor.redact(message).text.prefix(400)))
        case .ok:
            break
        }
        if request.schema != nil, cli == .claude, !parsed.hasStructuredOutput {
            throw CLIError.failed(cli, "no structured output in the reply")
        }
        // Finding from the test audit: an exit 0 with nothing in it would save an empty summary.
        if request.schema == nil, (parsed.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIError.failed(cli, "the reply was empty")
        }
        return CLIResult(
            cli: cli, model: model, text: parsed.text ?? "", apiKeySource: parsed.apiKeySource,
            webSearchCount: parsed.webSearchCount, rateLimit: parsed.rateLimit)
    }

    private func codexFeaturesOff(executable path: String) async -> [String] {
        let cached = lock.withLock { featuresOff }
        if let cached { return cached }

        // CODEX_HOME points at an empty folder: no login, no user config, no model call.
        var listed: [String] = []
        if let home = try? makeTempDir() {
            defer { try? FileManager.default.removeItem(at: home) }
            var env = environment
            env["CODEX_HOME"] = home.path
            if let out = try? await ProcessExec.run(
                executable: path, arguments: ["features", "list"], cwd: home, environment: env, timeout: 15),
                out.status == 0
            {
                listed = CLIArguments.parseCodexFeatureList(out.stdout)
            }
        }
        let result = CLIArguments.codexFeaturesOff(listed: listed)
        lock.withLock { featuresOff = result }
        return result
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingcapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
