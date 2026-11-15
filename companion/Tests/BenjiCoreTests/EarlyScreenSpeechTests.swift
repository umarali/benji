import XCTest
@testable import BenjiCore

/// An answer about the screen is spoken from its first sentence; its marks arrive with the
/// whole answer and catch up with what the voice has already said.
final class EarlyScreenSpeechTests: XCTestCase {
    private let pixel = CGSize(width: 1000, height: 500)
    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 500)
    private func t(_ shape: PointingShape, _ label: String) -> PointingTarget { PointingTarget(shape: shape, label: label) }

    func testAlignmentIgnoresOnlyWhiteSpace() {
        // The voice says sentences joined by single spaces; the cues index the answer cleaned whole.
        let target = "Here is the Total.\n\nNow look at Pay."
        let spoken = "Here is the Total. Now look at Pay."
        let pay = (spoken as NSString).range(of: "Pay").location
        XCTAssertEqual(SpokenAlignment.offset(pay, in: spoken, to: target), (target as NSString).range(of: "Pay").location)
        XCTAssertEqual(SpokenAlignment.offset(0, in: spoken, to: target), 0)
        XCTAssertEqual(SpokenAlignment.offset(12, in: spoken, to: spoken), 12)      // the same text: as is
        XCTAssertNil(SpokenAlignment.offset(500, in: spoken + " And more words here, far past the end.", to: target))
    }

    func testMarksCatchUpWithAVoiceThatStartedFirst() {
        // The voice started at 1.0 s and was told when its words fall; the answer (and its marks)
        // arrives at 2.5 s. The first mark's word was heard at 1.4 s: it shows at once; the second
        // keeps its time on the voice, not the fallback estimate from the answer's arrival.
        let text = "Here is the Total. Now look at Pay."
        var plan = PointingPlan(targets: [t(.circle(x1: 100, y1: 100, x2: 200, y2: 140), "Total"),
                                          t(.circle(x1: 300, y1: 100, x2: 400, y2: 140), "Pay")],
                                text: text, speaking: true, pixelSize: pixel, screenFrame: frame, displayID: nil)!
        plan.spokenFirst = true
        XCTAssertEqual(plan.cueText, SpeechText.plain(text))
        let spoken = "Here is the Total. Now look at Pay."
        let heard: [SpokenProgress.Mark] = [.init(at: 1.4, offset: 12), .init(at: 4.0, offset: 31)]
        var seq = plan.sequence(reduceMotion: false, now: 2.5)
        // What the overlay replays when the plan arrives.
        seq.speechDidStart(at: 1.0)
        for m in heard {
            seq.speechWillReach(offset: SpokenAlignment.offset(m.offset, in: spoken, to: plan.cueText)!, at: m.at)
        }
        XCTAssertEqual(seq.deadline(), 1.4)                 // already due: shown on the next frame
        XCTAssertEqual(seq.advance(to: 2.5), [.reveal(0)])
        XCTAssertEqual(seq.deadline(), 4.0)                 // the voice's time for "Pay"
    }

    func testWithoutTheReplayTheMarksWouldLag() {
        // Without the replay, a sequence that never hears the start waits for the voice.
        let text = "Here is the Total. Now look at Pay."
        let plan = PointingPlan(targets: [t(.circle(x1: 100, y1: 100, x2: 200, y2: 140), "Total")],
                                text: text, speaking: true, pixelSize: pixel, screenFrame: frame, displayID: nil)!
        var seq = plan.sequence(reduceMotion: false, now: 2.5)
        XCTAssertGreaterThan(seq.deadline() ?? 0, 2.5)
        XCTAssertEqual(seq.advance(to: 2.5), [])
    }
}
