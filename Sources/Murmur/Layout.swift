import FluidAudio
import Foundation
import NaturalLanguage

/// Lays a dictation out as paragraphs and lists, like Wispr Flow, but without a language model:
/// instant, offline, and it never rewrites what you said. Only line breaks, list markers, and the
/// spoken ordinals they replace ("first,", "number two,") change.
/// - Lists: spoken ordinals ("first… second… and third…") become a numbered list; an intro that
///   announces a count ("three things: a, b, and c") becomes bullets.
/// - Paragraphs: break where you paused noticeably longer than between sentences, or used a
///   transition ("separately", "by the way"); long stretches split at their longest pause.
///   Saying "new paragraph" or "new line" forces a break instead.
/// - Messages: a "Hey Sam," greeting and a "Thanks, Mason" sign-off get lines of their own.
enum Layout {
    /// Debug: receives the paragraph scoring (`Murmur --transcribe`).
    nonisolated(unsafe) static var trace: ((String) -> Void)?

    /// Runs `format` off the main thread.
    static func formatInBackground(_ t: Transcriber.Transcript) async -> String? {
        await Task.detached(priority: .userInitiated) { format(t.text, words: t.words) }.value
    }

    /// `text` laid out, or nil when it reads best as a single run of prose.
    static func format(_ text: String, words: [WordTiming]) -> String? {
        let sentences = sentences(text, words: words)
        let pauses = sentences.dropFirst().map(\.pause).filter { $0 > 0 }.sorted()
        let typicalPause = pauses.count >= 2 ? pauses[pauses.count / 2] : 0

        let (spoken, commanded) = applyCommands(sentences)
        var pieces = spoken
        guard !pieces.isEmpty else { return nil }

        var head: String?
        var tail: String?
        if pieces.count >= 3, let g = greeting(pieces[0].text) {
            head = g.line
            pieces[0].text = g.rest
        }
        if pieces.count >= 2, let s = signOff(pieces[pieces.count - 1].text, greeting: head) {
            tail = s.line
            if s.rest.isEmpty { pieces.removeLast() } else { pieces[pieces.count - 1].text = s.rest }
        }
        pieces = pieces.flatMap(splitOrdinals)

        var out = head ?? ""
        for laid in structure(pieces) {
            let blocks: [Laid]
            if case .prose(let run) = laid.block, !commanded {
                blocks = paragraphs(run, typicalPause: typicalPause).enumerated().map {
                    Laid(block: .prose($1), join: $0 == 0 ? laid.join : "\n\n")
                }
            } else {
                blocks = [laid]
            }
            for b in blocks {
                if !out.isEmpty { out += out == head ? "\n\n" : b.join }
                out += render(b.block)
            }
        }
        if let tail { out += "\n\n" + tail }
        return out.contains("\n") ? out : nil
    }

    // MARK: - Pieces

    private enum Break { case paragraph, line }

    /// A sentence, or a clause split off one.
    private struct Piece {
        var text: String
        /// Silence before it, in seconds (0 when unknown).
        var pause = 0.0
        /// "new paragraph" / "new line" was said right before it.
        var forced: Break?
        /// The spoken ordinal it opens with ("first," → 1, "finally," → `last`).
        var ordinal: Int?
        /// The text after that ordinal.
        var body = ""
        /// Split off a longer sentence: as a list item it drops its end punctuation.
        var fragment = false
        /// The clause leading into an inline list ("there are three things we need to do,").
        var intro = false
    }

    private static let last = Int.max

