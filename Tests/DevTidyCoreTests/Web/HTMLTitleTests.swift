import Foundation
import Testing
@testable import DevTidyCore

@Suite("HTMLTitle")
struct HTMLTitleTests {
    private func title(_ html: String) -> String? { HTMLTitle.title(inHTML: Array(html.utf8)) }

    @Test func aPlainTitle() {
        #expect(title("<!doctype html><html><head><title>Red Alert</title></head><body></body></html>") == "Red Alert")
    }

    @Test func tagAndAttributeCaseDoNotMatter() {
        #expect(title("<HTML><HEAD><TITLE data-x=\"1\">Shouting</TITLE ></HEAD>") == "Shouting")
        #expect(title("<head><TiTlE>Mixed</tItLe>") == "Mixed")
    }

    @Test func aTitleAcrossLinesIsCollapsed() {
        #expect(title("<head><title>\n   Red\r\n\tAlert   Dashboard \n</title>") == "Red Alert Dashboard")
    }

    @Test func entitiesAreDecoded() {
        #expect(title("<title>Tom &amp; Jerry &lt;3 &quot;cheese&quot; &#39;n&apos; chips</title>") == "Tom & Jerry <3 \"cheese\" 'n' chips")
        #expect(title("<title>Caf&#233; &#xE9; &mdash; &copy; 2026 &hellip;</title>") == "Café é — © 2026 …")
        #expect(title("<title>a&nbsp;&nbsp;b</title>") == "a b")                       // nbsp is whitespace, collapsed
        #expect(title("<title>&amp;lt;</title>") == "&lt;")                             // decoded once
    }

    @Test func unknownOrBrokenEntitiesStayAsWritten() {
        #expect(title("<title>AT&T &bogus; &#xZZ; &#0; &amp</title>") == "AT&T &bogus; &#xZZ; &#0; &amp")
    }

    @Test func missingEmptyOrUnterminatedTitlesAreNil() {
        #expect(title("<html><head></head><body>hi</body></html>") == nil)
        #expect(title("<title></title>") == nil)
        #expect(title("<title>   \n </title>") == nil)
        #expect(title("<title>never closed") == nil)
        #expect(title("") == nil)
        #expect(title("<titles>not a title</titles>") == nil)
    }

    @Test(arguments: [
        "Vite App", "vite app", "  Vite   App ", "Vite + React", "Vite + React + TS", "Vite + Vue", "Vite + Svelte", "Vite+Preact",
        "Vite + TS", "React App", "Create Next App", "Next.js", "NEXT.JS",
        "Document", "Untitled", "Error", "localhost", "localhost:5173", "127.0.0.1:3000", "[::1]:8080",
        "Index of /", "Directory listing for /",
    ])
    func genericTemplateTitlesAreIgnored(generic: String) {
        #expect(title("<head><title>\(generic)</title></head>") == nil)
    }

    @Test func aGenericTitleWrittenWithEntitiesIsStillGeneric() {
        #expect(title("<title>Vite &#43; React</title>") == nil)            // `&#43;` is "+"
    }

    @Test func aTitleThatMerelyContainsAGenericOneIsKept() {
        #expect(title("<title>My Vite App</title>") == "My Vite App")
        #expect(title("<title>Next.js Conf</title>") == "Next.js Conf")
        #expect(title("<title>Vitesse Admin</title>") == "Vitesse Admin")
        #expect(title("<title>Localhost Dashboard</title>") == "Localhost Dashboard")
        #expect(title("<title>localhost:5173/admin</title>") == "localhost:5173/admin")
        #expect(title("<title>Error budget</title>") == "Error budget")
    }

    @Test func aTitleInsideACommentOrScriptIsNotTheDocumentTitle() {
        #expect(title("<head><!-- <title>Old</title> --><title>New</title></head>") == "New")
        #expect(title("<head><script>var s = '<title>Fake</title>';</script><title>Real</title></head>") == "Real")
        #expect(title("<head><style>/* <title>x</title> */</style><title>Real</title></head>") == "Real")
        #expect(title("<head><!-- never closed <title>Hidden</title>") == nil)
    }

    @Test func aTitleAfterTheBodyStartsIsNotTheDocumentTitle() {
        // an inline SVG's <title> must not name the page
        #expect(title("<head></head><body><svg><title>Icon</title></svg>") == nil)
        #expect(title("<body class=x><svg><title>Icon</title></svg>") == nil)
    }

    @Test func aLongTitleIsCappedAtOneHundredTwentyCharacters() throws {
        let long = String(repeating: "abcdefghij", count: 30)
        let result = try #require(title("<title>\(long)</title>"))
        #expect(result.count == HTMLTitle.maxLength)
        #expect(result.hasSuffix("…"))
        #expect(result.hasPrefix("abcdefghij"))
        let exact = String(repeating: "x", count: 120)
        #expect(title("<title>\(exact)</title>") == exact)
    }

