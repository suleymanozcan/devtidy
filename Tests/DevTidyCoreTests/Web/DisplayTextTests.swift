import Foundation
import Testing
@testable import DevTidyCore

/// `DisplayText` is the one gate every untrusted string passes before the UI shows it (page titles, manifest names, folder and
/// process names, paths, command lines). The page-title path is covered end to end in `HTMLTitleTests`; here the gate itself.
@Suite("DisplayText")
struct DisplayTextTests {
    private func clean(_ text: String, limit: Int = 120) -> String? { DisplayText.clean(text, limit: limit) }

    // MARK: clean

    @Test func ordinaryTextIsKeptAndTrimmed() {
        #expect(clean("  Kızıl   Alarm \n — Prototip\t") == "Kızıl Alarm — Prototip")
        #expect(clean("日本語 🚀") == "日本語 🚀")
        #expect(clean("") == nil)
        #expect(clean("   \n\t ") == nil)
    }

    @Test func everyInvisibleScalarClassIsDropped() {
        let invisibles = [
            "\u{200B}", "\u{200E}", "\u{200F}", "\u{202A}", "\u{202E}", "\u{2060}", "\u{2066}", "\u{2069}", "\u{FEFF}", "\u{00AD}",
            "\u{061C}", "\u{E0041}", "\u{0007}", "\u{001B}", "\u{3164}", "\u{115F}", "\u{2800}", "\u{FFA0}", "\u{034F}",
        ]
        for invisible in invisibles {
            #expect(clean("a\(invisible)b") == "ab", "\(invisible.unicodeScalars.map(\.value))")
            #expect(clean(invisible) == nil, "\(invisible.unicodeScalars.map(\.value))")
        }
    }

    @Test func lineBreaksAndOddSpacesCollapseToOneSpace() {
        #expect(clean("a\r\nb\u{2028}c\u{2029}d\u{00A0}e\u{3000}f\u{0085}g") == "a b c d e f g")
    }

    @Test func aTextOfNothingButInvisibleCharactersOrMarksIsNil() {
        #expect(clean(String(repeating: "\u{200B}", count: 1_000)) == nil)
        #expect(clean("\u{200B}\u{202E}\u{FEFF} \u{2060}") == nil)
        #expect(clean("\u{0301}\u{0301}") == nil)                              // marks with no base
        #expect(clean("\u{200D}") == nil)
    }

    @Test func aCombiningMarkBombIsBoundedByScalars() throws {
        // One grapheme cluster of 300 001 scalars: a character cap sees "1 ≤ 120" and lets all of it through.
        let bomb = "e" + String(repeating: "\u{0301}", count: 300_000)
        let result = try #require(clean(bomb))
        #expect(result.unicodeScalars.count == 1 + DisplayText.maxMarksPerBase)
        #expect(result.unicodeScalars.first == "e")
    }

    @Test func marksAreKeptUpToTheLimitPerBase() throws {
        let three = "a\u{0301}\u{0302}\u{0303}"
        #expect(clean(three) == three)
        let eight = "a" + String(repeating: "\u{0301}", count: 8)
        let capped = try #require(clean(eight))
        #expect(capped.unicodeScalars.count == 1 + DisplayText.maxMarksPerBase)
        // the limit is per base: two bases each keep theirs
        let two = "a\u{0301}\u{0302}b\u{0301}\u{0302}"
        #expect(clean(two) == two)
    }

    @Test func theOutputIsBoundedByScalarsEvenWhenEveryCharacterIsWide() throws {
        let wide = String(repeating: "a" + String(repeating: "\u{0301}", count: 40), count: 1_000)
        let result = try #require(clean(wide, limit: 50))
        #expect(result.unicodeScalars.count <= 50 * DisplayText.scalarsPerCharacter)
        #expect(result.count <= 50)
        #expect(result.hasSuffix("…"))
    }

    @Test func aChainOfJoinersIsCutAndNoClusterIsWiderThanAFamilyEmoji() throws {
        let chain = "👨" + String(repeating: "\u{200D}👨", count: 200_000)
        let result = try #require(clean(chain))
        #expect(result.unicodeScalars.count <= 120 * DisplayText.scalarsPerCharacter)
        #expect(result.count <= 120)
        let widest = result.dropLast().map { $0.unicodeScalars.count }.max() ?? 0
        #expect(widest == 2 * (DisplayText.maxJoinersPerSequence + 1) - 1)
    }

