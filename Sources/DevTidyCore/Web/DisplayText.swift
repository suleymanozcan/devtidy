import Foundation

/// Text that came from a file, a web page, the process table or a directory name and is about to be shown in the UI.
///
/// Such text is never trusted to be drawable: it may carry invisible characters (zero-width, bidirectional overrides, tag
/// characters), newlines, or one grapheme cluster that is hundreds of kilobytes long (a base character followed by 100 000
/// combining marks, a chain of zero-width joiners). Everything the UI renders from outside the process goes through here and
/// is then shown with `Text(verbatim:)` or as a plain `String`, never as a `LocalizedStringKey` or Markdown.
///
/// Two flavours:
/// - `clean` / `label`: a NAME (page title, manifest name, folder, process, container). Whitespace collapses to one space,
///   every invisible scalar is dropped, the result is trimmed and bounded.
/// - `literal`: TEXT WHOSE SPACING MATTERS (a path, a command line). Spacing is kept; an invisible scalar is replaced by
///   U+FFFD so that nobody reads a path that is not the one on disk.
///
/// Bounds are in SCALARS, not characters: one `Character` can hold any number of scalars, so a character count bounds
/// nothing. Runs of combining marks and chains of joiners are cut short on top of that.
public enum DisplayText {
    /// Most combining marks kept after one base scalar.
    public static let maxMarksPerBase = 4
    /// Most zero-width joiners / non-joiners kept in one joined sequence (a family emoji has three).
    public static let maxJoinersPerSequence = 3
    /// `clean(_, limit:)` never returns more than `limit * scalarsPerCharacter` scalars.
    public static let scalarsPerCharacter = 4

    // MARK: Names

    /// Whitespace runs (newlines and non-breaking spaces included) become one space. Dropped: control characters, every
    /// `.format` scalar (zero-width space, word joiner, byte-order mark, bidirectional controls, tag characters), line and
    /// paragraph separators and the blank fillers (Hangul filler, braille blank…). A zero-width joiner / non-joiner is kept
    /// only between two characters, at most `maxJoinersPerSequence` per sequence (emoji sequences, Persian words); combining
    /// marks only after a base character, at most `maxMarksPerBase` of them. The result is trimmed.
    ///
    /// Longer than `limit` characters, or than `limit * scalarsPerCharacter` scalars ⇒ cut, ending in `…` (so the result has at
    /// most `limit` characters). nil when nothing visible is left (empty, only spaces, only invisible characters, only marks).
    public static func clean(_ text: String, limit: Int) -> String? {
        guard limit > 0 else { return nil }
        let scalarCap = limit * scalarsPerCharacter
        var out: [Unicode.Scalar] = []
        var limiter = ClusterLimiter()
        var pendingSpace = false
        var hasVisible = false

        for scalar in text.unicodeScalars {
            if out.count > scalarCap { break }
            let properties = scalar.properties
            if properties.isWhitespace {
                if limiter.endsWithJoiner { out.removeLast() }
                limiter.reset()
                pendingSpace = !out.isEmpty
                continue
            }
            let category = properties.generalCategory
            if isInvisible(scalar, category: category, properties: properties) { continue }
            guard limiter.admit(scalar, category: category) else { continue }
            if pendingSpace, !isJoiner(scalar), !isMark(category) {
                out.append(" ")
                pendingSpace = false
            }
            out.append(scalar)
            if !hasVisible, isVisible(category) { hasVisible = true }
        }
        var truncated = false
        if out.count > scalarCap {
            out.removeLast(out.count - scalarCap)
            truncated = true
        }
        while let last = out.last, isJoiner(last) { out.removeLast() }
        guard hasVisible, !out.isEmpty else { return nil }

        let whole = String(String.UnicodeScalarView(out))
        if limit == 1 { return String(whole.prefix(1)) }
        if !truncated, whole.count <= limit { return whole }
        return cut(whole, characters: limit - 1, scalars: scalarCap - 1) + "…"
    }

    /// `clean`, for a place that must show SOMETHING: when nothing visible is left, a short code-point preview of the raw
    /// text (`‹U+200B›`) instead of nil, and "" for an empty string.
    public static func label(_ raw: String, limit: Int = 120) -> String {
        if let cleaned = clean(raw, limit: limit) { return cleaned }
        guard !raw.isEmpty else { return "" }
        let first = raw.unicodeScalars.prefix(4).map { String(format: "U+%04X", $0.value) }
        let more = raw.unicodeScalars.dropFirst(4).isEmpty ? "" : " …"
        return "‹" + first.joined(separator: " ") + more + "›"
    }

    // MARK: Paths and command lines

