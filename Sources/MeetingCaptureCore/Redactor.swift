import Foundation

// Regex redaction (D-08). Formatted values become tokens like `<EMAIL_1>` before
// any LLM call and are restored locally afterwards.
//
// Known limits: spoken names aren't caught (0 of 7 in the spike), a bare nine-digit
// SSN looks like any order number so it's left alone, and anything not in a
// recognizable format goes through as it is. This reduces what's sent; it doesn't
// make a transcript anonymous.
enum Redactor {

    struct Result: Equatable {
        let text: String
        /// Token to original value.
        let tokens: [String: String]
    }

    struct Restored: Equatable {
        let text: String
        /// Tokens in the answer that couldn't be restored. They stay visible and are never guessed.
        let flagged: [String]
    }

    static let tokenInstruction = """


        The text contains placeholder tokens such as <EMAIL_1> or <PHONE_2>. Each stands for a real value that was removed for privacy. Copy a token exactly when you need it, and never guess or invent the value behind it.
        """

    private struct Rule {
        let type: String
        let regex: NSRegularExpression
        /// Capture group holding the value, 0 for the whole match.
        var group = 0
        /// Returns the valid length of a match, or nil to reject it.
        var validate: ((String) -> Int?)?
    }

    /// `\b` treats Chinese characters as word characters, so a value right after
    /// Chinese text would be missed. These boundaries look at ASCII only.
    private static let edge = "(?<![A-Za-z0-9_])"
    private static let endEdge = "(?![A-Za-z0-9_])"

    private static func rx(_ pattern: String) -> NSRegularExpression {
        // A bad pattern here is a programming error, caught by every test run.
        try! NSRegularExpression(pattern: pattern)
    }

