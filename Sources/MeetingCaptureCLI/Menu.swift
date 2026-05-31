import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Interactive list picker. Uses termios cbreak mode + ANSI redraws to let the
// user navigate with arrow keys (or j/k), select with Enter, or back out with
// b / ESC. Digit/letter shortcuts match an item's `key` and select immediately,
// so the old "press 1" muscle memory still works.
//
// Two entry points:
//   pick(...)  one-shot: render, return the chosen index (or .back).
//   run(...)   persistent: stay open, invoke `onSelect` per choice, redraw in
//              place. Used for settings/toggle menus so changing one item never
//              prints a fresh stacked copy of the whole menu.
//
// On a non-TTY stdin we fall back to a printed numbered list + readLine(),
// which keeps piped input (e.g. `echo 1 | MeetingCaptureCLI`) working.

struct MenuItem {
    let key: Character?
    let label: String
    /// Disabled rows are dimmed, skipped by navigation, and cannot be selected.
    /// Used for separators and contextually-unavailable options.
    let enabled: Bool
    init(key: Character? = nil, label: String, enabled: Bool = true) {
        self.key = key
        self.label = label
        self.enabled = enabled
    }
    /// A non-selectable divider/label row.
    static func separator(_ label: String = "") -> MenuItem {
        MenuItem(key: nil, label: label, enabled: false)
    }
}

enum MenuPick {
    case selected(Int)
    case back
}

enum Menu {

    // MARK: - One-shot picker

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

        enterRaw(&original)
        let prevSigint = installSigintRestore()
        defer {
            var r = original
            _ = tcsetattr(fileno(stdin), TCSANOW, &r)
            signal(SIGINT, prevSigint)
        }

        var index = max(0, min(initialIndex, items.count - 1))
        if !items[index].enabled { index = step(items, from: index, by: 1) }
        var drawnLines = 0

