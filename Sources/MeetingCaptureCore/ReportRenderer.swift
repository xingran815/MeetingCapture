import CryptoKit
import Foundation

// Step 5 of spec 04: the final JSON becomes a self-contained HTML page, with no
// model involved. Every string from a model or the transcript goes through
// `escape`, and links only through `safeURL`, so a transcript line saying
// `<script>` renders as text. The page also carries a Content-Security-Policy
// that blocks every external request, as a second line of defence.

enum ReportRenderer {

    // MARK: - Escaping

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            case "\u{0}": out += "\u{FFFD}"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    /// The URL if it's `http` or `https` with a host, else nil. Anything else, such
    /// as `javascript:` or `data:`, is shown as plain text and never linked.
    static func safeURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isWhitespace || $0.asciiValue.map { $0 < 0x20 || $0 == 0x7F } == true }),
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty,
            let url = components.url
        else { return nil }
        return url
    }

    // MARK: - HTML

    static func html(_ report: Report) -> String {
        var body = ""
        body += "<header><p class=\"kind\">\(escape(report.scenarioTitle))</p>"
        body += "<h1>\(escape(report.topic))</h1>"
        body += "<p class=\"meta\">\(escape(metaLine(report)))</p></header>\n"

        if !report.reviewed {
            body +=
                "<div class=\"banner\" role=\"note\"><strong>Not reviewed.</strong> The frontier review didn't run, so this is the first draft.</div>\n"
        }
        if !report.notices.isEmpty {
            body += "<ul class=\"notices\">"
            for n in report.notices { body += "<li>\(escape(n))</li>" }
            body += "</ul>\n"
        }

        let key = keyItems(report)
        if !key.isEmpty {
            body += "<aside class=\"glance\"><h2>At a glance</h2><ul>"
            for (section, item) in key {
                body += "<li><a class=\"from\" href=\"#s-\(escape(section.id))\">\(escape(section.title))</a> "
                body += hl(item.text, item)
                if let o = item.owner, !o.isEmpty { body += " <span class=\"tag\">Owner: \(escape(o))</span>" }
                if let d = item.due, !d.isEmpty { body += " <span class=\"tag\">Due: \(escape(d))</span>" }
                if item.isUnsure { body += " <span class=\"mark\">Unsure</span>" }
                body += "</li>"
            }
            body += "</ul></aside>\n"
        }
        body += "<nav><ul>"
        for s in report.sections { body += "<li><a href=\"#s-\(escape(s.id))\">\(escape(s.title))</a></li>" }
        body += "<li><a href=\"#transcript\">Transcript</a></li></ul></nav>\n<main>\n"

        for section in report.sections { body += sectionHTML(section) }

        if !report.reviewChanges.isEmpty {
            body +=
                "<details class=\"changes\"><summary>What the review changed (\(report.reviewChanges.count))</summary><ul>"
            for c in report.reviewChanges {
                body += "<li>\(escape(c.what))"
                if !c.why.isEmpty { body += " <span class=\"why\">— \(escape(c.why))</span>" }
                body += "</li>"
            }
            body += "</ul></details>\n"
        }

        body += transcriptHTML(report)
        body += "</main>\n"
        body += "<footer>\(escape(modelsLine(report)))</footer>\n"

        let lang = report.language.isEmpty ? "" : " lang=\"\(escape(report.language))\""
        return """
            <!doctype html>
            <html\(lang)>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src '\(scriptHash)'; img-src data:; base-uri 'none'; form-action 'none'">
            <meta name="referrer" content="no-referrer">
            <title>\(escape(report.topic))</title>
            <style>\(css)</style>
            </head>
            <body>
            \(body)<script>\(script)</script>
            </body>
            </html>

            """
    }

    private static func sectionHTML(_ section: Report.Section) -> String {
        var h = "<section id=\"s-\(escape(section.id))\" class=\"kind-\(section.kind.rawValue)\">"
        h += "<h2>\(escape(section.title))</h2>"
        if let note = section.note, !note.isEmpty { h += "<p class=\"note\">\(escape(note))</p>" }
        if section.items.isEmpty {
            return h + "<p class=\"empty\">Nothing for this section.</p></section>\n"
        }
        switch section.kind {
        case .prose:
            for item in section.items {
                h += "<div\(cls(item))>\(pri(item))\(para(item.text, keywords: item.keywords))\(marks(item))</div>"
            }
        case .bullets, .insights:
            h += "<ul>"
            for item in section.items {
                h += "<li\(cls(item))>\(pri(item))"
                if let s = item.speaker, !s.isEmpty { h += "<span class=\"speaker\">\(escape(s))</span> " }
                h += hl(item.text, item)
                if let q = item.quote, !q.isEmpty { h += "<q>\(escape(q))</q>" }
                h += marks(item) + "</li>"
            }
            h += "</ul>"
        case .actions:
            h += "<ul class=\"todo\">"
            for item in section.items {
                h +=
                    "<li\(cls(item))><span class=\"box\" aria-hidden=\"true\"></span> \(pri(item))\(hl(item.text, item))"
                if let o = item.owner, !o.isEmpty { h += " <span class=\"tag\">Owner: \(escape(o))</span>" }
                if let d = item.due, !d.isEmpty { h += " <span class=\"tag\">Due: \(escape(d))</span>" }
                h += marks(item) + "</li>"
            }
            h += "</ul>"
        case .qa:
            for item in section.items {
                h +=
                    "<div class=\"qa\(stateClasses(item))\"><p class=\"q\">\(pri(item))\(hl(item.text, item))</p>"
                let answer = (item.answer ?? "").isEmpty ? "I don't know." : item.answer!
                h += "<p class=\"a ai\"><span class=\"badge\">AI</span> \(hl(answer, item))</p>\(marks(item))</div>"
            }
        case .goals:
            h += "<ol class=\"goals\">"
            for item in section.items {
                h += "<li\(cls(item))>\(pri(item))\(hl(item.text, item))"
                if let q = item.quote, !q.isEmpty {
                    h += "<br><span class=\"said\">In their words:</span> <q>\(escape(q))</q>"
                }
                if let d = item.due, !d.isEmpty { h += " <span class=\"tag\">By: \(escape(d))</span>" }
                h += marks(item) + "</li>"
            }
            h += "</ol>"
        case .concepts:
            for item in section.items {
                h +=
                    "<article class=\"concept\(stateClasses(item))\"><h3>\(pri(item))\(escape(item.text ?? ""))</h3><dl>"
                if let q = item.quote, !q.isEmpty { h += "<dt>What was said</dt><dd><q>\(escape(q))</q></dd>" }
                if let a = item.answer, !a.isEmpty {
                    h +=
                        "<dt>What the AI understands</dt><dd class=\"ai\"><span class=\"badge\">AI</span> \(hl(a, item))</dd>"
                }
                if let d = item.detail, !d.isEmpty { h += "<dt>More detail</dt><dd class=\"ai\">\(para(d))</dd>" }
                h += "<dt>Sources</dt><dd>"
                let links = item.sources ?? []
                if links.isEmpty {
                    h += "<span class=\"empty\">None found.</span>"
                } else {
                    h += "<ul class=\"sources\">"
                    for link in links { h += "<li>\(linkHTML(link))</li>" }
                    h += "</ul>"
                }
                h += "</dd></dl>\(marks(item))</article>"
            }
        }
        return h + "</section>\n"
    }

    /// ` unsure`, ` high`, ` low` as they apply, for boxes that carry their own class.
    private static func stateClasses(_ item: Report.Item) -> String {
        (item.isUnsure ? " unsure" : "") + (item.isHigh ? " high" : "") + (item.isLow ? " low" : "")
    }

    private static func cls(_ item: Report.Item) -> String {
        var names: [String] = []
        if item.isAI { names.append("ai") }
        if item.isUnsure { names.append("unsure") }
        if item.isHigh { names.append("high") }
        if item.isLow { names.append("low") }
        return names.isEmpty ? "" : " class=\"\(names.joined(separator: " "))\""
    }

    /// The AI badge and the unsure marker with its reason, both visible.
    private static func marks(_ item: Report.Item) -> String {
        var h = ""
        if item.isUnsure {
            let reason = (item.reason ?? "").isEmpty ? "no reason given" : item.reason!
            h += "<p class=\"doubt\"><span class=\"mark\">Unsure</span> \(escape(reason))</p>"
        } else if let reason = item.reason, !reason.isEmpty {
            h += "<p class=\"why\">\(escape(reason))</p>"
        }
        return h
    }

    private static func para(_ text: String?, keywords: [String]? = nil) -> String {
        (text ?? "").components(separatedBy: "\n\n").filter { !$0.isEmpty }
            .map { "<p>\(highlight($0, keywords).replacingOccurrences(of: "\n", with: "<br>"))</p>" }.joined()
    }

    /// The badge for a high-priority item, so it stands out on a skim.
    private static func pri(_ item: Report.Item) -> String {
        item.isHigh ? "<span class=\"pri\">Key</span> " : ""
    }

    private static func hl(_ text: String?, _ item: Report.Item) -> String {
        highlight(text ?? "", item.keywords)
    }

    /// Escapes `text` and wraps each keyword it contains in `<mark>`. The text is
    /// cut into pieces first and every piece is escaped on its own, so a keyword
    /// can never open or close markup.
    static func highlight(_ text: String, _ keywords: [String]?) -> String {
        wrap(text, keywords, open: "<mark>", close: "</mark>", piece: escape)
    }

    /// Cuts `text` at every keyword (any case; earliest first, longest first, no
    /// overlaps), passes each piece through `piece`, and puts `open`/`close`
    /// around the keyword pieces. Used for HTML, markdown and the terminal.
    static func wrap(
        _ text: String, _ keywords: [String]?, open: String, close: String, piece: (String) -> String
    ) -> String {
        let ns = text as NSString
        var ranges: [NSRange] = []
        for k in keywords ?? [] where !k.isEmpty {
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let r = ns.range(of: k, options: [.caseInsensitive], range: search)
                if r.location == NSNotFound || r.length == 0 { break }
                ranges.append(r)
                let next = r.location + r.length
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        // Earliest first, longest first at the same start; overlaps are dropped.
        ranges.sort { $0.location != $1.location ? $0.location < $1.location : $0.length > $1.length }
        var out = ""
        var cursor = 0
        for r in ranges where r.location >= cursor {
            out += piece(ns.substring(with: NSRange(location: cursor, length: r.location - cursor)))
            out += open + piece(ns.substring(with: r)) + close
            cursor = r.location + r.length
        }
        return out + piece(ns.substring(from: cursor))
    }

    /// High-priority items from every section, for the top of the page.
    static func keyItems(_ report: Report, limit: Int = 8) -> [(section: Report.Section, item: Report.Item)] {
        Array(report.sections.flatMap { s in s.items.filter(\.isHigh).map { (s, $0) } }.prefix(limit))
    }

    static func linkHTML(_ link: Report.Link) -> String {
        let title = link.title.isEmpty ? link.url : link.title
        guard let url = safeURL(link.url) else {
            return "\(escape(title)) <span class=\"tag\">link not shown: not http or https</span>"
        }
        return
            "<a href=\"\(escape(url.absoluteString))\" rel=\"noopener noreferrer nofollow\" target=\"_blank\">\(escape(title))</a>"
    }

    private static func transcriptHTML(_ report: Report) -> String {
        var h = "<section id=\"transcript\"><h2>Transcript</h2>"
        h +=
            "<input type=\"search\" id=\"q\" placeholder=\"Search the transcript\" aria-label=\"Search the transcript\">"
        h += "<p class=\"count\" id=\"count\"></p><ol class=\"lines\">"
        for e in report.transcript {
            h += "<li><span class=\"time\">\(TranscriptParser.clock(e.start))</span>"
            if !e.speaker.isEmpty { h += " <span class=\"speaker\">\(escape(e.speaker))</span>" }
            h += " <span class=\"text\">\(escape(e.text))</span>"
            if let s = e.suggestion, !s.isEmpty {
                h += "<div class=\"suggestion ai\"><span class=\"badge\">Suggested</span> \(escape(s))</div>"
            }
            h += "</li>"
        }
        return h + "</ol></section>\n"
    }

    /// Date as written in `createdAt` (local time of the run), so the page reads the
    /// same on any machine and snapshot tests are stable.
    static func metaLine(_ report: Report) -> String {
        var parts: [String] = []
        let iso = report.createdAt
        if iso.count >= 16, iso.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}"#, options: .regularExpression) != nil {
            parts.append(String(iso.prefix(16)).replacingOccurrences(of: "T", with: " "))
        }
        if report.durationSeconds > 0 { parts.append("about \(TranscriptParser.clock(report.durationSeconds))") }
        parts.append(report.reviewed ? "reviewed" : "not reviewed")
        return parts.joined(separator: " · ")
    }

    static func modelsLine(_ report: Report) -> String {
        let m = report.models
        let parts = [("classify", m.cheap), ("sections", m.normal), ("review", m.frontier)]
            .filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }
        return "Written by AI from an automatic transcript. "
            + (parts.isEmpty ? "" : "Models — " + parts.joined(separator: ", ") + ".")
    }

    private static let css = """
        :root{--hl:#ffe680;--key:#c2410c;--bg:#fbfaf8;--fg:#1d1d1f;--muted:#6b6b70;--line:#e3e1dc;--card:#fff;--ai:#5b4bb7;--ai-bg:#f3f0ff;--warn:#9a5b00;--warn-bg:#fff4e0;--link:#0a58ca}
        @media (prefers-color-scheme:dark){:root{--hl:#5c4a00;--key:#fb923c;--bg:#161618;--fg:#ececee;--muted:#a0a0a8;--line:#2e2e33;--card:#1f1f23;--ai:#b9adff;--ai-bg:#26223a;--warn:#ffc46b;--warn-bg:#33270f;--link:#8ab4ff}}
        *{box-sizing:border-box}
        body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Hiragino Sans GB",sans-serif;padding:24px 16px 64px}
        header,nav,main,footer,.banner,.notices,.glance{max-width:820px;margin-left:auto;margin-right:auto}
        h1{font-size:1.8rem;line-height:1.25;margin:.2rem 0}
        h2{font-size:1.2rem;margin:2rem 0 .6rem;padding-bottom:.3rem;border-bottom:1px solid var(--line)}
        h3{font-size:1.05rem;margin:0 0 .4rem}
        .kind{text-transform:uppercase;letter-spacing:.08em;font-size:.75rem;color:var(--muted);margin:0}
        .meta,.note,.empty,.count,footer,.why{color:var(--muted);font-size:.9rem}
        .banner{background:var(--warn-bg);color:var(--warn);border-radius:8px;padding:10px 14px;margin-top:16px}
        .notices{color:var(--muted);font-size:.9rem;padding-left:1.2rem}
        nav ul{list-style:none;padding:0;display:flex;flex-wrap:wrap;gap:6px 14px;font-size:.9rem}
        a{color:var(--link)}
        ul,ol{padding-left:1.3rem}
        li{margin:.3rem 0}
        .speaker{font-weight:600}
        .speaker::after{content:":"}
        .lines .speaker::after{content:""}
        q{font-style:italic;margin-left:.3em}
        .tag{display:inline-block;font-size:.78rem;color:var(--muted);border:1px solid var(--line);border-radius:999px;padding:0 8px;margin-left:4px}
        .todo{list-style:none;padding-left:0}
        .box{display:inline-block;width:.9em;height:.9em;border:1.5px solid var(--muted);border-radius:3px;vertical-align:-1px}
        .ai{background:var(--ai-bg);border-left:3px solid var(--ai);padding:4px 10px;border-radius:0 6px 6px 0}
        li.ai{list-style:none;margin-left:-1.3rem}
        .badge{display:inline-block;font-size:.7rem;font-weight:700;letter-spacing:.05em;color:var(--ai);border:1px solid var(--ai);border-radius:4px;padding:0 4px;margin-right:4px;vertical-align:1px}
        .doubt{margin:.25rem 0 0;font-size:.88rem;color:var(--warn)}
        .mark{display:inline-block;font-weight:700;font-size:.72rem;background:var(--warn-bg);color:var(--warn);border:1px dashed var(--warn);border-radius:4px;padding:0 5px;margin-right:4px}
        .unsure{outline:1px dashed var(--warn);outline-offset:3px;border-radius:4px}
        mark{background:var(--hl);color:inherit;border-radius:3px;padding:0 2px}
        .pri{display:inline-block;font-size:.7rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase;color:var(--bg);background:var(--key);border-radius:4px;padding:1px 5px;margin-right:4px;vertical-align:1px}
        li.high,div.high,.qa.high,.concept.high{border-left:3px solid var(--key);padding-left:8px}
        li.high{margin-left:-11px}
        .low{color:var(--muted);font-size:.93rem}
        .glance{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--key);border-radius:10px;padding:4px 16px 8px;margin-top:16px}
        .glance h2{border:0;margin:.6rem 0 .2rem;font-size:1rem;text-transform:uppercase;letter-spacing:.06em;color:var(--key)}
        .glance ul{padding-left:1.1rem}
        .glance .from{font-size:.78rem;color:var(--muted);margin-right:4px;text-decoration:none}
        .glance .from::after{content:" ›"}
        .qa,.concept{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px;margin:10px 0}
        .q{font-weight:600;margin:0 0 .4rem}
        .a{margin:0}
        dt{font-size:.8rem;color:var(--muted);margin-top:.5rem}
        dd{margin:0}
        details.changes{margin-top:2rem}
        summary{cursor:pointer;font-weight:600}
        #q{width:100%;padding:8px 10px;font:inherit;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--fg)}
        .lines{list-style:none;padding:0;font-size:.95rem}
        .lines li{padding:4px 0;border-bottom:1px solid var(--line)}
        .time{font-variant-numeric:tabular-nums;color:var(--muted);font-size:.85rem}
        .suggestion{margin-top:4px;font-size:.9rem}
        .hidden{display:none}
        @media print{body{background:#fff;color:#000;padding:0}mark{background:none;text-decoration:underline}.pri{color:#000;background:none;border:1px solid #000}nav,#q,.count{display:none}a{color:#000}a[href]::after{content:" (" attr(href) ")";font-size:.8em}.ai{background:none}details{display:block}details>summary{list-style:none}h2{break-after:avoid}.qa,.concept,li{break-inside:avoid}}
        """

    /// Search filters transcript lines by their text content; it never builds HTML.
    /// The CSP allows only this exact script, by hash, so a missed escape still can't run one.
    static var scriptHash: String {
        "sha256-" + Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
    }

    static let script = """
        (function(){var q=document.getElementById('q'),c=document.getElementById('count');if(!q)return;var rows=Array.prototype.slice.call(document.querySelectorAll('.lines li'));q.addEventListener('input',function(){var t=q.value.trim().toLowerCase(),n=0;rows.forEach(function(r){var hit=!t||r.textContent.toLowerCase().indexOf(t)>=0;r.classList.toggle('hidden',!hit);if(hit)n++;});c.textContent=t?n+' of '+rows.length+' lines':'';});document.querySelectorAll('details').forEach(function(d){window.addEventListener('beforeprint',function(){d.open=true;});});})();
        """

    // MARK: - Markdown, for tools that read `.md`

    static func markdown(_ report: Report) -> String {
        var md = "# \(mdLine(report.topic))\n\n_\(report.scenarioTitle) · \(metaLine(report))_\n"
        if !report.reviewed {
            md += "\n> **Not reviewed.** The frontier review didn't run, so this is the first draft.\n"
        }
        let key = keyItems(report)
        if !key.isEmpty {
            md += "\n## At a glance\n\n"
            for (section, item) in key {
                md += "- \(mdBold(oneLine(item.text), item.keywords))"
                if let o = item.owner, !o.isEmpty { md += " (owner: \(mdLine(o)))" }
                if let d = item.due, !d.isEmpty { md += " (due: \(mdLine(d)))" }
                md += " _(\(mdLine(section.title)))_\(unsureSuffix(item))\n"
            }
        }
        for section in report.sections {
            md += "\n## \(mdLine(section.title))\n"
            if let note = section.note, !note.isEmpty { md += "_\(mdLine(note))_\n" }
            if section.items.isEmpty {
                md += "\nNone.\n"
                continue
            }
            md += "\n"
            for item in section.items { md += markdownItem(item, kind: section.kind) }
        }
        if !report.reviewChanges.isEmpty {
            md += "\n## What the review changed\n\n"
            for c in report.reviewChanges { md += "- \(mdLine(c.what))\(c.why.isEmpty ? "" : " — \(mdLine(c.why))")\n" }
        }
        if !report.notices.isEmpty {
            md += "\n---\n" + report.notices.map { "> Note: \(mdLine($0))" }.joined(separator: "\n") + "\n"
        }
        md += "\n" + modelsLine(report) + "\n"
        return md
    }

    private static func markdownItem(_ item: Report.Item, kind: SectionKind) -> String {
        let keyPrefix = item.isHigh ? "**Key:** " : ""
        let text = keyPrefix + mdBold(oneLine(item.text), item.keywords)
        var line: String
        switch kind {
        case .prose:
            return (item.isHigh ? "**Key:** " : "") + mdBold(item.text ?? "", item.keywords) + unsureSuffix(item)
                + "\n\n"
        case .actions:
            line = "- [ ] \(text)"
            if let o = item.owner, !o.isEmpty { line += " (owner: \(mdLine(o)))" }
            if let d = item.due, !d.isEmpty { line += " (due: \(mdLine(d)))" }
        case .qa:
            let answer = (item.answer ?? "").isEmpty ? "I don't know." : oneLine(item.answer)
            // The question is bold already, so keywords are bolded in the answer only.
            let shown = (item.answer ?? "").isEmpty ? answer : mdBold(answer, item.keywords)
            line = "- **\(item.isHigh ? "Key: " : "")\(mdLine(item.text))**\n  - AI: \(shown)"
        case .concepts:
            // The unsure note goes on the name's line, not after the last source.
            line = "- **\(item.isHigh ? "Key: " : "")\(mdLine(item.text))**" + unsureSuffix(item)
            if let q = item.quote, !q.isEmpty { line += "\n  - Said: \(mdLine(q))" }
            if let a = item.answer, !a.isEmpty { line += "\n  - AI understands: \(mdLine(a))" }
            if let d = item.detail, !d.isEmpty { line += "\n  - More: \(mdLine(d))" }
            // The checked URL, not the raw string, with the characters that could end
            // the link encoded; the title is escaped, so neither can form a new link.
            for link in item.sources ?? [] {
                guard let url = safeURL(link.url) else { continue }
                let href = url.absoluteString.replacingOccurrences(of: "(", with: "%28")
                    .replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: " ", with: "%20")
                    .replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
                line += "\n  - Source: [\(mdLine(link.title))](\(href))"
            }
            return line + "\n"
        case .insights:
            line = "- AI: \(text)"
        case .bullets, .goals:
            line = "- " + ((item.speaker ?? "").isEmpty ? "" : "**\(mdLine(item.speaker))**: ") + text
            if let q = item.quote, !q.isEmpty { line += " — “\(mdLine(q))”" }
            if let d = item.due, !d.isEmpty, kind == .goals { line += " (by: \(mdLine(d)))" }
        }
        return line + unsureSuffix(item) + "\n"
    }

    private static func mdBold(_ text: String, _ keywords: [String]?) -> String {
        wrap(text, keywords, open: "**", close: "**", piece: mdSafe)
    }

    /// Model and transcript text in the `.md` can't form a link or raw HTML: the
    /// characters that open them are backslash-escaped, which Markdown shows as is.
    static func mdSafe(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\[]<>`".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private static func mdLine(_ s: String?) -> String { mdSafe(oneLine(s)) }

    private static func unsureSuffix(_ item: Report.Item) -> String {
        guard item.isUnsure else { return "" }
        return " _(unsure: \(mdLine((item.reason ?? "").isEmpty ? "no reason given" : item.reason)))_"
    }

    private static func oneLine(_ s: String?) -> String {
        (s ?? "").components(separatedBy: .newlines).joined(separator: " ")
    }

    // MARK: - Terminal

    /// The summary for the terminal: plain text, sections in order, unsure items marked.
    /// Every piece of model text goes through `terminalSafe`; the only escape codes
    /// in the output are the yellow highlight ones added here, and only on a real terminal.
    static func terminalSummary(_ report: Report, ansi: Bool = isatty(STDOUT_FILENO) != 0) -> String {
        func t(_ s: String?) -> String { terminalSafe(oneLine(s)) }
        func hl(_ s: String?, _ keywords: [String]?) -> String {
            ansi
                ? wrap(oneLine(s), keywords, open: "\u{1B}[33m", close: "\u{1B}[39m", piece: terminalSafe)
                : t(s)
        }
        var out = "\(t(report.topic))  [\(t(report.scenarioTitle))\(report.reviewed ? "" : ", NOT REVIEWED")]\n"
        let key = keyItems(report)
        if !key.isEmpty {
            out += "\nAT A GLANCE\n"
            for (section, item) in key {
                var line = "  ▶ \(hl(item.text, item.keywords))"
                if let o = item.owner, !o.isEmpty { line += " (owner: \(t(o)))" }
                if let d = item.due, !d.isEmpty { line += " (due: \(t(d)))" }
                if item.isUnsure { line += " (unsure)" }
                out += line + "  — \(t(section.title))\n"
            }
        }
        for section in report.sections {
            out += "\n\(t(section.title))\n"
            if section.items.isEmpty {
                out += "  (none)\n"
                continue
            }
            for item in section.items {
                var line = item.isHigh ? "  ▶ KEY " : "  • "
                if let s = item.speaker, !s.isEmpty, section.kind == .bullets { line += "\(t(s)): " }
                if section.kind == .insights || item.isAI && section.kind != .qa { line += "[AI] " }
                line += hl(item.text, item.keywords)
                if section.kind == .qa {
                    line +=
                        "\n      [AI] "
                        + ((item.answer ?? "").isEmpty ? "I don't know." : hl(item.answer, item.keywords))
                }
                if let o = item.owner, !o.isEmpty { line += " (owner: \(t(o)))" }
                if let d = item.due, !d.isEmpty { line += " (due: \(t(d)))" }
                if item.isUnsure {
                    line += "\n      ? unsure: \((item.reason ?? "").isEmpty ? "no reason given" : t(item.reason))"
                }
                out += line + "\n"
            }
        }
        for n in report.notices { out += "\n⚠  \(terminalSafe(n))" }
        return out
    }

    /// Drops control characters, so model text can't move the cursor or recolour the terminal.
    static func terminalSafe(_ s: String) -> String {
        String(
            String.UnicodeScalarView(
                s.unicodeScalars.filter { $0 == "\n" || !(CharacterSet.controlCharacters.contains($0)) }))
    }
}

/// `<yyyyMMdd_HHmmss>_<short-topic>.html` (spec 04).
enum ReportFileName {
    static let maxSlug = 40
    static let maxSlugBytes = 160

    /// Keeps letters (Chinese included) and digits; anything else, path and shell
    /// characters and emoji included, becomes one `-`. At most 40 characters.
    static func slug(_ topic: String) -> String {
        var out = ""
        var lastDash = true
        for ch in topic.precomposedStringWithCanonicalMapping {
            // Emoji are symbols, not letters, so they become a dash too. A keycap such
            // as 1️⃣ is a digit plus marks, so the emoji selector and keycap mark rule it out.
            let isWordChar =
                ch.unicodeScalars.allSatisfy {
                    CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
                        || CharacterSet.nonBaseCharacters.contains($0)
                } && !ch.unicodeScalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 }
            if isWordChar {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
            // Bytes too: letters can carry many combining marks, and a name over
            // 255 bytes fails to write.
            if out.count >= maxSlug || out.utf8.count >= maxSlugBytes { break }
        }
        var s = String(out.prefix(maxSlug))
        while s.utf8.count > maxSlugBytes { s.removeLast() }
        while s.hasSuffix("-") { s.removeLast() }
        while s.hasPrefix("-") { s.removeFirst() }
        return s.isEmpty ? "report" : s
    }

    static func stamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: date)
    }

    static func name(topic: String, date: Date, timeZone: TimeZone = .current) -> String {
        "\(stamp(date, timeZone: timeZone))_\(slug(topic)).html"
    }

    /// A free path in `directory`: `_2`, `_3`, … before the extension if taken.
    static func freeURL(in directory: URL, topic: String, date: Date) -> URL {
        let base = name(topic: topic, date: date)
        var url = directory.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(String(base.dropLast(5)) + "_\(n).html")
            n += 1
        }
        return url
    }
}

/// Writes a report's files next to its transcript: `<base>.md`, `<base>.report.json`
/// and the dated HTML. Returns where each went.
enum ReportFiles {
    struct Written {
        let html: URL
        let markdown: URL
        let json: URL
    }

    /// `fileTopic` names the HTML; the pipeline passes the topic before tokens were
    /// restored, so a redacted value never ends up in a file name.
    static func write(_ report: Report, nextTo source: URL, fileTopic: String? = nil, date: Date = Date()) throws
        -> Written
    {
        let base = source.deletingPathExtension()
        var md = base.appendingPathExtension("md")
        // A transcript kept as `.md` must never be overwritten by its own report.
        if md.standardizedFileURL.resolvingSymlinksInPath() == source.standardizedFileURL.resolvingSymlinksInPath() {
            md = base.appendingPathExtension("report.md")
        }
        let json = base.appendingPathExtension("report.json")
        try (ReportRenderer.markdown(report)).write(to: md, atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: json, options: .atomic)
        let html = ReportFileName.freeURL(
            in: source.deletingLastPathComponent(), topic: fileTopic ?? report.topic, date: date)
        try ReportRenderer.html(report).write(to: html, atomically: true, encoding: .utf8)
        return Written(html: html, markdown: md, json: json)
    }
}

/// What the terminal shows after a report: the transcript with time and speaker
/// (unless it was just printed), then the summary, then where the files went.
enum ReportConsole {
    static func text(_ report: Report, showTranscript: Bool) -> String {
        var out = ""
        if showTranscript {
            out += "\n──── transcript ──────────────────────────\n"
            for e in report.transcript {
                let who = e.speaker.isEmpty ? "" : "\(e.speaker): "
                out += ReportRenderer.terminalSafe("[\(TranscriptParser.clock(e.start))] \(who)\(e.text)") + "\n"
            }
        }
        out += "\n──── summary ─────────────────────────────\n"
        out += ReportRenderer.terminalSummary(report)
        out += "\n──────────────────────────────────────────\n"
        return out
    }

    static func print(_ report: Report, showTranscript: Bool) {
        Swift.print(text(report, showTranscript: showTranscript), terminator: "")
    }

    static func printPaths(_ written: ReportFiles.Written) {
        Swift.print("   md:   \(written.markdown.path)")
        Swift.print("   json: \(written.json.path)")
        Swift.print("🌐  Report: \(written.html.path)")
    }
}
