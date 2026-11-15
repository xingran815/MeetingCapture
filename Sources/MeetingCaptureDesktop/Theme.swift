import AppKit
import SwiftUI

// M7 (D-101): the "Terminal Native" look. Every colour, font and recurring shape the
// views draw comes from this file, so the two themes stay one decision in one place.
// Mock-ups are private (spec 07); the values here are the spec's.

/// Which theme the user picked in Settings. `system` follows the Mac's appearance.
enum ThemeChoice: String, CaseIterable, Identifiable {
    case system, phosphor, paper
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Follow the Mac"
        case .phosphor: return "Phosphor (dark)"
        case .paper: return "Paper (light)"
        }
    }

    /// Desktop-only preference keys (UserDefaults; the terminal has no window to theme).
    static let storageKey = "themeChoice"

    /// Screenshots under `MEETINGCAPTURE_E2E=1` pin a theme without touching the user's
    /// defaults: `MEETINGCAPTURE_THEME=phosphor|paper`.
    static var testOverride: ThemeChoice? {
        let env = ProcessInfo.processInfo.environment
        guard env["MEETINGCAPTURE_E2E"] == "1", let raw = env["MEETINGCAPTURE_THEME"] else { return nil }
        return ThemeChoice(rawValue: raw)
    }
}

/// One theme's colours as 0xRRGGBB, so tests can check contrast without SwiftUI.
struct TerminalPalette: Equatable {
    var ground: UInt32  // window background
    var ground2: UInt32  // sidebar, bars, boxes
    var ground3: UInt32  // key caps, tokens
    var line: UInt32  // quiet rules
    var line2: UInt32  // box borders
    var text: UInt32
    var dim: UInt32  // secondary text; reaches 4.5:1 on ground
    var faint: UInt32  // decoration only (##, tree lines), never needed to read
    var accent: UInt32  // phosphor green / ink green
    var amber: UInt32  // paused and warnings
    var rec: UInt32  // only while recording
    var selection: UInt32
    /// Text drawn on a solid accent, amber or rec block.
    var onAccent: UInt32
    var onRec: UInt32
    var onAmber: UInt32

    static let phosphor = TerminalPalette(
        ground: 0x0a0d0b, ground2: 0x0f1411, ground3: 0x151c17, line: 0x2a3a2f, line2: 0x3d5444,
        text: 0xd6f5df, dim: 0x8fa696, faint: 0x5d7264, accent: 0x4dff9a, amber: 0xffb340, rec: 0xff5c5c,
        selection: 0x173322, onAccent: 0x0a0d0b, onRec: 0x0a0d0b, onAmber: 0x1b1206)

    static let paper = TerminalPalette(
        ground: 0xf2eee2, ground2: 0xe9e4d4, ground3: 0xded8c4, line: 0xb9b19a, line2: 0x8f876f,
        text: 0x1b241d, dim: 0x4a5549, faint: 0x6d7468, accent: 0x0b6a33, amber: 0x7a4a00, rec: 0xa8161b,
        selection: 0xd3e2cf, onAccent: 0xf2eee2, onRec: 0xffffff, onAmber: 0xf2eee2)

    /// WCAG contrast ratio between two colours.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func lum(_ c: UInt32) -> Double {
            func ch(_ v: UInt32) -> Double {
                let s = Double(v) / 255
                return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * ch(c >> 16 & 0xff) + 0.7152 * ch(c >> 8 & 0xff) + 0.0722 * ch(c & 0xff)
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func css(_ c: UInt32) -> String { String(format: "#%06x", c) }
}

/// The theme the views read: `@Environment(\.theme)`.
struct TerminalTheme: Equatable {
    var name: String
    var isDark: Bool
    var palette: TerminalPalette

    static let phosphor = TerminalTheme(name: "phosphor", isDark: true, palette: .phosphor)
    static let paper = TerminalTheme(name: "paper", isDark: false, palette: .paper)

    static func resolve(_ choice: ThemeChoice, scheme: ColorScheme) -> TerminalTheme {
        switch choice {
        case .phosphor: return .phosphor
        case .paper: return .paper
        case .system: return scheme == .dark ? .phosphor : .paper
        }
    }

    var ground: Color { Color(hex: palette.ground) }
    var ground2: Color { Color(hex: palette.ground2) }
    var ground3: Color { Color(hex: palette.ground3) }
    var line: Color { Color(hex: palette.line) }
    var line2: Color { Color(hex: palette.line2) }
    var text: Color { Color(hex: palette.text) }
    var dim: Color { Color(hex: palette.dim) }
    var faint: Color { Color(hex: palette.faint) }
    var accent: Color { Color(hex: palette.accent) }
    var amber: Color { Color(hex: palette.amber) }
    var rec: Color { Color(hex: palette.rec) }
    var selection: Color { Color(hex: palette.selection) }
    var onAccent: Color { Color(hex: palette.onAccent) }
    var onRec: Color { Color(hex: palette.onRec) }
    var onAmber: Color { Color(hex: palette.onAmber) }
    var amberWash: Color { amber.opacity(0.10) }
    var recWash: Color { rec.opacity(isDark ? 0.12 : 0.08) }
    var colorScheme: ColorScheme { isDark ? .dark : .light }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB, red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255,
            blue: Double(hex & 0xff) / 255)
    }
}

