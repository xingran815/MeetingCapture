import Foundation
import XCTest

@testable import MeetingCaptureCore

/// Writes fake `claude` and `codex` scripts into a temp folder and gives a runner
/// whose PATH holds only that folder. Every model call logs its arguments, input
/// and environment names, so tests can see exactly what a real CLI would have got.
final class FakeCLIWorld {
    let root: URL
    let bin: URL
    let logs: URL
    let ledgerPath: URL
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let timeZone = TimeZone(identifier: "UTC")!

    /// Lines the fake prints on stdout, plus its exit code and stderr.
    struct Script {
        var stdout: String
        var exit: Int32 = 0
        var stderr: String = ""
        var status: String?
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fakecli-\(UUID().uuidString)")
        bin = root.appendingPathComponent("bin")
        logs = root.appendingPathComponent("logs")
        ledgerPath = root.appendingPathComponent("usage.json")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    static func claudeOK(_ text: String = "fake answer", apiKeySource: String = "none", status: String = "allowed")
        -> String
    {
        let answer = jsonString(text)
        return """
            {"type":"system","subtype":"init","apiKeySource":"\(apiKeySource)","model":"fake"}
            {"type":"rate_limit_event","rate_limit_info":{"status":"\(status)","resetsAt":1800100000,"unifiedWindows":{"five_hour":{"utilization":0.07},"seven_day":{"utilization":0.66}}}}
            {"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":\(answer)}
            """
    }

    /// A Claude answer to a call that sent a JSON Schema: the object travels in
    /// `structured_output`, and the runner refuses a schema call without it.
    static func claudeStructured(_ json: String) -> String {
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        let result: [String: Any] = [
            "type": "result", "subtype": "success", "is_error": false, "result": "", "structured_output": object,
        ]
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        return """
            {"type":"system","subtype":"init","apiKeySource":"none","model":"fake"}
            {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1800100000,"unifiedWindows":{"five_hour":{"utilization":0.07},"seven_day":{"utilization":0.66}}}}
            \(line)
            """
    }

    /// One scripted answer carrying this JSON, in the shape the given CLI uses for a schema call.
    static func jsonScript(_ json: String, cli: CLIKind = .claude) -> Script {
        switch cli {
        case .claude: return Script(stdout: claudeStructured(json))
        case .codex:
            let compact = String(
                decoding: try! JSONSerialization.data(
                    withJSONObject: try! JSONSerialization.jsonObject(with: Data(json.utf8))), as: UTF8.self)
            return Script(stdout: codexOK(compact))
        }
    }

    static func codexOK(_ text: String = "fake answer") -> String {
        """
        {"type":"thread.started","thread_id":"x"}
        {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":\(jsonString(text))}}
        {"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":5}}
        """
    }

