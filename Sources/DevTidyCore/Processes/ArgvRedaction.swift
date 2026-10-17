import Foundation

/// The one place where a process's argv is made fit for a screen (security I-4 / F3-3): every surface that prints a command
/// line (the kill card, the server row, "Ayrıntılar → Komut satırı") goes through here, so a secret that is hidden on one of
/// them is hidden on all of them.
///
/// What is hidden (replaced by `mask`):
/// - the value of a secret-named flag, as `--token=x` or as `--token x`; secret names are matched on whole words
///   (`--pass`, `--auth`, `--key`, `--cookie`, `--dsn`, `--api-key`, `--dbPass`) or, for the long words, anywhere
///   (`--access-token`, `--client-secret`, `--password`), so `--bypass`, `--author` and `--passWithNoTests` stay readable;
/// - `NAME=value` and `NAME:value` (`--var API_TOKEN:x`) whose `NAME` has no leading dash and is secret-named, whole word or
///   glued (`API_KEY`, `DB_PASS`, `APIKEY`; not `AUTHOR`, `KEYBOARD`), and header words such as `Authorization: Bearer x`;
/// - the userinfo of a URL (`scheme://user:pw@host`) and the value of `?token=` / `&key=` / `#access_token=`;
/// - the same inside the payload of `sh|bash|zsh|dash|… -c '<script>'` and inside any argument that holds whitespace, word by
///   word and recursively, with the original spacing and quoting of the script kept.
///
/// Control, format, line- and paragraph-separator characters (newlines, bidi overrides, zero-width joiners) are replaced by
/// U+FFFD, because they cannot be told apart from ordinary text on a card. Redacting text that is already redacted changes
/// nothing. Nothing here truncates.
public enum ArgvRedaction {
    /// Replaces a hidden value.
    public static let mask = "•••"
    /// Replaces an invisible character in a displayed argument.
    static let replacement = "\u{FFFD}"

    /// Nesting of `sh -c` payloads / quoted words that is looked into; a script nested deeper is hidden as a whole.
    private static let maxDepth = 4

    // MARK: API

    /// Per token, same count and order: secrets hidden, invisible characters replaced.
    public static func redact(tokens: [String]) -> [String] {
        redact(tokens, depth: 0)
    }

    /// argv as one display line: the redacted tokens joined by a single space.
    public static func redactedLine(arguments: [String]) -> String {
        redact(tokens: arguments).joined(separator: " ")
    }

    /// An already-joined command line (`DevServer.command`, a rewritten process title): split into shell words, the quoting
    /// and the spacing between the words are kept.
    public static func redactedLine(commandLine: String) -> String {
        sanitized(redactScript(commandLine, depth: 0))
    }

