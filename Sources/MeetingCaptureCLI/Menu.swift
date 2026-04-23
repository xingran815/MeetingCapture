import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Interactive list picker. Uses termios cbreak mode + ANSI redraws to let the
// user navigate with arrow keys (or j/k), select with Enter, or back out with
// b / ESC. Digit/letter shortcuts match an item's `key` and select immediately,
// so the old "press 1" muscle memory still works.
//
// On a non-TTY stdin we fall back to a printed numbered list + readLine(),
// which keeps piped input (e.g. `echo 1 | MeetingCaptureCLI`) working.

struct MenuItem {
    let key: Character?
    let label: String
    init(key: Character? = nil, label: String) {
        self.key = key
        self.label = label
    }
}

enum MenuPick {
    case selected(Int)
    case back
}

enum Menu {

    static func pick(
        title: String? = nil,
        header: String? = nil,
        items: [MenuItem],
        initialIndex: Int = 0,
        allowBack: Bool
    ) -> MenuPick {
        precondition(!items.isEmpty, "Menu.pick called with no items")

        if isatty(fileno(stdin)) == 0 {
            return lineFallback(title: title, header: header, items: items, allowBack: allowBack)
        }

        var original = termios()
        if tcgetattr(fileno(stdin), &original) != 0 {
            return lineFallback(title: title, header: header, items: items, allowBack: allowBack)
        }

        var raw = original
        raw.c_lflag &= ~(UInt(ICANON) | UInt(ECHO))
        _ = tcsetattr(fileno(stdin), TCSANOW, &raw)

        // Best-effort terminal restore on SIGINT so Ctrl-C never leaves the
        // user's shell in cbreak mode.
        let prevSigint = signal(SIGINT) { _ in
            var t = termios()
            if tcgetattr(fileno(stdin), &t) == 0 {
                t.c_lflag |= UInt(ICANON) | UInt(ECHO)
                _ = tcsetattr(fileno(stdin), TCSANOW, &t)
            }
            _ = write(fileno(stdout), "\n", 1)
            exit(130)
        }
        defer {
            var r = original
            _ = tcsetattr(fileno(stdin), TCSANOW, &r)
            signal(SIGINT, prevSigint)
        }

        var index = max(0, min(initialIndex, items.count - 1))
        var drawnLines = 0

        func render(first: Bool) {
            if !first {
                // Move cursor up over the previously-drawn block and clear each line.
                fputs("\u{1B}[\(drawnLines)A", stdout)
            }
            var lines = 0
            if let title = title {
                for line in title.split(separator: "\n", omittingEmptySubsequences: false) {
                    fputs("\u{1B}[2K\(line)\n", stdout)
                    lines += 1
                }
            }
            if let header = header {
                for line in header.split(separator: "\n", omittingEmptySubsequences: false) {
                    fputs("\u{1B}[2K\(line)\n", stdout)
                    lines += 1
                }
            }
            for (i, item) in items.enumerated() {
                let marker = (i == index) ? "\u{1B}[36m▸\u{1B}[0m " : "  "
                let keyHint: String = {
                    if let k = item.key { return "\(k)) " }
                    return "   "
                }()
                let label = (i == index)
                    ? "\u{1B}[1m\(item.label)\u{1B}[0m"
                    : item.label
                fputs("\u{1B}[2K\(marker)\(keyHint)\(label)\n", stdout)
                lines += 1
            }
            let footer = allowBack
                ? "  ↑↓ move · enter select · b back · q quit"
                : "  ↑↓ move · enter select · q quit"
            fputs("\u{1B}[2K\u{1B}[2m\(footer)\u{1B}[0m\n", stdout)
            lines += 1
            fflush(stdout)
            drawnLines = lines
        }

        render(first: true)

        while true {
            var byte: UInt8 = 0
            let n = read(fileno(stdin), &byte, 1)
            if n <= 0 { return allowBack ? .back : .selected(index) }

            switch byte {
            case 0x0A, 0x0D:                     // Enter
                return .selected(index)
            case 0x1B:                           // ESC or escape sequence
                if let seq = readEscapeSequence() {
                    switch seq {
                    case "[A":                   // up
                        index = (index - 1 + items.count) % items.count
                        render(first: false)
                    case "[B":                   // down
                        index = (index + 1) % items.count
                        render(first: false)
                    default:
                        break
                    }
                } else {
                    if allowBack { return .back }
                }
            case UInt8(ascii: "k"):
                index = (index - 1 + items.count) % items.count
                render(first: false)
            case UInt8(ascii: "j"):
                index = (index + 1) % items.count
                render(first: false)
            case UInt8(ascii: "q"):
                return allowBack ? .back : .selected(items.count - 1)  // root: last item is Quit
            case UInt8(ascii: "b"):
                if allowBack { return .back }
                fallthrough
            default:
                let ch = Character(UnicodeScalar(byte))
                if let hit = items.firstIndex(where: { $0.key == ch }) {
                    index = hit
                    render(first: false)
                    return .selected(hit)
                }
            }
        }
    }

    // Read up to 2 more bytes with a short timeout to complete an ANSI CSI
    // sequence like ESC [ A. Returns nil on a lone ESC press.
    private static func readEscapeSequence() -> String? {
        var fds = fd_set()
        fdZero(&fds)
        fdSet(fileno(stdin), &fds)
        var tv = timeval(tv_sec: 0, tv_usec: 10_000)  // 10 ms
        let ready = select(fileno(stdin) + 1, &fds, nil, nil, &tv)
        if ready <= 0 { return nil }

        var b1: UInt8 = 0
        guard read(fileno(stdin), &b1, 1) == 1 else { return nil }
        if b1 != UInt8(ascii: "[") { return nil }

        var b2: UInt8 = 0
        guard read(fileno(stdin), &b2, 1) == 1 else { return nil }
        return "[\(Character(UnicodeScalar(b2)))"
    }

    private static func lineFallback(
        title: String?,
        header: String?,
        items: [MenuItem],
        allowBack: Bool
    ) -> MenuPick {
        if let title = title { print(title) }
        if let header = header { print(header) }
        for (i, item) in items.enumerated() {
            let k = item.key.map { "\($0)) " } ?? "\(i + 1)) "
            print("  \(k)\(item.label)")
        }
        fputs("> ", stdout)
        guard let raw = readLine() else { return allowBack ? .back : .selected(0) }
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return allowBack ? .back : .selected(0) }
        if allowBack, s == "b" || s == "back" { return .back }
        if s == "q" || s == "quit" || s == "exit" {
            return allowBack ? .back : .selected(items.count - 1)
        }
        if let ch = s.first, let hit = items.firstIndex(where: { $0.key == ch }) {
            return .selected(hit)
        }
        if let n = Int(s), n >= 1, n <= items.count {
            return .selected(n - 1)
        }
        return allowBack ? .back : .selected(0)
    }
}

// MARK: - fd_set helpers (Darwin exposes fd_set as an opaque tuple)

private func fdZero(_ set: inout fd_set) {
    withUnsafeMutableBytes(of: &set) { buf in
        _ = buf.initializeMemory(as: UInt8.self, repeating: 0)
    }
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let intBits = MemoryLayout<Int32>.size * 8
    let idx = Int(fd) / intBits
    let bit = Int(fd) % intBits
    withUnsafeMutableBytes(of: &set.fds_bits) { buf in
        let ints = buf.bindMemory(to: Int32.self)
        ints[idx] |= Int32(1 << bit)
    }
}