    static func jsonString(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    /// Installs a fake. `answers`, when several, are used in order and the last repeats.
    func install(_ cli: CLIKind, answers: [Script], authStatus: String? = nil) throws {
        let dir = logs.appendingPathComponent(cli.rawValue)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, answer) in answers.enumerated() {
            try answer.stdout.write(to: dir.appendingPathComponent("answer\(i).out"), atomically: true, encoding: .utf8)
            try answer.stderr.write(to: dir.appendingPathComponent("answer\(i).err"), atomically: true, encoding: .utf8)
            try "\(answer.exit)".write(
                to: dir.appendingPathComponent("answer\(i).code"), atomically: true, encoding: .utf8)
        }
        let status =
            authStatus
            ?? (cli == .claude
                ? #"{"loggedIn":true,"authMethod":"claude.ai"}"#
                : "Logged in using ChatGPT")
        try status.write(to: dir.appendingPathComponent("status"), atomically: true, encoding: .utf8)
        let script = """
            #!/usr/bin/env bash
            dir='\(dir.path)'
            last=\(answers.count - 1)
            case "$1 $2" in
              "auth status"|"login status") cat "$dir/status"; exit 0 ;;
              "features list") printf 'shell_tool stable true\\nfast_mode stable true\\nbrand_new_tool beta false\\n'; exit 0 ;;
            esac
            n=$(ls "$dir" | grep -c '^call')
            call="$dir/call$n"
            mkdir "$call"
            printf '%s\\n' "$@" > "$call/args"
            cat > "$call/stdin"
            env | cut -d= -f1 | sort > "$call/env"
            pwd > "$call/cwd"
            ls -A > "$call/cwdfiles"
            i=$n; [ "$i" -gt "$last" ] && i=$last
            cat "$dir/answer$i.out"
            cat "$dir/answer$i.err" >&2
            exit "$(cat "$dir/answer$i.code")"
            """
        let url = bin.appendingPathComponent(cli.rawValue)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// A fake whose model call is this bash snippet, for what a canned answer can't do:
    /// sleeping, ignoring signals, leaving a child behind, or exiting without reading.
    func installScript(
        _ cli: CLIKind, modelCall: String, featuresList: String = "exit 1", authStatus: String? = nil
    ) throws {
        let status =
            authStatus
            ?? (cli == .claude
                ? #"{"loggedIn":true,"authMethod":"claude.ai"}"#
                : "Logged in using ChatGPT")
        let script = """
            #!/usr/bin/env bash
            case "$1 $2" in
              "auth status"|"login status") printf '%s' '\(status)'; exit 0 ;;
              "features list") \(featuresList) ;;
            esac
            \(modelCall)
            """
        let url = bin.appendingPathComponent(cli.rawValue)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    struct Call {
        let args: [String]
        let stdin: String
        let env: [String]
        let cwd: String
        let cwdFiles: String
        var toolsOn: Bool {
            guard let i = args.firstIndex(of: "--tools") else { return args.contains("web_search=\"live\"") }
            return !args[i + 1].isEmpty
        }
        var everything: String { (args + [stdin]).joined(separator: "\n") }
    }

    func calls(_ cli: CLIKind) -> [Call] {
        let dir = logs.appendingPathComponent(cli.rawValue)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("call") }
            .sorted { Int($0.dropFirst(4))! < Int($1.dropFirst(4))! }
        return names.map { name in
            let d = dir.appendingPathComponent(name)
            func read(_ f: String) -> String {
                (try? String(contentsOf: d.appendingPathComponent(f), encoding: .utf8)) ?? ""
            }
            return Call(
                args: read("args").split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init),
                stdin: read("stdin"),
                env: read("env").split(separator: "\n").map(String.init),
                cwd: read("cwd").trimmingCharacters(in: .whitespacesAndNewlines),
                cwdFiles: read("cwdfiles").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// PATH holds only the fakes installed so far. Extra entries show what gets filtered out.
    var environment: [String: String] {
        [
            "PATH": bin.path + ":/usr/bin:/bin",
            "HOME": root.path,
            "USER": "tester",
            "TMPDIR": root.path + "/",
            "ANTHROPIC_API_KEY": "must-not-pass",
            "OPENAI_API_KEY": "must-not-pass",
            "SOME_OTHER": "must-not-pass",
        ]
    }

    func runner(
        allowAPIBilling: Bool = false, timeout: TimeInterval = 30,
        models: [CLIKind: CLITierModels] = [.claude: .claudeDefault, .codex: .codexDefault]
    ) -> CLIRunner {
        CLIRunner(models: models, allowAPIBilling: allowAPIBilling, environment: environment, timeout: timeout)
    }

    func ledger() -> UsageLedger {
        UsageLedger(path: ledgerPath, clock: { [unowned self] in self.now }, timeZone: timeZone)
    }

    func router(primary: CLIKind = .claude, cap: Int = 200) -> LLMRouter {
        LLMRouter(runner: runner(), ledger: ledger(), primary: primary, cap: cap, clock: { [unowned self] in self.now })
    }
}
