import Foundation

/// Extracts the document `<title>` from the first bytes of an HTML page. Case-insensitive, multi-line, comment- and
/// `<script>`/`<style>`-aware, entity-decoding, whitespace-collapsing, capped at `maxLength` characters. Generic template titles
/// ("Vite App", "React App", …) are not titles. Everything here is a pure function over bytes.
enum HTMLTitle {
    static let maxLength = 120

    /// Lowercased; compared after whitespace collapsing. Placeholder titles of the usual project templates and servers.
    static let genericTitles: Set<String> = [
        "vite app", "react app", "create next app", "next.js", "document", "untitled", "untitled document", "error",
        "localhost", "127.0.0.1", "[::1]", "index of /", "directory listing for /",
    ]

    /// The cleaned title, or nil when there is none, it is empty or it is a generic template title.
    static func title(inHTML bytes: [UInt8]) -> String? {
        guard let slice = scan(bytes).title else { return nil }
        guard let cleaned = DisplayText.clean(decodeEntities(String(decoding: slice, as: UTF8.self)), limit: maxLength) else {
            return nil
        }
        return isGeneric(cleaned) ? nil : cleaned
    }

    /// A placeholder, not a name: the exact titles in `genericTitles`, every `Vite + <framework>` template title (`Vite + Vue`,
    /// `Vite + Svelte`, `Vite + React + TS`…), and a bare address (`localhost:5173`, `127.0.0.1:3000`).
    static func isGeneric(_ title: String) -> Bool {
        let lowered = title.lowercased()
        if genericTitles.contains(lowered) { return true }
        if lowered.hasPrefix("vite"), lowered.dropFirst("vite".count).drop(while: \.isWhitespace).hasPrefix("+") { return true }
        for address in ["localhost:", "127.0.0.1:", "[::1]:"] where lowered.hasPrefix(address) {
            let port = lowered.dropFirst(address.count)
            if !port.isEmpty, port.allSatisfy(\.isASCII), port.allSatisfy(\.isNumber) { return true }
        }
        return false
    }

    /// True once the markup that can still hold the document title is behind us (`</title`, `</head`, `<body`), so a reader
    /// can stop early instead of downloading the whole page.
    static func isPastTitle(_ bytes: [UInt8]) -> Bool {
        scan(bytes).pastTitle
    }

    // MARK: Scanning

    private struct Scan {
        var title: ArraySlice<UInt8>?
        var pastTitle: Bool
        static let incomplete = Scan(title: nil, pastTitle: false)
    }

    private enum Pattern {
        static let lessThan = UInt8(ascii: "<")
        static let commentOpen = Array("<!--".utf8)
        static let commentClose = Array("-->".utf8)
        static let titleOpen = Array("<title".utf8)
        static let titleClose = Array("</title".utf8)
        static let headClose = Array("</head".utf8)
        static let bodyOpen = Array("<body".utf8)
        static let greaterThan = Array(">".utf8)
        /// Elements whose text is never markup: a "<title>" inside a script string is not the document title.
        static let rawText: [(open: [UInt8], close: [UInt8])] = [
            (Array("<script".utf8), Array("</script".utf8)),
            (Array("<style".utf8), Array("</style".utf8)),
        ]
    }

    private static func scan(_ bytes: [UInt8]) -> Scan {
        let count = bytes.count
        var index = 0
        scanning: while index < count {
            guard bytes[index] == Pattern.lessThan else { index += 1; continue }
            if hasPrefix(bytes, at: index, Pattern.commentOpen) {
                guard let end = find(bytes, Pattern.commentClose, from: index + Pattern.commentOpen.count) else { return .incomplete }
                index = end + Pattern.commentClose.count
                continue
            }
            if hasPrefix(bytes, at: index, Pattern.titleOpen), isTagNameEnd(bytes, at: index + Pattern.titleOpen.count) {
                guard let open = find(bytes, Pattern.greaterThan, from: index + Pattern.titleOpen.count),
                      let close = find(bytes, Pattern.titleClose, from: open + 1) else { return .incomplete }
                return Scan(title: bytes[(open + 1)..<close], pastTitle: true)
            }
            for element in Pattern.rawText
            where hasPrefix(bytes, at: index, element.open) && isTagNameEnd(bytes, at: index + element.open.count) {
                guard let end = find(bytes, element.close, from: index + element.open.count) else { return .incomplete }
                index = end + element.close.count
                continue scanning
            }
            if hasPrefix(bytes, at: index, Pattern.headClose)
                || (hasPrefix(bytes, at: index, Pattern.bodyOpen) && isTagNameEnd(bytes, at: index + Pattern.bodyOpen.count)) {
                return Scan(title: nil, pastTitle: true)
            }
            index += 1
        }
        return .incomplete
    }

    /// The byte after a tag name must end it (`>`, `/`, whitespace), so `<titles>` / `<bodyguard>` are not matched.
    private static func isTagNameEnd(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index < bytes.count else { return false }
        let byte = bytes[index]
        return byte == UInt8(ascii: ">") || byte == UInt8(ascii: "/") || byte == 0x20 || byte == 0x09 || byte == 0x0A
            || byte == 0x0D || byte == 0x0C
    }

    /// ASCII case-insensitive prefix test; `pattern` must be lowercase ASCII.
    private static func hasPrefix(_ bytes: [UInt8], at index: Int, _ pattern: [UInt8]) -> Bool {
        guard index + pattern.count <= bytes.count else { return false }
        for offset in 0..<pattern.count where lowercase(bytes[index + offset]) != pattern[offset] { return false }
        return true
    }

    /// First ASCII case-insensitive occurrence of the lowercase ASCII `pattern` at or after `start`.
    private static func find(_ bytes: [UInt8], _ pattern: [UInt8], from start: Int) -> Int? {
        guard let first = pattern.first, start >= 0, bytes.count >= pattern.count else { return nil }
        var index = start
        let last = bytes.count - pattern.count
        while index <= last {
            if lowercase(bytes[index]) == first, hasPrefix(bytes, at: index, pattern) { return index }
            index += 1
        }
        return nil
    }

    private static func lowercase(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    // MARK: Entities

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "middot": "·", "bull": "•",
        "laquo": "«", "raquo": "»", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "times": "×", "deg": "°",
        "plusmn": "±", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶", "larr": "←",
        "rarr": "→", "uarr": "↑", "darr": "↓", "check": "✓",
    ]

    /// Named (`&amp;`), decimal (`&#8212;`) and hexadecimal (`&#x2014;`) references. Unknown or malformed references stay as
    /// written.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&" else {
                out.append(character)
                index = text.index(after: index)
                continue
            }
            var cursor = text.index(after: index)
            var body = ""
            while cursor < text.endIndex, body.count <= 10, text[cursor] != ";", text[cursor] != "&", !text[cursor].isWhitespace {
                body.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            if cursor < text.endIndex, text[cursor] == ";", let decoded = decode(reference: body) {
                out += decoded
                index = text.index(after: cursor)
            } else {
                out.append(character)
                index = text.index(after: index)
            }
        }
        return out
    }

    private static func decode(reference body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if let first = digits.first, first == "x" || first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, let scalar = Unicode.Scalar(value), scalar.properties.generalCategory != .control else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[body]
    }
}
