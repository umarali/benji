import XCTest
@testable import BenjiCore

final class StatusGlyphTests: XCTestCase {
    func testRestingPhasesShowTheIdleGlyph() {
        XCTAssertEqual(StatusGlyph.glyph(for: .idle), .idle)
        XCTAssertEqual(StatusGlyph.glyph(for: .error), .idle)
    }

    func testEveryBusyPhaseShowsTheWorkingGlyph() {
        for phase in [CompanionPhase.listening, .transcribing, .thinking, .speaking, .awaitingApproval] {
            XCTAssertEqual(StatusGlyph.glyph(for: phase), .working, "\(phase)")
        }
    }

    func testEveryPhaseIsDecidedAndOnlyIdleAndErrorAreAtRest() {
        let all: [CompanionPhase] = [.idle, .listening, .transcribing, .thinking, .speaking, .awaitingApproval, .error]
        XCTAssertEqual(all.filter { StatusGlyph.glyph(for: $0) == .idle }, [.idle, .error])
    }

    func testEachGlyphNamesItsBundledFile() {
        XCTAssertEqual(StatusGlyph.idle.resourceName, "MenuBarGlyph")
        XCTAssertEqual(StatusGlyph.working.resourceName, "MenuBarGlyphWorking")
    }
}
