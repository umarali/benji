import XCTest
@testable import BenjiCore

/// What the panel shows for an answer (inline Markdown, nothing clickable).
final class PanelMarkdownTests: XCTestCase {
    #if canImport(Darwin)
    func testInlineMarkupIsRenderedNotShown() {
        let a = PanelMarkdown.attributed("I'm **Benji**; files go to `output/`, *not* tmp.")
        XCTAssertEqual(String(a.characters), "I'm Benji; files go to output/, not tmp.")
        let bold = a.runs.first { String(a[$0.range].characters) == "Benji" }
        XCTAssertEqual(bold?.inlinePresentationIntent, .stronglyEmphasized)
        let code = a.runs.first { String(a[$0.range].characters) == "output/" }
        XCTAssertEqual(code?.inlinePresentationIntent, .code)
    }

    func testLineBreaksAndStepNumbersAreKept() {
        XCTAssertEqual(PanelMarkdown.plain("Do this:\n1. Open **Settings**\n2. Click Save"),
                       "Do this:\n1. Open Settings\n2. Click Save")
    }

    func testLinksAndImagesAreNotClickable() {
        let a = PanelMarkdown.attributed("See [the docs](https://example.com) and ![x](https://example.com/x.png) or <https://example.com/raw>")
        XCTAssertTrue(a.runs.allSatisfy { $0.link == nil && $0.imageURL == nil })
        XCTAssertTrue(String(a.characters).hasPrefix("See the docs and "))
    }
    #endif

    func testUnbalancedMarkupFallsBackToText() {
        XCTAssertEqual(PanelMarkdown.plain("2 * 3 = 6, and a lone ` tick"), "2 * 3 = 6, and a lone ` tick")
    }

    func testPlainTextIsUnchanged() {
        XCTAssertEqual(PanelMarkdown.plain("Done. Wrote output/notes.md."), "Done. Wrote output/notes.md.")
    }
}