    @Test func joinersBetweenCharactersSurviveAndDanglingOnesDoNot() {
        let family = "👨\u{200D}👩\u{200D}👧\u{200D}👦"
        #expect(clean(family) == family)
        #expect(clean("می\u{200C}خواهم") == "می\u{200C}خواهم")
        #expect(clean("a\u{200D}") == "a")
        #expect(clean("\u{200D}a") == "a")
        #expect(clean("a\u{200D}\u{200D}\u{200D}b") == "a\u{200D}b")           // one joiner joins, the rest are noise
        #expect(clean("a\u{200D} b") == "a b")
    }

    @Test func aLongTextIsCutToTheLimitWithAnEllipsis() throws {
        let result = try #require(clean(String(repeating: "x", count: 500), limit: 10))
        #expect(result == String(repeating: "x", count: 9) + "…")
        #expect(clean(String(repeating: "x", count: 10), limit: 10) == String(repeating: "x", count: 10))
        #expect(clean("abc def ghi", limit: 5) == "abc…")                      // no space before the ellipsis
        #expect(clean("abc", limit: 1) == "a")
        #expect(clean("abc", limit: 0) == nil)
    }

    @Test func aCutNeverLeavesADanglingJoiner() throws {
        // "ab<ZWJ>" repeated: the clusters alternate `a` and `b<ZWJ>`, so a cut after an even number of clusters lands right
        // behind a joiner.
        let text = String(repeating: "ab\u{200D}", count: 400)
        let result = try #require(clean(text, limit: 21))
        #expect(result.hasSuffix("…"))
        let body = Array(result.unicodeScalars.dropLast())                      // without the ellipsis
        #expect(body.last == "b")
        #expect(!body.isEmpty)
    }

    // MARK: label

    @Test func aLabelShowsWhatIsThereOrACodePointPreviewOfWhatIsNot() {
        #expect(DisplayText.label("client") == "client")
        #expect(DisplayText.label("a\u{202E}b") == "ab")
        #expect(DisplayText.label("") == "")
        #expect(DisplayText.label("\u{200B}") == "‹U+200B›")
        #expect(DisplayText.label("\u{200B}\u{2060}\u{FEFF}\u{200E}\u{202E}") == "‹U+200B U+2060 U+FEFF U+200E …›")
    }

    // MARK: literal

    @Test func aLiteralKeepsItsSpacingAndReplacesWhatCannotBeSeen() {
        #expect(DisplayText.literal("/Users/me/my  project/x", scalarLimit: 100) == "/Users/me/my  project/x")
        #expect(DisplayText.literal("/a\u{202E}b/c\nd\te\u{200B}f", scalarLimit: 100) == "/a\u{FFFD}b/c\u{FFFD}d\u{FFFD}e\u{FFFD}f")
        #expect(DisplayText.literal("a\u{2028}b", scalarLimit: 100) == "a\u{FFFD}b")
    }

    @Test func aLiteralCanKeepPlainLineFeeds() {
        #expect(DisplayText.literal("a\nb\r\nc\u{1B}", scalarLimit: 100, keepingLineBreaks: true) == "a\nb\u{FFFD}\nc\u{FFFD}")
    }

    @Test func aLiteralIsBoundedInScalarsAndKeepsRunsOfMarksShort() throws {
        let bomb = "/x" + String(repeating: "\u{0301}", count: 100_000)
        let shown = DisplayText.literal(bomb, scalarLimit: 4_000)
        #expect(shown.unicodeScalars.count == 2 + DisplayText.maxMarksPerBase)

        let long = String(repeating: "z", count: 10_000)
        let cut = DisplayText.literal(long, scalarLimit: 4_000)
        #expect(cut.unicodeScalars.count == 4_000)
        #expect(cut.hasSuffix("…"))
        #expect(DisplayText.literal(String(repeating: "z", count: 4_000), scalarLimit: 4_000).hasSuffix("z"))   // exactly fits
        #expect(DisplayText.literal("abc", scalarLimit: 1) == "…")
        #expect(DisplayText.literal("abc", scalarLimit: 0) == "")
    }

    @Test func aLiteralIsIdempotent() {
        let once = DisplayText.literal("a\u{202E}b\u{0301}\u{0302}\u{0303}\u{0304}\u{0305}\u{0306}\nc", scalarLimit: 100)
        #expect(DisplayText.literal(once, scalarLimit: 100) == once)
    }
}