extension EnvironmentValues {
    @Entry var theme: TerminalTheme = .phosphor
}

extension Font {
    /// SF Mono, the system monospaced face (D-102), so no font is bundled.
    static func mono(_ size: CGFloat = 13, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Puts the chosen theme in the environment and makes the window's chrome match.
struct ThemedRoot: ViewModifier {
    @AppStorage(ThemeChoice.storageKey) private var stored = ThemeChoice.system.rawValue
    @Environment(\.colorScheme) private var scheme

    private var choice: ThemeChoice { ThemeChoice.testOverride ?? ThemeChoice(rawValue: stored) ?? .system }

    func body(content: Content) -> some View {
        let theme = TerminalTheme.resolve(choice, scheme: scheme)
        content
            .environment(\.theme, theme)
            .font(.mono())
            .foregroundStyle(theme.text)
            .tint(theme.accent)
            .background(theme.ground)
            // A pinned theme pins the controls too; "Follow the Mac" leaves them alone.
            .preferredColorScheme(choice == .system ? nil : theme.colorScheme)
    }
}

extension View {
    func terminalThemed() -> some View { modifier(ThemedRoot()) }
}

// MARK: - Recurring shapes

/// A key hint: `⌘R` in a small key cap.
struct Kbd: View {
    @Environment(\.theme) private var theme
    let keys: String
    var inverted = false
    init(_ keys: String, inverted: Bool = false) {
        self.keys = keys
        self.inverted = inverted
    }

    var body: some View {
        Text(keys)
            .font(.mono(11, .medium))
            .padding(.horizontal, 4).padding(.vertical, 0.5)
            .foregroundStyle(inverted ? theme.onAccent : theme.text)
            .background(inverted ? Color.clear : theme.ground3)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(inverted ? theme.onAccent : theme.line2, lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}

/// `## TITLE ---------`: a section head with a dashed rule to the edge.
struct SectionHead: View {
    @Environment(\.theme) private var theme
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        HStack(spacing: 10) {
            Text("##").foregroundStyle(theme.faint)
            Text(title.uppercased()).foregroundStyle(theme.accent).tracking(1)
            DashedRule().frame(height: 1)
        }
        .font(.mono(13, .bold))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
    }
}

struct DashedRule: View {
    @Environment(\.theme) private var theme
    var body: some View {
        GeometryReader { g in
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0.5))
                p.addLine(to: CGPoint(x: g.size.width, y: 0.5))
            }
            .stroke(theme.line2, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }
}

/// A box with its label set into the top border: `┌─ LABEL ─────┐`.
struct TerminalBox<Content: View>: View {
    @Environment(\.theme) private var theme
    let label: String?
    var tint: Color?
    @ViewBuilder var content: Content

    init(_ label: String? = nil, tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 14).padding(.top, label == nil ? 12 : 16).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Rectangle().strokeBorder(tint ?? theme.line2, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if let label {
                    HStack(spacing: 0) {
                        Text("─ ").foregroundStyle(tint ?? theme.line2)
                        Text(label.uppercased()).foregroundStyle(tint ?? theme.accent).tracking(0.8)
                        Text(" ─").foregroundStyle(tint ?? theme.line2)
                    }
                    .font(.mono(11.5, .semibold))
                    .padding(.horizontal, 4)
                    .background(theme.ground)
                    .offset(x: 10, y: -8)
                    .accessibilityAddTraits(.isHeader)
                }
            }
    }
}

/// The look of every button in the window: square, bordered, its key beside it.
struct TerminalButtonStyle: ButtonStyle {
    enum Kind { case plain, go, stop, quiet }
    var kind: Kind = .plain
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let (fg, bg, border) = colors
        configuration.label
            .font(.mono(12.5, .bold))
            .padding(.horizontal, kind == .quiet ? 8 : 12).padding(.vertical, kind == .quiet ? 3 : 7)
            .foregroundStyle(fg)
            .background(bg.opacity(configuration.isPressed ? 0.75 : 1))
            .overlay(Rectangle().strokeBorder(border, lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }

    private var colors: (Color, Color, Color) {
        switch kind {
        case .plain: return (theme.text, theme.ground2, theme.line2)
        case .go: return (theme.onAccent, theme.accent, theme.accent)
        case .stop: return (theme.rec, theme.ground2, theme.rec)
        case .quiet: return (theme.text, theme.ground, theme.line)
        }
    }
}

extension ButtonStyle where Self == TerminalButtonStyle {
    static var terminal: TerminalButtonStyle { TerminalButtonStyle() }
    static func terminal(_ kind: TerminalButtonStyle.Kind) -> TerminalButtonStyle { TerminalButtonStyle(kind: kind) }
}

/// A button's title with its key hint: `‖ Pause ⇧⌘P`.
struct KeyedLabel: View {
    let title: String
    let keys: String?
    var inverted = false
    init(_ title: String, keys: String? = nil, inverted: Bool = false) {
        self.title = title
        self.keys = keys
        self.inverted = inverted
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
            if let keys { Kbd(keys, inverted: inverted) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.trimmingCharacters(in: CharacterSet.letters.inverted.subtracting(.whitespaces)))
    }
}

/// Block characters: a level meter `██████░░░░` or a progress bar `[███░░] 64%`.
enum Blocks {
    static func meter(_ level: Double, width: Int) -> String {
        let n = Int((min(max(level, 0), 1) * Double(width)).rounded())
        return String(repeating: "█", count: n) + String(repeating: "░", count: width - n)
    }