    /// Invisible characters replaced, nothing hidden (names and paths, which hold no secret).
    static func sanitized(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isInvisible) else { return text }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isInvisible(scalar) { out.append(contentsOf: replacement.unicodeScalars) } else { out.append(scalar) }
        }
        return String(out)
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }

    // MARK: Tokens

    private static func redact(_ tokens: [String], depth: Int) -> [String] {
        let payloads = shellPayloadIndices(in: tokens)
        var out: [String] = []
        out.reserveCapacity(tokens.count)
        var hideNext = false
        for (index, token) in tokens.enumerated() {
            if payloads.contains(index) {
                hideNext = false
                out.append(sanitized(redactScript(token, depth: depth + 1)))
                continue
            }
            if hideNext, !token.hasPrefix("-") {
                hideNext = false
                out.append(mask)
                continue
            }
            let redacted = redactToken(token, depth: depth)
            hideNext = redacted.hidesNext
            out.append(sanitized(redacted.text))
        }
        return out
    }

    /// `hidesNext`: the token is a secret-named flag whose value is the next token (or the word `Bearer`).
    private static func redactToken(_ token: String, depth: Int) -> (text: String, hidesNext: Bool) {
        if token.hasPrefix("-"), token.count > 1 {
            let space = token.firstIndex(where: \.isWhitespace)
            if let equals = token.firstIndex(of: "="), space.map({ equals < $0 }) ?? true {
                let flag = token[..<equals]
                if isSecretFlag(flag) { return (String(flag) + "=" + mask, false) }
                let value = String(token[token.index(after: equals)...])
                return (String(flag) + "=" + redactValue(value, depth: depth), false)
            }
            if space == nil { return (token, isSecretFlag(token[...])) }
        }
        return (redactValue(token, depth: depth), token.lowercased() == "bearer")
    }

    /// A value that is not a flag: an assignment, an argument with whitespace, a URL.
    private static func redactValue(_ value: String, depth: Int) -> String {
        if let masked = maskedAssignment(value) { return masked }
        if value.contains(where: \.isWhitespace) { return redactScript(value, depth: depth + 1) }
        return hidingQuerySecrets(in: hidingCredentials(inURL: value))
    }

    // MARK: Names

    /// Long words that make a name secret wherever they occur in it.
    private static let strongWords = [
        "token", "secret", "password", "passwd", "passphrase", "credential", "bearer",
        "apikey", "api-key", "api_key", "privatekey", "private-key", "private_key", "accesskey", "access-key", "access_key",
    ]
    /// Short words that count only as a whole word of the name (`API_KEY`, `--db-pass`, `dbPass`).
    private static let wholeWords: Set<String> = [
        "pass", "pwd", "pw", "auth", "authorization", "key", "cookie", "cookies", "jwt", "dsn",
    ]
    /// A name without a leading dash may also end in one of these (`APIKEY`, `DBPASS`).
    private static let gluedSuffixes = ["key", "pass", "pwd", "auth", "jwt", "dsn"]

    private static func isSecretFlag(_ flag: Substring) -> Bool {
        isSecretName(String(flag.drop(while: { $0 == "-" })), glued: false)
    }

    private static func isSecretName(_ name: String, glued: Bool) -> Bool {
        let lower = name.lowercased()
        if strongWords.contains(where: { lower.contains($0) }) { return true }
        if words(of: name).contains(where: { wholeWords.contains($0) }) { return true }
        return glued && gluedSuffixes.contains { lower.hasSuffix($0) }
    }

    /// Lowercased parts of `name` split at `- _ . :` and spaces; a part with a lower→upper step also yields its last camel
    /// word (`dbPass` → `pass`) but not the others, so `passWithNoTests` is not a password flag.
    private static func words(of name: String) -> [String] {
        var out: [String] = []
        for part in name.split(whereSeparator: { "-_.: ".contains($0) }) {
            out.append(part.lowercased())
            var tail = ""
            var previous: Character?
            var stepped = false
            for character in part {
                if let previous, character.isUppercase, !previous.isUppercase {
                    tail = ""
                    stepped = true
                }
                tail.append(character)
                previous = character
            }
            if stepped { out.append(tail.lowercased()) }
        }
        return out
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
    }

    // MARK: Values

    /// `API_TOKEN=x`, `API_TOKEN:x`, `Authorization: Bearer x` → the name, its separator and the mask. nil when the token is not
    /// an assignment of a secret-named variable. A colon counts only after an upper-case name (`--var API_TOKEN:x`) or when a
    /// space follows it (a header), so a lower-case script name such as `npm run auth:login` stays readable.
    private static func maskedAssignment(_ token: String) -> String? {
        guard let separator = token.firstIndex(where: { $0 == "=" || $0 == ":" }), separator != token.startIndex else { return nil }
        let name = token[..<separator]
        guard let first = name.first, first != "-", name.allSatisfy(isNameCharacter),
              isSecretName(String(name), glued: true) else { return nil }
        let valueStart = token.index(after: separator)
        guard valueStart < token.endIndex else { return nil }
        let spaced = token[separator] == ":" && token[valueStart] == " "
        if token[separator] == ":", !spaced, String(name) != name.uppercased() { return nil }
        return String(token[...separator]) + (spaced ? " " : "") + mask
    }

    /// `https://user:pass@host` → `https://•••@host`. The userinfo is everything up to the last `@` of the authority
    /// (the text before the first `/`, `?` or `#`), so an `@` in a password does not leak the rest of it.
    private static func hidingCredentials(inURL token: String) -> String {
        guard token.contains("://") else { return token }
        var out = ""
        var rest = token[...]
        while let scheme = rest.range(of: "://") {
            out += rest[..<scheme.upperBound]
            rest = rest[scheme.upperBound...]
            let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
            if let at = rest[..<authorityEnd].lastIndex(of: "@"), at > rest.startIndex {
                out += mask
                rest = rest[at...]
            }
        }
        out += rest
        return out
    }

    /// `?token=x&page=2` → `?token=•••&page=2` (also after `#` and between `&`).
    private static func hidingQuerySecrets(in token: String) -> String {
        guard let start = token.firstIndex(where: { $0 == "?" || $0 == "#" }), token[start...].contains("=") else { return token }
        var out = String(token[..<start])
        var rest = token[start...]
        while let delimiter = rest.first {
            out.append(delimiter)
            rest = rest.dropFirst()
            let end = rest.firstIndex(where: { $0 == "&" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
            let pair = rest[..<end]
            if let equals = pair.firstIndex(of: "="), equals != pair.startIndex, pair.index(after: equals) < pair.endIndex,
               isSecretName(String(pair[..<equals]), glued: true) {
                out.append(contentsOf: pair[...equals])
                out += mask
            } else {
                out.append(contentsOf: pair)
            }
            rest = rest[end...]
        }
        return out
    }

    // MARK: Shell payloads

    private static let shellNames: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "csh", "tcsh"]

    /// Indices of the tokens that are the script of `<shell> [-flags] -c <script>` (`-c`, `-lc`, `-ic`…; `-o`/`-O` take a
    /// value; `--long` flags are skipped; `--` ends the options).
    private static func shellPayloadIndices(in tokens: [String]) -> Set<Int> {
        var found: Set<Int> = []
        for (index, token) in tokens.enumerated() {
            if token.hasPrefix("-"), index != 0 { continue }
            var name = Substring(ProcessNames.basename(token))
            while name.first == "-" { name = name.dropFirst() }
            guard shellNames.contains(name.lowercased()) else { continue }
            var next = index + 1
            while next < tokens.count {
                let flag = tokens[next]
                guard flag.hasPrefix("-"), flag != "--", flag.count > 1 else { break }
                if flag == "-o" || flag == "-O" { next += 2; continue }
                if !flag.hasPrefix("--"), flag.dropFirst().contains("c") {
                    if next + 1 < tokens.count { found.insert(next + 1) }
                    break
                }
                next += 1
            }
        }
        return found
    }

    private struct Piece {
        var text: String
        let isWord: Bool
        /// A gap that ends a command (`;`, `|`, `&`, parentheses, a backtick, a newline): a secret flag does not hide the
        /// first word of the next command.
        let isBoundary: Bool
    }

    private static let operators: Set<Character> = [";", "|", "&", "(", ")", "`"]

    /// Redacts a script word by word. Quoted words are judged by their unquoted text; a word that stays as it is keeps its
    /// quotes, a changed one keeps the quote characters that enclosed it. The gaps between words are kept as they were.
    private static func redactScript(_ script: String, depth: Int) -> String {
        guard depth <= maxDepth else { return mask }
        var pieces = split(script)
        var group: [Int] = []
        func flush() {
            guard !group.isEmpty else { return }
            let raw = group.map { pieces[$0].text }
            let plain = raw.map(unquoted)
            let redacted = redact(plain, depth: depth)
            for (offset, index) in group.enumerated() {
                pieces[index].text = redacted[offset] == plain[offset] ? raw[offset] : requoted(redacted[offset], like: raw[offset])
            }
            group.removeAll()
        }
        for index in pieces.indices {
            if pieces[index].isWord {
                group.append(index)
            } else if pieces[index].isBoundary {
                flush()
            }
        }
        flush()
        return pieces.map(\.text).joined()
    }

    /// `text` inside the quote characters that enclosed the whole of `raw`; as it is when `raw` was not wrapped in one pair of
    /// quotes or when `text` itself holds that quote character.
    private static func requoted(_ text: String, like raw: String) -> String {
        guard raw.count >= 2, let open = raw.first, open == "'" || open == "\"", raw.last == open, !text.contains(open) else {
            return text
        }
        return String(open) + text + String(open)
    }

    /// Words and gaps of `script`, in order; joining their texts gives `script` back.
    private static func split(_ script: String) -> [Piece] {
        var pieces: [Piece] = []
        var word = ""
        var gap = ""
        var quote: Character?
        var escaped = false

        func endWord() {
            guard !word.isEmpty else { return }
            pieces.append(Piece(text: word, isWord: true, isBoundary: false))
            word = ""
        }
        func endGap() {
            guard !gap.isEmpty else { return }
            let boundary = gap.contains { operators.contains($0) || $0.isNewline }
            pieces.append(Piece(text: gap, isWord: false, isBoundary: boundary))
            gap = ""
        }

        for character in script {
            if escaped {
                word.append(character)
                escaped = false
            } else if let open = quote {
                word.append(character)
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"" {
                    escaped = true
                }
            } else if character == "\\" {
                endGap()
                word.append(character)
                escaped = true
            } else if character == "'" || character == "\"" {
                endGap()
                word.append(character)
                quote = character
            } else if character.isWhitespace || operators.contains(character) {
                endWord()
                gap.append(character)
            } else {
                endGap()
                word.append(character)
            }
        }
        endWord()
        endGap()
        return pieces
    }

    /// `"a b"` → `a b`, `a\ b` → `a b`, `'x'y` → `xy`.
    private static func unquoted(_ word: String) -> String {
        guard word.contains(where: { $0 == "'" || $0 == "\"" || $0 == "\\" }) else { return word }
        var out = ""
        var quote: Character?
        var escaped = false
        for character in word {
            if escaped {
                out.append(character)
                escaped = false
            } else if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"" {
                    escaped = true
                } else {
                    out.append(character)
                }
            } else if character == "\\" {
                escaped = true
            } else if character == "'" || character == "\"" {
                quote = character
            } else {
                out.append(character)
            }
        }
        return out
    }
}