        renderBlock(title: title, header: header, items: items,
                    index: index, allowBack: allowBack, drawnLines: &drawnLines, first: true)

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
                    case "[A": index = step(items, from: index, by: -1)
                               renderBlock(title: title, header: header, items: items,
                                           index: index, allowBack: allowBack, drawnLines: &drawnLines, first: false)
                    case "[B": index = step(items, from: index, by: 1)
                               renderBlock(title: title, header: header, items: items,
                                           index: index, allowBack: allowBack, drawnLines: &drawnLines, first: false)
                    default: break
                    }
                } else {
                    if allowBack { return .back }
                }
            case UInt8(ascii: "k"):
                index = step(items, from: index, by: -1)
                renderBlock(title: title, header: header, items: items,
                            index: index, allowBack: allowBack, drawnLines: &drawnLines, first: false)
            case UInt8(ascii: "j"):
                index = step(items, from: index, by: 1)
                renderBlock(title: title, header: header, items: items,
                            index: index, allowBack: allowBack, drawnLines: &drawnLines, first: false)
            case UInt8(ascii: "q"):
                return allowBack ? .back : .selected(items.count - 1)  // root: last item is Quit
            case UInt8(ascii: "b"):
                if allowBack { return .back }
                fallthrough
            default:
                let ch = Character(UnicodeScalar(byte))
                if let hit = items.firstIndex(where: { $0.key == ch && $0.enabled }) {
                    index = hit
                    renderBlock(title: title, header: header, items: items,
                                index: index, allowBack: allowBack, drawnLines: &drawnLines, first: false)
                    return .selected(hit)
                }
            }
        }
    }

    // MARK: - Persistent menu (redraws in place)

    /// Stays open, calling `onSelect` for each chosen index. The menu block is
    /// cleared before `onSelect` runs (so any output it prints replaces the menu
    /// rather than stacking below it) and re-rendered afterwards. `items` is a
    /// closure so labels reflect the latest state on every redraw.
    static func run(
        title: String? = nil,
        header: String? = nil,
        items: () -> [MenuItem],
        allowBack: Bool = true,
        onSelect: (Int) -> Void
    ) {
        if isatty(fileno(stdin)) == 0 {
            runLineFallback(title: title, header: header, items: items, onSelect: onSelect)
            return
        }

        var original = termios()
        if tcgetattr(fileno(stdin), &original) != 0 {
            runLineFallback(title: title, header: header, items: items, onSelect: onSelect)
            return
        }

        var current = items()
        precondition(!current.isEmpty, "Menu.run called with no items")
        var index = firstEnabled(current)
        var drawnLines = 0

        enterRaw(&original)
        let prevSigint = installSigintRestore()
        renderBlock(title: title, header: header, items: current,
                    index: index, allowBack: allowBack, drawnLines: &drawnLines, first: true)
        defer {
            var r = original
            _ = tcsetattr(fileno(stdin), TCSANOW, &r)
            signal(SIGINT, prevSigint)
        }

        // Run onSelect in cooked mode (so sub-prompts can readLine), then rebuild
        // the item list and redraw a fresh block at the cursor's new position.
        func dispatch(_ i: Int) {
            // Erase the current block, then drop back to cooked mode.
            fputs("\u{1B}[\(drawnLines)A\u{1B}[0J", stdout)
            fflush(stdout)
            var r = original
            _ = tcsetattr(fileno(stdin), TCSANOW, &r)

            onSelect(i)

            current = items()
            index = current.indices.contains(index) && current[index].enabled
                ? index : firstEnabled(current)
            enterRaw(&original)
            renderBlock(title: title, header: header, items: current,
                        index: index, allowBack: allowBack, drawnLines: &drawnLines, first: true)
        }

        while true {
            var byte: UInt8 = 0
            let n = read(fileno(stdin), &byte, 1)
            if n <= 0 { return }

            switch byte {
            case 0x0A, 0x0D:                     // Enter
                dispatch(index)
            case 0x1B:                           // ESC or escape sequence
                if let seq = readEscapeSequence() {
                    switch seq {
                    case "[A": index = step(current, from: index, by: -1)
                               renderBlock(title: title, header: header, items: current,
                                           index: index, allowBack: allowBack, drawnLines: &drawnLines, first: false)
                    case "[B": index = step(current, from: index, by: 1)
                               renderBlock(title: title, header: header, items: current,
                                           index: index, allowBack: allowBack, drawnLines: &drawnLines, first: false)
                    default: break
                    }
                } else {
                    if allowBack { return }
                }
            case UInt8(ascii: "k"):
                index = step(current, from: index, by: -1)
                renderBlock(title: title, header: header, items: current,
                            index: index, allowBack: allowBack, drawnLines: &drawnLines, first: false)
            case UInt8(ascii: "j"):
                index = step(current, from: index, by: 1)
                renderBlock(title: title, header: header, items: current,
                            index: index, allowBack: allowBack, drawnLines: &drawnLines, first: false)
            case UInt8(ascii: "q"):
                return
            case UInt8(ascii: "b"):
                if allowBack { return }
                fallthrough
            default:
                let ch = Character(UnicodeScalar(byte))
                if let hit = current.firstIndex(where: { $0.key == ch && $0.enabled }) {
                    index = hit
                    dispatch(hit)
                }
            }
        }
    }

    // MARK: - Rendering

    private static func renderBlock(
        title: String?,
        header: String?,
        items: [MenuItem],
        index: Int,
        allowBack: Bool,
        drawnLines: inout Int,
        first: Bool
    ) {
        if !first {
            // Move cursor up over the previously-drawn block and clear each line.
            fputs("\u{1B}[\(drawnLines)A", stdout)
        }
        var lines = 0
        func emit(_ s: String) { fputs("\u{1B}[2K\(s)\n", stdout); lines += 1 }

        if let title = title {
            for line in title.split(separator: "\n", omittingEmptySubsequences: false) { emit(String(line)) }
        }
        if let header = header {
            for line in header.split(separator: "\n", omittingEmptySubsequences: false) { emit(String(line)) }
        }
        for (i, item) in items.enumerated() {
            if !item.enabled {
                // Dimmed, non-selectable row (separator / unavailable option),
                // aligned under the selectable labels (2 marker + 3 key cols).
                emit("\u{1B}[2m     \(item.label)\u{1B}[0m")
                continue
            }
            let marker = (i == index) ? "\u{1B}[36m▸\u{1B}[0m " : "  "
            let keyHint = item.key.map { "\($0)) " } ?? "   "
            let label = (i == index) ? "\u{1B}[1m\(item.label)\u{1B}[0m" : item.label
            emit("\(marker)\(keyHint)\(label)")
        }
        let footer = allowBack
            ? "  ↑↓ move · enter select · b back · q quit"
            : "  ↑↓ move · enter select · q quit"
        emit("\u{1B}[2m\(footer)\u{1B}[0m")
        fflush(stdout)
        drawnLines = lines
    }

    // MARK: - Navigation helpers

    /// Next enabled index in `dir` (+1 / -1), wrapping. Returns `from` if no
    /// other enabled item exists.
    private static func step(_ items: [MenuItem], from i: Int, by dir: Int) -> Int {
        guard items.contains(where: { $0.enabled }) else { return i }
        var j = i
        for _ in 0..<items.count {
            j = (j + dir + items.count) % items.count
            if items[j].enabled { return j }
        }
        return i
    }

    private static func firstEnabled(_ items: [MenuItem]) -> Int {
        items.firstIndex(where: { $0.enabled }) ?? 0
    }

    // MARK: - termios helpers

    private static func enterRaw(_ original: inout termios) {
        var raw = original
        raw.c_lflag &= ~(UInt(ICANON) | UInt(ECHO))
        _ = tcsetattr(fileno(stdin), TCSANOW, &raw)
    }

    // Best-effort terminal restore on SIGINT so Ctrl-C never leaves the user's
    // shell in cbreak mode. Returns the previous handler to reinstate on exit.
    private static func installSigintRestore() -> (@convention(c) (Int32) -> Void)? {
        signal(SIGINT) { _ in
            var t = termios()
            if tcgetattr(fileno(stdin), &t) == 0 {
                t.c_lflag |= UInt(ICANON) | UInt(ECHO)
                _ = tcsetattr(fileno(stdin), TCSANOW, &t)
            }
            _ = write(fileno(stdout), "\n", 1)
            exit(130)
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

    // MARK: - Non-TTY fallbacks

    private static func lineFallback(
        title: String?,
        header: String?,
        items: [MenuItem],
        allowBack: Bool
    ) -> MenuPick {
        if let title = title { print(title) }
        if let header = header { print(header) }
        for (i, item) in items.enumerated() {
            if !item.enabled { print("     \(item.label)"); continue }
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
        if let ch = s.first, let hit = items.firstIndex(where: { $0.key == ch && $0.enabled }) {
            return .selected(hit)
        }
        if let n = Int(s), n >= 1, n <= items.count, items[n - 1].enabled {
            return .selected(n - 1)
        }
        return allowBack ? .back : .selected(0)
    }

    private static func runLineFallback(
        title: String?,
        header: String?,
        items: () -> [MenuItem],
        onSelect: (Int) -> Void
    ) {
        while true {
            let current = items()
            if let title = title { print(title) }
            if let header = header { print(header) }
            for (i, item) in current.enumerated() {
                if !item.enabled { print("     \(item.label)"); continue }
                let k = item.key.map { "\($0)) " } ?? "\(i + 1)) "
                print("  \(k)\(item.label)")
            }
            fputs("> ", stdout)
            guard let raw = readLine() else { return }
            let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if s.isEmpty || s == "b" || s == "back" || s == "q" || s == "quit" { return }
            if let ch = s.first, let hit = current.firstIndex(where: { $0.key == ch && $0.enabled }) {
                onSelect(hit); continue
            }
            if let n = Int(s), n >= 1, n <= current.count, current[n - 1].enabled {
                onSelect(n - 1)
            }
        }
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
