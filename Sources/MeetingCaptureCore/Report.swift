import Foundation

// The one model every report is rendered from (spec 04). Models fill JSON that
// becomes this; they never write HTML. Every field a model writes is optional on
// decode, so a reply missing a field still loads and the renderer shows what's there.

struct Report: Codable, Equatable {
    var schemaVersion = 1
    var topic: String
    var scenario: String
    /// The scenario's display title, such as "Company meeting".
    var scenarioTitle: String
    /// ISO 8601, local time with offset.
    var createdAt: String
    /// From the last transcript line's start, so it can be a little short.
    var durationSeconds: Double
    /// BCP 47-ish code from the classifier, such as `en` or `zh`. Empty if unknown.
    var language: String
    var models: Models
    var reviewed: Bool
    /// Things the reader should know: low-confidence scenario, a skipped step, a CLI switch.
    var notices: [String]
    var sections: [Section]
    /// What the frontier review changed, and why. Empty when it changed nothing or didn't run.
    var reviewChanges: [Change]
    var transcript: [TranscriptEntry]

    struct Models: Codable, Equatable {
        var cheap = ""
        var normal = ""
        var frontier = ""
    }

    struct Change: Codable, Equatable {
        var what: String
        var why: String
    }

    struct Section: Codable, Equatable {
        var id: String
        var title: String
        var kind: SectionKind
        /// A fixed line from the template, such as "AI, not clinical advice".
        var note: String?
        var items: [Item]
    }

    struct Item: Codable, Equatable {
        var text: String?
        var speaker: String?
        var owner: String?
        var due: String?
        var answer: String?
        /// What was said, in the speaker's words (concepts, goals).
        var quote: String?
        /// A longer explanation (concepts).
        var detail: String?
        var confidence: String?
        var reason: String?
        /// `ai` for the model's own view, `transcript` for what was said.
        var source: String?
        var sources: [Link]?

        var isUnsure: Bool { confidence?.lowercased() == "unsure" }
        var isAI: Bool { source?.lowercased() == "ai" }
    }

    struct Link: Codable, Equatable {
        var title: String
        var url: String
    }
}

enum SectionKind: String, Codable, CaseIterable {
    case prose, bullets, actions, qa, goals, concepts, insights
}

struct TranscriptEntry: Codable, Equatable {
    var start: Double
    var end: Double
    var speaker: String
    var text: String
    /// A correction the review proposed. The original `text` is always kept.
    var suggestion: String?
}

/// Reads the `[hh:mm:ss] Speaker: text` lines `SpeakerLabels.format` writes.
enum TranscriptParser {

    private static let line = try! NSRegularExpression(
        pattern: #"^\[(\d{1,3}):(\d{2}):(\d{2})\] ([^:\n]{1,80}?): ?(.*)$"#)

    /// A line that doesn't match joins the one before it, so a hand-edited file
    /// still loads. A file with no timestamps at all becomes one line per text line
    /// at time 0, with no speaker.
    static func parse(_ text: String) -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let ns = trimmed as NSString
            if let m = line.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
                let h = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let mi = Double(ns.substring(with: m.range(at: 2))) ?? 0
                let s = Double(ns.substring(with: m.range(at: 3))) ?? 0
                entries.append(
                    TranscriptEntry(
                        start: h * 3600 + mi * 60 + s, end: 0,
                        speaker: ns.substring(with: m.range(at: 4)),
                        text: ns.substring(with: m.range(at: 5))))
            } else if hasTimestamps(entries) {
                entries[entries.count - 1].text += " " + trimmed
            } else {
                entries.append(TranscriptEntry(start: 0, end: 0, speaker: "", text: trimmed))
            }
        }
        for i in entries.indices {
            entries[i].end = i + 1 < entries.count ? max(entries[i].start, entries[i + 1].start) : entries[i].start
        }
        return entries
    }

    private static func hasTimestamps(_ entries: [TranscriptEntry]) -> Bool {
        entries.contains { !$0.speaker.isEmpty }
    }

    static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
}
