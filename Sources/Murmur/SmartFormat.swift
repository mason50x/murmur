import Foundation

/// Adapts a transcript to the text around the caret.
enum SmartFormat {
    /// - Parameters:
    ///   - before/after: field text on either side of the caret, or nil when unknown
    ///     (then it's formatted as a standalone sentence).
    static func apply(_ raw: String, before: String?, after: String?) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }
        // Unknown surroundings: treat it as its own sentence.
        guard let before, let after else { return ensureTerminalPunctuation(capitalizeFirst(text)) }

        let b = before.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let a = after.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)

        // The only text in the field: a proper sentence.
        if b.isEmpty && a.isEmpty {
            return ensureTerminalPunctuation(capitalizeFirst(text))
        }

        let atSentenceStart = b.isEmpty || before.last?.isNewline == true || ".!?…".contains(b.last!)
        text = atSentenceStart ? capitalizeFirst(text) : lowercaseFirstIfCommon(text)

        // Inserted in front of existing text on the same line: a trailing period would break the sentence.
        if after.prefix(while: { !$0.isNewline }).contains(where: { !$0.isWhitespace }),
            text.hasSuffix("."), !text.hasSuffix("...")
        {
            text.removeLast()
        }

        if let last = before.last, !last.isWhitespace, !"([{\"'“‘/-".contains(last) {
            text = " " + text
        }
        if let first = after.first, first.isLetter || first.isNumber {
            text += " "
        }
        return text
    }

    /// Paragraphs and lists only go where the caret's line is otherwise empty.
    static func allowsLayout(before: String?, after: String?) -> Bool {
        let lineBefore = before.map { $0.reversed().prefix { !$0.isNewline } } ?? []
        let lineAfter = after.map { $0.prefix { !$0.isNewline } } ?? ""
        return lineBefore.allSatisfy(\.isWhitespace) && lineAfter.allSatisfy(\.isWhitespace)
    }

    private static func capitalizeFirst(_ s: String) -> String {
        guard let i = s.firstIndex(where: \.isLetter) else { return s }
        return s.replacingCharacters(in: i...i, with: s[i].uppercased())
    }

    /// Lowercases the first word only when it's a common function word, so names and "I" survive.
    private static func lowercaseFirstIfCommon(_ s: String) -> String {
        guard let start = s.firstIndex(where: \.isLetter) else { return s }
        let word = s[start...].prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        guard word.count > 1 || word == "A",
            word.first?.isUppercase == true,
            word.dropFirst().allSatisfy({ !$0.isUppercase }),
            commonWords.contains(word.lowercased())
        else { return s }
        return s.replacingCharacters(in: start...start, with: s[start].lowercased())
    }

    private static func ensureTerminalPunctuation(_ s: String) -> String {
        var core = s
        // A laid-out dictation ending in a list item is already finished.
        if let lastLine = s.split(separator: "\n").last,
            lastLine.hasPrefix("- ") || lastLine.range(of: #"^\d+\. "#, options: .regularExpression) != nil
        {
            return s
        }
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]"]
        while let last = core.last, closers.contains(last) { core.removeLast() }
        if let last = core.last, ".!?…:;".contains(last) { return s }
        return s + "."
    }

    private static let commonWords: Set<String> = [
        "a", "about", "after", "again", "all", "also", "an", "and", "any", "are", "as", "at", "be", "because",
        "been", "before", "but", "by", "can", "could", "did", "do", "does", "even", "every", "for", "from",
        "get", "go", "had", "has", "have", "he", "her", "here", "his", "how", "if", "in", "into", "is", "it",
        "it's", "its", "just", "let's", "like", "make", "maybe", "me", "more", "most", "much", "my", "no",
        "not", "now", "of", "okay", "ok", "on", "one", "only", "or", "our", "out", "please", "really", "she",
        "should", "so", "some", "still", "that", "that's", "the", "their", "them", "then", "there", "these",
        "they", "this", "those", "to", "too", "up", "us", "very", "was", "we", "well", "were", "what",
        "when", "where", "which", "while", "who", "why", "will", "with", "would", "yeah", "yes", "you",
        "your", "actually", "basically", "probably", "though", "although", "since", "until", "unless",
    ]
}