    @Test func controlAndBidiCharactersNeverReachTheScreen() {
        #expect(title("<title>a\u{202E}b\u{0007}c\u{2066}d</title>") == "abcd")
    }

    // MARK: Titles that attack the renderer (Security F3-1)

    @Test func bidiOverridesAreStrippedAlsoWhenWrittenAsEntities() {
        #expect(title("<title>evil&#x202E;gpj.exe</title>") == "evilgpj.exe")
        #expect(title("<title>\u{202E}\u{2067}ab\u{2069}\u{200F}c\u{061C}</title>") == "abc")
    }

    @Test func lineAndParagraphSeparatorsAreSpacesNotLineBreaks() {
        #expect(title("<title>a\u{2028}b\u{2029}c\u{0085}d</title>") == "a b c d")
    }

    @Test func aTitleOfInvisibleCharactersIsNoTitleSoTheManifestNameCanShow() {
        #expect(title("<title>" + String(repeating: "\u{200B}", count: 50) + "</title>") == nil)
        for invisible in ["\u{2060}", "\u{FEFF}", "\u{200E}", "\u{3164}", "\u{2800}", "\u{E0041}", "&#x200B;", "&#x202E;", " \u{200B} "] {
            #expect(title("<title>\(invisible)</title>") == nil, "\(invisible.debugDescription)")
        }
        #expect(title("<title>\u{200B}Admin\u{200B}</title>") == "Admin")
    }

    @Test func aCombiningMarkBombIsBoundedByScalarsNotCharacters() throws {
        // ONE grapheme cluster of 200 001 scalars: a character count says "1 ≤ 120" and lets all of it through.
        let bomb = "e" + String(repeating: "\u{0301}", count: 200_000)
        let result = try #require(title("<title>\(bomb)</title>"))
        #expect(result.unicodeScalars.first == "e")
        #expect(result.unicodeScalars.count <= 1 + DisplayText.maxMarksPerBase)

        // marks spread over a long title stay bounded too
        let zalgo = String(repeating: "a" + String(repeating: "\u{0301}", count: 40), count: 500)
        let spread = try #require(title("<title>\(zalgo)</title>"))
        #expect(spread.unicodeScalars.count <= HTMLTitle.maxLength * DisplayText.scalarsPerCharacter)
        #expect(spread.count <= HTMLTitle.maxLength)
        #expect(spread.hasSuffix("…"))
    }

    @Test func aChainOfZeroWidthJoinersIsBounded() throws {
        let chain = "👨" + String(repeating: "\u{200D}👨", count: 100_000)
        let result = try #require(title("<title>\(chain)</title>"))
        #expect(result.unicodeScalars.count <= HTMLTitle.maxLength * DisplayText.scalarsPerCharacter)
        #expect(result.count <= HTMLTitle.maxLength)
        // No cluster is wider than the longest joined sequence that is kept: four emoji and three joiners.
        let widest = result.dropLast().map { $0.unicodeScalars.count }.max() ?? 0
        #expect(widest <= 2 * (DisplayText.maxJoinersPerSequence + 1) - 1)
    }

    @Test func joinersThatBelongToTheTextAreKept() {
        // a family emoji: four emoji, three zero-width joiners
        let family = "👨\u{200D}👩\u{200D}👧\u{200D}👦"
        #expect(family.unicodeScalars.count == 7)
        #expect(title("<title>\(family) Aile</title>") == "\(family) Aile")
        // a Persian zero-width non-joiner between two letters
        let persian = "می\u{200C}خواهم"
        #expect(title("<title>\(persian)</title>") == persian)
        // a joiner with nothing to join is dropped
        #expect(title("<title>a\u{200D} b</title>") == "a b")
        #expect(title("<title>\u{200D}a</title>") == "a")
    }

    @Test func multibyteTextSurvives() {
        #expect(title("<title>Türkçe başlık — 日本語 🚀</title>") == "Türkçe başlık — 日本語 🚀")
    }

    // MARK: early stop

    @Test func theReaderCanStopOnceTheTitleOrTheHeadIsBehindIt() {
        #expect(!HTMLTitle.isPastTitle(Array("<html><head><meta charset=utf-8>".utf8)))
        #expect(!HTMLTitle.isPastTitle(Array("<html><head><title>half".utf8)))
        #expect(HTMLTitle.isPastTitle(Array("<html><head><title>done</title>".utf8)))
        #expect(HTMLTitle.isPastTitle(Array("<html><head></head>".utf8)))
        #expect(HTMLTitle.isPastTitle(Array("<html><body>".utf8)))
    }
}