    /// Spacing is kept. Control, format, line / paragraph separator and bidirectional scalars become U+FFFD (a path or an
    /// argument must not hide characters), runs of combining marks and joiner chains are bounded, and at most `scalarLimit`
    /// scalars are kept: longer ⇒ cut, ending in `…`. `keepingLineBreaks`: a plain line feed stays one (multi-line messages,
    /// such as the error banner's); every other control character is still replaced.
    public static func literal(_ text: String, scalarLimit: Int, keepingLineBreaks: Bool = false) -> String {
        guard scalarLimit > 0 else { return "" }
        var out = String.UnicodeScalarView()
        var count = 0
        var limiter = ClusterLimiter()
        var truncated = false
        for scalar in text.unicodeScalars {
            let properties = scalar.properties
            let category = properties.generalCategory
            var emitted = scalar
            if properties.isWhitespace && category == .spaceSeparator {
                limiter.reset()
            } else if keepingLineBreaks && scalar.value == 0x0A {
                limiter.reset()
            } else if isInvisible(scalar, category: category, properties: properties) || properties.isWhitespace {
                emitted = replacement
                limiter.reset()
            } else if !limiter.admit(scalar, category: category) {
                continue
            }
            if count == scalarLimit { truncated = true; break }
            out.append(emitted)
            count += 1
        }
        guard truncated else { return String(out) }
        out.removeLast()
        while let last = out.last, isJoiner(last) { out.removeLast() }
        out.append("…")
        return String(out)
    }

    /// Shown in place of an invisible scalar by `literal`.
    public static let replacement: Unicode.Scalar = "\u{FFFD}"

    // MARK: Scalar classes

    private static func isJoiner(_ scalar: Unicode.Scalar) -> Bool { scalar.value == 0x200D || scalar.value == 0x200C }

    private static func isMark(_ category: Unicode.GeneralCategory) -> Bool {
        category == .nonspacingMark || category == .spacingMark || category == .enclosingMark
    }

    /// Letters, numbers, punctuation and symbols: something a reader can see.
    private static func isVisible(_ category: Unicode.GeneralCategory) -> Bool {
        switch category {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: true
        default: false
        }
    }

    /// Scalars that draw nothing (or change how the text around them reads) and are never part of a name. A joiner is NOT in
    /// this class: it is handled by `ClusterLimiter`.
    private static func isInvisible(_ scalar: Unicode.Scalar, category: Unicode.GeneralCategory,
                                    properties: Unicode.Scalar.Properties) -> Bool {
        if isJoiner(scalar) { return false }
        switch category {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: break
        }
        if properties.isBidiControl { return true }
        switch scalar.value {
        // combining grapheme joiner, Hangul fillers, Khmer inherent vowels, braille blank, halfwidth Hangul filler
        case 0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x2800, 0x3164, 0xFFA0: return true
        default: return false
        }
    }

    /// The first `characters` characters of `text` that also fit in `scalars` scalars, without a trailing space or joiner.
    private static func cut(_ text: String, characters: Int, scalars: Int) -> String {
        var kept = String.UnicodeScalarView()
        var characterCount = 0
        var scalarCount = 0
        for character in text {
            let width = character.unicodeScalars.count
            if characterCount + 1 > characters || scalarCount + width > scalars { break }
            kept.append(contentsOf: character.unicodeScalars)
            characterCount += 1
            scalarCount += width
        }
        while let last = kept.last, isJoiner(last) || last == " " { kept.removeLast() }
        return String(kept)
    }

    /// Decides, scalar by scalar, which combining marks and joiners survive: a mark needs a base before it and at most
    /// `maxMarksPerBase` follow it; a joiner sits between two characters and at most `maxJoinersPerSequence` chain.
    private struct ClusterLimiter {
        private var hasBase = false
        private var marks = 0
        private var joiners = 0
        private(set) var endsWithJoiner = false

        /// false = drop `scalar`.
        mutating func admit(_ scalar: Unicode.Scalar, category: Unicode.GeneralCategory) -> Bool {
            if DisplayText.isJoiner(scalar) {
                guard hasBase, joiners < DisplayText.maxJoinersPerSequence else { return false }
                joiners += 1
                hasBase = false
                endsWithJoiner = true
                return true
            }
            if DisplayText.isMark(category) {
                guard hasBase, marks < DisplayText.maxMarksPerBase else { return false }
                marks += 1
                return true
            }
            if !endsWithJoiner { joiners = 0 }
            endsWithJoiner = false
            marks = 0
            hasBase = true
            return true
        }

        /// A space (or a replaced scalar) ends the sequence.
        mutating func reset() {
            hasBase = false
            marks = 0
            joiners = 0
            endsWithJoiner = false
        }
    }
}