    private static func sentences(_ text: String, words: [WordTiming]) -> [Piece] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        // Word timings line up with the transcript one-to-one; if not, go without pauses.
        let aligned = words.count == text.split(whereSeparator: \.isWhitespace).count
        var pieces: [Piece] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return true }
            var pause = 0.0
            if aligned {
                let w = text[..<range.lowerBound].split(whereSeparator: \.isWhitespace).count
                if w > 0, w < words.count { pause = max(0, words[w].startTime - words[w - 1].endTime) }
            }
            pieces.append(Piece(text: s, pause: pause))
            return true
        }
        return pieces
    }

    /// "new paragraph" / "new line", said as their own phrase, become breaks.
    private static let command = regex(#"(?:^|[,;:.]\s+)new (paragraph|line)(?:[.!?,;:]+|$)\s*"#)

    private static func applyCommands(_ pieces: [Piece]) -> ([Piece], commanded: Bool) {
        var out: [Piece] = []
        var pending: Break?
        var commanded = false
        for p in pieces {
            var rest = p.text
            var pause = p.pause
            while let m = command.firstMatch(in: rest), let r = Range(m.range, in: rest),
                let kind = Range(m.range(at: 1), in: rest)
            {
                commanded = true
                let before = trimEnd(String(rest[..<r.lowerBound]), ",;: ")
                if !before.isEmpty {
                    out.append(Piece(text: terminated(before), pause: pause, forced: pending))
                    pending = nil
                }
                pending = rest[kind].lowercased() == "line" ? .line : .paragraph
                rest = capitalized(String(rest[r.upperBound...]))
                pause = 0
            }
            if !rest.isEmpty {
                out.append(Piece(text: rest, pause: pause, forced: pending))
                pending = nil
            }
        }
        return (out, commanded)
    }

    // MARK: - Lists

    private static let marker = regex(
        #"(?:^|(?<=[,;:])\s+)(?:(?:and then|and|then|so)\s+)?"#
            + #"(firstly|first|secondly|second|thirdly|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|"#
            + #"number (?:one|two|three|four|five|six|seven|eight|nine|ten)|"#
            + #"one|two|three|four|five|six|seven|eight|nine|ten|finally|lastly)\s*[,:]\s*"#)

    private static let numbers = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10,
    ]
    private static let ordinals = [
        "first": 1, "firstly": 1, "second": 2, "secondly": 2, "third": 3, "thirdly": 3, "fourth": 4,
        "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "finally": last,
        "lastly": last,
    ]

    private static func ordinalValue(_ word: Substring) -> Int? {
        let w = word.lowercased().replacingOccurrences(of: "number ", with: "")
        return ordinals[w] ?? numbers[w]
    }

    /// Finds the spoken ordinal a sentence opens with, and splits "first, a, second, b, and third, c"
    /// into one piece per item.
    private static func splitOrdinals(_ p: Piece) -> [Piece] {
        let s = p.text
        let found = marker.matches(in: s).compactMap { m -> (range: Range<String.Index>, value: Int)? in
            guard let r = Range(m.range, in: s), let w = Range(m.range(at: 1), in: s),
                let v = ordinalValue(s[w])
            else { return nil }
            return (r, v)
        }
        let values = found.map(\.value)
        let sequential = values.count >= 2
            && zip(values, values.dropFirst()).enumerated().allSatisfy { k, pair in
                pair.1 == pair.0 + 1 || (pair.1 == last && k == values.count - 2)
            }
        if sequential {
            var out: [Piece] = []
            let lead = String(s[..<found[0].range.lowerBound])
            if lead.contains(where: \.isLetter) {
                out.append(Piece(text: lead, pause: p.pause, forced: p.forced, intro: true))
            }
            for (k, f) in found.enumerated() {
                let end = k + 1 < found.count ? found[k + 1].range.lowerBound : s.endIndex
                let body = trimEnd(String(s[f.range.upperBound..<end]), ",; ")
                guard body.contains(where: \.isLetter) else { return [p] }
                let first = out.isEmpty
                out.append(Piece(
                    text: String(s[f.range.lowerBound..<end]).trimmingCharacters(in: .whitespaces),
                    pause: first ? p.pause : 0,
                    forced: first ? p.forced : nil, ordinal: f.value, body: body, fragment: true))
            }
            return out
        }
        var q = p
        if let f = found.first, f.range.lowerBound == s.startIndex {
            q.ordinal = f.value
            q.body = String(s[f.range.upperBound...])
        }
        return [q]
    }

    /// Items "first, …" through "and third, …" (or "finally, …"); sentences between two items
    /// belong to the earlier one.
    private static func ordinalRun(_ pieces: [Piece], from start: Int) -> (items: [String], end: Int)? {
        guard pieces[start].ordinal == 1 else { return nil }
        var items: [[Piece]] = [[pieces[start]]]
        var pending: [Piece] = []
        var j = start + 1
        while j < pieces.count, pieces[j].forced == nil, pending.count <= 2 {
            let p = pieces[j]
            if let v = p.ordinal {
                guard v == items.count + 1 || v == last else { break }
                items[items.count - 1] += pending
                pending = []
                items.append([p])
                j += 1
                if v == last { break }
            } else {
                pending.append(p)
                j += 1
            }
        }
        guard items.count >= 2 else { return nil }
        let texts = items.map { group in
            var s = ([group[0].body] + group.dropFirst().map(\.text)).joined(separator: " ")
            if group[group.count - 1].fragment { s = trimEnd(s, ".") }
            return s
        }
        return (texts, j - pending.count)
    }

    private static let nouns =
        "things|items|points|steps|tasks|questions|ideas|options|reasons|changes|updates|issues|priorities|"
        + "notes|topics|goals|bugs|features|takeaways|thoughts|requirements|todos|to-dos|problems|concerns|"
        + "suggestions|parts|pieces|places|people|ways|areas|names"
    private static let count = "two|three|four|five|six|seven|eight|nine|ten|[2-9]"

    /// "We need three things: eggs, milk, and bread." / "Here's the plan: a, b, c, and d."
    private static let inline = regex(
        #"^(?<lead>[^,:;]*?\b(?:(?:\#(count)|a few|a couple of|several|some)\s+(?:\w+\s+){0,2}?(?:\#(nouns))\b[^,:;]*|[^:]+(?=:)))[,:;]\s*(?<rest>.+)$"#
    )
    /// "There are three things we need to do." followed by one sentence per item.
    private static let announce = regex(
        #"\b(?:here are|here's|there are|there's|i have|i've got|we have|we've got|need|want|let's|should|would like|wanted to)\b.*\b(?<n>\#(count))\s+(?:\w+\s+){0,2}?(?:\#(nouns))\b[^?!]*[.:]$"#
    )

    private static func inlineList(_ text: String) -> (lead: String, items: [String])? {
        guard let m = inline.firstMatch(in: text), let lr = Range(m.range(withName: "lead"), in: text),
            let rr = Range(m.range(withName: "rest"), in: text)
        else { return nil }
        let lead = String(text[lr])
        var rest = String(text[rr]).trimmingCharacters(in: .whitespaces)
        guard !rest.hasSuffix("?") else { return nil }
        rest = trimEnd(rest, ".!")
        let expected = countIn(lead)

        var items = rest.components(separatedBy: itemSeparator).map {
            $0.replacingOccurrences(of: #"^(?:and|or)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        // "a, b and c": the last comma is often missing.
        if let n = expected, items.count == n - 1, let tail = items.last,
            let r = tail.range(of: " and ", options: .backwards) ?? tail.range(of: " or ", options: .backwards)
        {
            items[items.count - 1] = String(tail[..<r.lowerBound])
            items.append(String(tail[r.upperBound...]))
        }
        items = items.map { $0.trimmingCharacters(in: .whitespaces) }
        let sizes = items.map(wordCount)
        guard sizes.allSatisfy({ (1...10).contains($0) }),
            expected.map({ items.count == $0 }) ?? (items.count >= 3)
        else { return nil }
        return (lead, items)
    }

    private static let itemSeparator = regex(#"\s*[,;]\s*"#)
    private static let countWord = regex(#"\b(\#(count))\b"#)
    private static let listWord = regex(#"\b(?:\#(nouns)|following)\b"#)

    private static func countIn(_ s: String) -> Int? {
        guard let m = countWord.firstMatch(in: s), let r = Range(m.range(at: 1), in: s) else {
            return nil
        }
        return numbers[s[r].lowercased()] ?? Int(s[r])
    }

    // MARK: - Blocks

    private enum Block {
        case prose([Piece])
        case list(ordered: Bool, items: [String])
    }

    /// A block and the separator that goes before it.
    private struct Laid {
        var block: Block
        var join: String
    }

    private static func structure(_ pieces: [Piece]) -> [Laid] {
        var out: [Laid] = []
        var prose: [Piece] = []
        var join = "\n\n"

        func flush() {
            guard !prose.isEmpty else { return }
            out.append(Laid(block: .prose(prose), join: join))
            prose = []
            join = "\n\n"
        }
        /// A clause that announces the list gets a colon and the list follows on the next line.
        func emitList(ordered: Bool, _ items: [String]) {
            var listJoin = join
            if let last = prose.last {
                listJoin = "\n\n"
                if last.intro || announces(last.text) {
                    prose[prose.count - 1].text = trimEnd(last.text, ".,;: ") + ":"
                    listJoin = "\n"
                }
            }
            flush()
            out.append(Laid(block: .list(ordered: ordered, items: items), join: listJoin))
            join = "\n\n"
        }

        var i = 0
        while i < pieces.count {
            let p = pieces[i]
            if let f = p.forced {
                flush()
                join = f == .line ? "\n" : "\n\n"
            }
            if let run = ordinalRun(pieces, from: i) {
                emitList(ordered: true, run.items)
                i = run.end
            } else if p.ordinal == nil, let list = inlineList(p.text) {
                prose.append(Piece(text: list.lead, pause: p.pause, intro: true))
                emitList(ordered: false, list.items)
                i += 1
            } else if let n = announcedCount(p.text), let items = sentenceItems(pieces, after: i, count: n) {
                prose.append(p)
                emitList(ordered: false, items)
                i += 1 + n
            } else {
                prose.append(p)
                i += 1
            }
        }
        flush()
        return out
    }

    private static func announces(_ s: String) -> Bool {
        s.hasSuffix(":") || listWord.firstMatch(in: s) != nil
    }

    private static func announcedCount(_ s: String) -> Int? {
        guard let m = announce.firstMatch(in: s), let r = Range(m.range(withName: "n"), in: s) else { return nil }
        return numbers[s[r].lowercased()] ?? Int(s[r])
    }

    /// The next `count` sentences as list items, if they're short and nothing interrupts them.
    private static func sentenceItems(_ pieces: [Piece], after i: Int, count: Int) -> [String]? {
        guard i + count < pieces.count else { return nil }
        let items = pieces[(i + 1)...(i + count)]
        guard items.allSatisfy({ $0.forced == nil && $0.ordinal == nil && wordCount($0.text) <= 25 }) else {
            return nil
        }
        return items.map(\.text)
    }

    private static func render(_ block: Block) -> String {
        switch block {
        case .prose(let pieces):
            return pieces.map(\.text).joined(separator: " ")
        case .list(let ordered, var items):
            items = items.map(capitalized)
            // Mixed full sentences and fragments read better without periods throughout.
            if !items.allSatisfy({ $0.last.map { ".!?".contains($0) } ?? false }) {
                items = items.map { $0.hasSuffix("...") ? $0 : trimEnd($0, ".") }
            }
            return items.enumerated().map { ordered ? "\($0 + 1). \($1)" : "- \($1)" }.joined(separator: "\n")
        }
    }

    // MARK: - Paragraphs

    /// Splits prose where a long pause, a transition, or a closing line points to a new
    /// paragraph; very long paragraphs also split at their strongest seam.
    private static func paragraphs(_ run: [Piece], typicalPause: Double) -> [[Piece]] {
        let n = run.count
        let words = run.map { wordCount($0.text) }
        guard n >= 3, words.reduce(0, +) >= 40 else { return [run] }

        var score = [Double](repeating: 0, count: n)
        for i in 1..<n {
            let pause =
                typicalPause > 0 ? min(max((run[i].pause - max(typicalPause * 1.6, 0.45)) / 0.8, 0), 1.2) : 0
            let closer = i == n - 1 && isCloser(run[i].text) ? 0.8 : 0
            score[i] = pause + transition(run[i].text) + closer
            trace?(
                String(
                    format: "%5.2f  pause %.2fs→%.2f transition %.1f closer %.1f | %@", score[i], run[i].pause, pause,
                    transition(run[i].text), closer, String(run[i].text.prefix(50))))
        }

        func fits(_ a: Int, _ b: Int) -> Bool {
            b - a >= 2 || words[a] >= 14 || transition(run[a].text) >= 1 || (b == n && isCloser(run[a].text))
        }
        func valid(_ breaks: [Int]) -> Bool {
            let edges = [0] + breaks.sorted() + [n]
            return zip(edges, edges.dropFirst()).allSatisfy { fits($0, $1) }
        }
        var breaks: [Int] = []
        for i in (1..<n).sorted(by: { score[$0] > score[$1] }) where score[i] >= 1 && valid(breaks + [i]) {
            breaks.append(i)
        }
        var split = true
        while split {
            split = false
            let edges = [0] + breaks.sorted() + [n]
            for (a, b) in zip(edges, edges.dropFirst()) where b - a >= 4 && words[a..<b].reduce(0, +) > 90 {
                // Strongest seam; among equals, the longest pause.
                let seams = (a + 1..<b).filter { valid(breaks + [$0]) }
                if let i = seams.max(by: { (score[$0], run[$0].pause) < (score[$1], run[$1].pause) }) {
                    breaks.append(i)
                    split = true
                    break
                }
            }
        }
        let edges = [0] + breaks.sorted() + [n]
        return zip(edges, edges.dropFirst()).map { Array(run[$0..<$1]) }
    }

    private static let strongTransition = regex(
        #"^(?:separately|anyway|anyways|on (?:another|a different|an unrelated|a separate|a side) note|by the way|"#
            + #"oh,? and|oh,? also|one more thing|another thing|unrelated|switching gears|changing (?:topics|gears|subjects)|"#
            + #"moving on|in other news|speaking of|as for|regarding|p\.?s\.?|last thing|one last thing|other than that)\b"#)
    private static let weakTransition = regex(
        #"^(?:also|additionally|besides that|next|now|okay|ok|so|alright|all right|finally|lastly|otherwise|"#
            + #"on top of that|beyond that|in addition|meanwhile|however|that said),"#)
    private static let closer = regex(
        #"^(?:let me know|thanks|thank you|talk soon|looking forward|hope (?:that|this) helps|cheers|appreciate it|"#
            + #"have a (?:good|great|nice)|see you|happy to (?:chat|help|discuss)|feel free|let's discuss)\b"#)

    private static func transition(_ s: String) -> Double {
        if strongTransition.firstMatch(in: s) != nil { return 1 }
        return weakTransition.firstMatch(in: s) != nil ? 0.4 : 0
    }

    private static func isCloser(_ s: String) -> Bool { closer.firstMatch(in: s) != nil }

    // MARK: - Greeting & sign-off

    private static let name = #"(?-i:[A-Z])[\w'’.-]*"#
    private static let greetingLine = regex(
        #"^((?:hi|hey|hello|dear|good (?:morning|afternoon|evening)|morning)"#
            + #"(?:\s+(?:\#(name)|team|all|everyone|everybody|guys|folks|there|y'all|both)){1,3})\s*,\s+(\S.*)$"#)
    private static let signOffLine = regex(
        #"(?:^|,\s+)(thanks|thank you|thanks so much|thanks again|best|cheers|regards|best regards|kind regards|"#
            + #"warm regards|talk soon|sincerely|all the best|take care),\s+(\#(name)(?:\s+\#(name))?)[.!]?$"#)

    private static func greeting(_ s: String) -> (line: String, rest: String)? {
        guard let m = greetingLine.firstMatch(in: s), let g = Range(m.range(at: 1), in: s),
            let r = Range(m.range(at: 2), in: s)
        else { return nil }
        return (String(s[g]) + ",", capitalized(String(s[r])))
    }

    /// "Thanks, Mason." → "Thanks,\nMason", also off the end of a run-on last sentence, unless
    /// it's thanking the person the greeting named. Returns the line and what's left before it.
    private static func signOff(_ s: String, greeting: String?) -> (line: String, rest: String)? {
        guard let m = signOffLine.firstMatch(in: s), let r = Range(m.range, in: s),
            let w = Range(m.range(at: 1), in: s), let n = Range(m.range(at: 2), in: s)
        else { return nil }
        if let greeting, greeting.contains(s[n]) { return nil }
        let rest = trimEnd(String(s[..<r.lowerBound]), ",; ")
        return ("\(capitalized(String(s[w]))),\n\(s[n])", rest.isEmpty ? "" : terminated(rest))
    }

    // MARK: - Text helpers

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func wordCount(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }

    private static func trimEnd(_ s: String, _ chars: String) -> String {
        var s = s
        while let c = s.last, chars.contains(c) || c.isWhitespace { s.removeLast() }
        return s
    }

    private static func terminated(_ s: String) -> String {
        s.last.map { ".!?…:".contains($0) } == true ? s : s + "."
    }

    private static func capitalized(_ s: String) -> String {
        guard let i = s.firstIndex(where: \.isLetter), s[i].isLowercase else { return s }
        return s.replacingCharacters(in: i...i, with: s[i].uppercased())
    }
}

private extension NSRegularExpression {
    func matches(in s: String) -> [NSTextCheckingResult] {
        matches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    func firstMatch(in s: String) -> NSTextCheckingResult? {
        firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }
}

private extension String {
    func components(separatedBy re: NSRegularExpression) -> [String] {
        var parts: [String] = []
        var start = startIndex
        for m in re.matches(in: self) {
            guard let r = Range(m.range, in: self) else { continue }
            parts.append(String(self[start..<r.lowerBound]))
            start = r.upperBound
        }
        parts.append(String(self[start...]))
        return parts
    }
}