    /// Earlier rules win when two match the same span.
    private static let rules: [Rule] = [
        Rule(
            type: "API_KEY",
            regex: rx(
                edge
                    + #"(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{30,}|hf_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_-]{16,})"#
            )),
        // CJK has no spaces, so a sentence runs straight into an address. Limiting those
        // scripts to a name's length stops the token swallowing the words before it.
        Rule(
            type: "EMAIL",
            regex: rx(
                #"(?:[[\p{L}\p{N}._%+-]&&[^\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]]{1,64}|[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]{1,4})@[A-Za-z0-9.-]{1,255}\.[A-Za-z]{2,}"#
            )),
        Rule(
            type: "URL_TOKEN",
            regex: rx(
                #"(?i)[?&#](?:token|access_token|api_key|apikey|key|auth|sig|signature|password|secret)=([^&\s]{8,})"#),
            group: 1),
        Rule(
            type: "EMAIL_SPOKEN",
            regex: rx(
                #"(?i)(?<![A-Za-z0-9])[a-z0-9]+(?: (?:dot|underscore|dash|hyphen) [a-z0-9]+){0,8} at [a-z0-9]+(?: (?:dot|dash|hyphen) [a-z0-9]+){0,8} dot (?:com|org|net|cn|io|edu|de|co|ai|uk)(?![A-Za-z0-9])"#
            )),
        Rule(
            type: "IBAN",
            regex: rx(edge + #"[A-Za-z]{2}\d{2}(?: ?[A-Za-z0-9]{4}){2,7}(?: ?[A-Za-z0-9]{1,4})?"# + endEdge),
            validate: ibanLength),
        Rule(
            type: "CN_ID", regex: rx(#"(?<![0-9])\d{17}[\dXx](?![0-9A-Za-z])"#),
            validate: { cnIDValid($0) ? $0.utf16.count : nil }),
        Rule(
            type: "CARD",
            regex: rx(#"(?<![0-9])(?:\d{4}[ -]\d{6}[ -]\d{4,5}|(?:\d{4}[ -]){3}\d{1,7}|\d{13,19})(?![0-9])"#),
            validate: { luhnValid($0) ? $0.utf16.count : nil }),
        Rule(type: "CN_MOBILE", regex: rx(#"(?<![0-9])(?:\+?86[ -]?)?1[3-9]\d(?:[ -]?\d{4}){2}(?![0-9])"#)),
        Rule(
            type: "SSN", regex: rx(#"(?<![0-9-])\d{3}([- ])\d{2}\1\d{4}(?![0-9-])"#),
            validate: { ssnValid($0) ? $0.utf16.count : nil }),
        // Joined to another digit group, or among groups of four, it's part of a longer
        // number, such as a mistyped card. Any other number beside it says nothing.
        Rule(
            type: "PHONE",
            regex: rx(
                #"(?<![A-Za-z0-9_.])(?<![0-9][.-])(?<!(?:^| )\d{4} )(?:\+\d{1,3}(?:[ .-]?\d){7,12}|0\d{3,4}[ .-]\d{6}|(?:\+\d{1,3}[ .-]?|1[ .-])?(?:\(\d{2,4}\)[ .-]?|\d{2,4}[ .-])\d{3,4}[ .-]\d{3,4})(?![0-9-])(?![.-][0-9])(?! \d{4}(?![0-9]))"#
            ), validate: { phoneValid($0) ? $0.utf16.count : nil }),
    ]

    private static let priority: [String: Int] = Dictionary(
        uniqueKeysWithValues: rules.enumerated().map { ($1.type, $0) })

    static func redact(_ text: String) -> Result {
        let ns = text as NSString
        struct Span {
            let location: Int
            let length: Int
            let type: String
        }
        var spans: [Span] = []
        let whole = NSRange(location: 0, length: ns.length)
        for rule in rules {
            for match in rule.regex.matches(in: text, range: whole) {
                let range = match.range(at: rule.group)
                guard range.location != NSNotFound else { continue }
                var length = range.length
                if let validate = rule.validate {
                    guard let valid = validate(ns.substring(with: range)) else { continue }
                    length = valid
                }
                spans.append(Span(location: range.location, length: length, type: rule.type))
            }
        }
        spans.sort {
            if $0.location != $1.location { return $0.location < $1.location }
            if $0.length != $1.length { return $0.length > $1.length }
            return priority[$0.type, default: 0] < priority[$1.type, default: 0]
        }

        var output = ""
        var cursor = 0
        var tokens: [String: String] = [:]
        var tokenForValue: [String: String] = [:]
        var counters: [String: Int] = [:]
        for span in spans where span.location >= cursor {
            let value = ns.substring(with: NSRange(location: span.location, length: span.length))
            let key = span.type + "\u{0}" + value
            var token = tokenForValue[key]
            if token == nil {
                // Skip a number the text already uses literally, so restoring can't collide.
                var next = counters[span.type, default: 0] + 1
                while text.contains("<\(span.type)_\(next)>") { next += 1 }
                counters[span.type] = next
                token = "<\(span.type)_\(next)>"
                tokenForValue[key] = token
                tokens[token!] = value
            }
            output += ns.substring(with: NSRange(location: cursor, length: span.location - cursor))
            output += token!
            cursor = span.location + span.length
        }
        output += ns.substring(from: cursor)
        return Result(text: output, tokens: tokens)
    }

    private static let typeNames = rules.map(\.type).sorted { $0.count > $1.count }.joined(separator: "|")
    private static let exactToken = rx("<(?:\(typeNames))_\\d+>")
    private static let mangledToken = rx(
        "<[^<>\\n]{0,3}(?i:\(typeNames))[ _-]?\\d+[^<>\\n]{0,3}>|(?<![A-Za-z<])(?:\(typeNames))_\\d+")

    /// One pass over the answer, so a restored value can't be read as another token.
    static func restore(_ text: String, tokens: [String: String]) -> Restored {
        let ns = text as NSString
        var output = ""
        var cursor = 0
        var flagged: [String] = []
        for match in mangledOrExact(in: text) {
            let found = ns.substring(with: match)
            output += ns.substring(with: NSRange(location: cursor, length: match.location - cursor))
            if let value = tokens[found] {
                output += value
            } else {
                output += found
                if !flagged.contains(found) { flagged.append(found) }
            }
            cursor = match.location + match.length
        }
        output += ns.substring(from: cursor)
        return Restored(text: output, flagged: flagged)
    }

    private static func mangledOrExact(in text: String) -> [NSRange] {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let exact = exactToken.matches(in: text, range: whole).map(\.range)
        let mangled = mangledToken.matches(in: text, range: whole).map(\.range)
        var taken: [NSRange] = []
        for range in (exact + mangled).sorted(by: { $0.location < $1.location }) {
            if let last = taken.last, range.location < last.location + last.length { continue }
            taken.append(range)
        }
        return taken
    }

    // MARK: - Validation

    private static func digits(_ s: String) -> [Int] { s.compactMap { $0.isASCII ? $0.wholeNumberValue : nil } }

    static func luhnValid(_ s: String) -> Bool {
        let d = digits(s)
        guard (13...19).contains(d.count), Set(d).count > 1 else { return false }
        var sum = 0
        for (i, digit) in d.reversed().enumerated() {
            sum += i % 2 == 1 ? (digit * 2 > 9 ? digit * 2 - 9 : digit * 2) : digit
        }
        return sum % 10 == 0
    }

    static func ibanValid(_ s: String) -> Bool {
        let compact = s.filter { $0 != " " }.uppercased()
        guard (15...34).contains(compact.count) else { return false }
        let moved = String(compact.dropFirst(4) + compact.prefix(4))
        var remainder = 0
        for ch in moved {
            guard ch.isASCII,
                let value = ch.isNumber ? ch.wholeNumberValue : ch.isLetter ? Int(ch.asciiValue!) - 55 : nil
            else { return false }
            for digit in String(value) {
                remainder = (remainder * 10 + digit.wholeNumberValue!) % 97
            }
        }
        return remainder == 1
    }

    /// The match can run on into a following capitalized word. Drops trailing
    /// groups until the checksum holds, and returns that length.
    private static func ibanLength(_ s: String) -> Int? {
        var parts = s.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        while parts.count >= 2 {
            let candidate = parts.joined(separator: " ")
            if ibanValid(candidate) { return candidate.utf16.count }
            parts.removeLast()
        }
        return ibanValid(s) ? s.utf16.count : nil
    }

    static func cnIDValid(_ s: String) -> Bool {
        let chars = Array(s.uppercased())
        guard chars.count == 18 else { return false }
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        var sum = 0
        for i in 0..<17 {
            guard let d = chars[i].wholeNumberValue else { return false }
            sum += d * weights[i]
        }
        return Array("10X98765432")[sum % 11] == chars[17]
    }

    static func ssnValid(_ s: String) -> Bool {
        let d = digits(s)
        guard d.count == 9 else { return false }
        let area = d[0] * 100 + d[1] * 10 + d[2]
        let group = d[3] * 10 + d[4]
        let serial = d[5] * 1000 + d[6] * 100 + d[7] * 10 + d[8]
        return area != 0 && area != 666 && area < 900 && group != 0 && serial != 0
    }

    /// Without a `+`, ten digits is the least that reads as a phone number rather
    /// than a code like `100-200-300`.
    private static func phoneValid(_ s: String) -> Bool {
        let count = digits(s).count
        return s.hasPrefix("+") ? (8...15).contains(count) : (10...15).contains(count)
    }
}