    static func progress(_ fraction: Double, width: Int = 22) -> String {
        let f = min(max(fraction, 0), 1)
        return "[\(meter(f, width: width))] \(Int((f * 100).rounded()))%"
    }
}

/// The braille spinner `⠋⠙⠹…`; a still `⠿` with Reduce Motion.
struct Spinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let frames = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    var body: some View {
        if reduceMotion {
            Text("⠿").accessibilityHidden(true)
        } else {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let i = Int(context.date.timeIntervalSinceReferenceDate * 10) % Self.frames.count
                Text(String(Self.frames[i]))
            }
            .accessibilityHidden(true)
        }
    }
}

/// The blinking block cursor after `● REC`, the only blink in the app.
struct BlockCursor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = reduceMotion || Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Rectangle().fill(color.opacity(on ? 1 : 0)).frame(width: 9, height: 15)
        }
        .accessibilityHidden(true)
    }
}

/// The "Prompt Bubble" mark (D-101): a square-cornered speech bubble holding `>_`, from
/// `scripts/make-brand.sh`'s 64-unit grid, in the theme's accent.
struct BrandMark: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Canvas { context, size in
            let k = min(size.width, size.height) / 64
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
            let style = StrokeStyle(lineWidth: 5 * k, lineCap: .square, lineJoin: .miter)
            var bubble = Path()
            bubble.move(to: p(6, 8))
            for point in [p(58, 8), p(58, 44), p(24, 44), p(12, 56), p(12, 44), p(6, 44)] { bubble.addLine(to: point) }
            bubble.closeSubpath()
            context.stroke(bubble, with: .color(theme.accent), style: style)
            var chevron = Path()
            chevron.move(to: p(16, 17))
            chevron.addLine(to: p(26, 25.5))
            chevron.addLine(to: p(16, 34))
            context.stroke(chevron, with: .color(theme.accent), style: style)
            context.fill(
                Path(CGRect(origin: p(30, 30), size: CGSize(width: 16 * k, height: 4.5 * k))),
                with: .color(theme.accent))
        }
        .accessibilityLabel("MeetingCapture")
    }
}

// MARK: - The report page

/// The report is the same self-contained HTML the terminal writes (spec 04). In the app
/// it gets the theme laid over it: a `<style>` added before `</head>`, never written to
/// the file. The page's CSP allows inline styles, and the CSS here is fixed text built
/// from the palette, so nothing from the report reaches it.
enum ReportTheme {
    static func apply(_ theme: TerminalTheme, to html: String) -> String {
        let style = "<style id=\"mc-theme\">\(css(theme))</style>"
        guard let head = html.range(of: "</head>", options: .caseInsensitive) else {
            return style + html
        }
        var out = html
        out.insert(contentsOf: style, at: head.lowerBound)
        return out
    }

    static func css(_ theme: TerminalTheme) -> String {
        let p = theme.palette
        let c = TerminalPalette.css
        let hl = theme.isDark ? "#3a3200" : "#f3df8a"
        return """
            :root{color-scheme:\(theme.isDark ? "dark" : "light");--bg:\(c(p.ground));--fg:\(c(p.text));--muted:\(c(p.dim));--line:\(c(p.line));--card:\(c(p.ground2));--key:\(c(p.accent));--ai:\(c(p.accent));--ai-bg:\(c(p.selection));--warn:\(c(p.amber));--warn-bg:\(c(p.ground2));--link:\(c(p.accent));--hl:\(hl)}
            body{font:14px/1.6 ui-monospace,"SF Mono",Menlo,monospace;background:var(--bg);color:var(--fg)}
            h1{font-weight:800;letter-spacing:-.01em}
            h2{font-size:.95rem;text-transform:uppercase;letter-spacing:.08em;color:var(--key);border-bottom:1px dashed \(c(p.line2))}
            h2::before{content:"## ";color:\(c(p.faint))}
            .glance h2::before{content:""}
            .tag,.badge,.mark,.pri,.box,.banner,.glance,.qa,.concept,#q,mark,.ai{border-radius:0}
            .pri{color:\(c(p.onAccent))}
            .banner{border:1px dashed var(--warn)}
            .glance{border-left-width:1px;border-color:\(c(p.line2))}
            .ai{border-left-width:2px}
            .lines li{border-bottom:1px dotted var(--line)}
            ::selection{background:var(--key);color:var(--bg)}
            """
    }
}
