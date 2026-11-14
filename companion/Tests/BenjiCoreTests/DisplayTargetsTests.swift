import XCTest
@testable import BenjiCore

/// Displays in AppKit global coordinates: a 1512 × 982 pt laptop with a notch at the origin, a
/// 2560 × 1440 pt display to its left and lower (negative x and y), and a narrow portrait one above.
final class DisplayTargetsTests: XCTestCase {
    let laptop = DisplayDescriptor(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                   notch: CGRect(x: 661, y: 950, width: 190, height: 32), name: "Built-in Retina Display")
    let left = DisplayDescriptor(id: 2, frame: CGRect(x: -2560, y: -458, width: 2560, height: 1440), name: "Studio Display")
    let above = DisplayDescriptor(id: 3, frame: CGRect(x: 200, y: 982, width: 1080, height: 1920), name: "Portrait")
    var all: [DisplayDescriptor] { [laptop, left, above] }

    // MARK: which display

    func testThePointerIsOnTheDisplayAppKitWouldSay() {
        XCTAssertEqual(CaptureDisplay.display(at: CGPoint(x: -1, y: 0.5), in: all)?.id, left.id)
        XCTAssertEqual(CaptureDisplay.display(at: CGPoint(x: 0, y: 0.5), in: all)?.id, laptop.id, "a left edge belongs to its display")
        XCTAssertEqual(CaptureDisplay.display(at: CGPoint(x: 300, y: 982), in: all)?.id, laptop.id, "a top edge belongs to its display")
        XCTAssertEqual(CaptureDisplay.display(at: CGPoint(x: 300, y: 983), in: all)?.id, above.id)
        XCTAssertEqual(CaptureDisplay.display(at: CGPoint(x: -2560, y: -457), in: all)?.id, left.id)
        XCTAssertNil(CaptureDisplay.display(at: CGPoint(x: 5000, y: 5000), in: all))
    }

    func testALatchedDisplayIsCapturedWhereverThePointerIs() {
        let latched = CaptureTarget(id: left.id, name: "Studio Display")
        XCTAssertEqual(CaptureDisplay.choose(requested: latched, displays: all, pointer: CGPoint(x: 700, y: 900), fallback: laptop.id),
                       .display(left.id))
    }

    func testADisconnectedLatchedDisplayIsRefusedAndNeverReplaced() {
        let latched = CaptureTarget(id: left.id, name: "Studio Display")
        XCTAssertEqual(CaptureDisplay.choose(requested: latched, displays: [laptop, above], pointer: CGPoint(x: 700, y: 900),
                                             fallback: laptop.id), .disconnected(latched))
    }

    func testWithNothingLatchedThePointersDisplayThenTheFallback() {
        XCTAssertEqual(CaptureDisplay.choose(requested: nil, displays: all, pointer: CGPoint(x: -100, y: 100), fallback: laptop.id),
                       .display(left.id))
        XCTAssertEqual(CaptureDisplay.choose(requested: nil, displays: all, pointer: CGPoint(x: 9000, y: 0), fallback: laptop.id),
                       .display(laptop.id))
        XCTAssertEqual(CaptureDisplay.choose(requested: nil, displays: [left], pointer: CGPoint(x: 9000, y: 0), fallback: laptop.id),
                       .none)
    }

    func testATargetIsNamedOnlyAmongSeveralDisplays() {
        XCTAssertEqual(CaptureDisplay.target(id: left.id, among: all), CaptureTarget(id: left.id, name: "Studio Display"))
        XCTAssertEqual(CaptureDisplay.target(id: laptop.id, among: [laptop]), CaptureTarget(id: laptop.id, name: nil))
        XCTAssertNil(CaptureDisplay.target(id: 99, among: all))
    }

    // MARK: bars and anchors

    func testTheBarIsCentredAtTheTopOfANegativeOriginDisplay() {
        let hit = DisplayBar.hitFrame(screenFrame: left.frame)
        XCTAssertEqual(hit, CGRect(x: -1280 - 48, y: 982 - 24, width: 96, height: 24))
        let bar = DisplayBar.barFrame(inHit: hit.size)
        XCTAssertEqual(bar.size, CGSize(width: 48, height: 5))
        XCTAssertEqual(bar.midX, hit.width / 2)
        XCTAssertEqual(hit.height - bar.maxY, DisplayBar.barTop, "4 pt below the display's top edge")
        XCTAssertGreaterThan(hit.width * hit.height, bar.width * bar.height * 8, "the target is much larger than the bar")
    }

    func testTheBarNeverOutgrowsANarrowDisplay() {
        let narrow = CGRect(x: -60, y: 100, width: 60, height: 20)
        let hit = DisplayBar.hitFrame(screenFrame: narrow)
        XCTAssertEqual(hit, narrow)
        XCTAssertEqual(DisplayBar.barFrame(inHit: hit.size).width, 48)
    }

    func testAtHomeEveryOtherFlatDisplayGetsABarAndHomeKeepsItsNotch() {
        let anchors = DisplayAnchors.anchors(displays: all, host: laptop.id)
        XCTAssertEqual(anchors.map(\.display), [left.id, above.id])
        XCTAssertTrue(anchors.allSatisfy { $0.kind == .bar })
        XCTAssertEqual(anchors.first?.zone, DisplayBar.hitFrame(screenFrame: left.frame))
    }

    func testAwayFromHomeTheNotchBringsBenjiBackAndTheVisitedDisplayHasNoBar() {
        let anchors = DisplayAnchors.anchors(displays: all, host: left.id)
        XCTAssertEqual(anchors.map(\.display), [laptop.id, above.id])
        XCTAssertEqual(anchors[0].kind, .notch)
        XCTAssertEqual(anchors[0].zone, PanelGeometry.hotZone(notch: laptop.notch, screenFrame: laptop.frame))
        XCTAssertEqual(DisplayAnchors.anchor(at: CGPoint(x: 756, y: 975), in: anchors)?.display, laptop.id)
        XCTAssertEqual(DisplayAnchors.anchor(at: CGPoint(x: 740, y: 2895), in: anchors)?.display, above.id)
        XCTAssertNil(DisplayAnchors.anchor(at: CGPoint(x: 756, y: 500), in: anchors))
    }

    func testEveryFlatDisplayIncludingHomeUsesABarWhenClosed() {
        let flat = DisplayDescriptor(id: 7, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(DisplayAnchors.home([flat, left])?.id, flat.id)
        XCTAssertEqual(DisplayAnchors.home([left, laptop])?.id, laptop.id, "the notch wins over order")
        XCTAssertEqual(DisplayAnchors.anchors(displays: [flat, left], host: flat.id).map(\.display), [left.id])
        XCTAssertEqual(DisplayAnchors.anchors(displays: [flat, left], host: left.id).first?.kind, .bar)
        let closed = DisplayAnchors.anchors(displays: [flat], host: flat.id, panelClosed: true)
        XCTAssertEqual(closed.map(\.display), [flat.id], "a single flat display keeps a visible entry point")
        XCTAssertEqual(closed.first?.kind, .bar)
        XCTAssertTrue(DisplayAnchors.anchors(displays: [flat], host: flat.id, panelClosed: false).isEmpty,
                      "the entry bar leaves when the panel opens")
        XCTAssertTrue(DisplayAnchors.anchors(displays: [laptop], host: laptop.id).isEmpty, "one display: nothing new")
    }

    func testThePanelMovesOnlyWhenNothingIsHeldWhereItIs() {
        XCTAssertTrue(DisplayAnchors.mayMove(target: .closed, userOpened: false, cardWaiting: false))
        XCTAssertTrue(DisplayAnchors.mayMove(target: .peek, userOpened: false, cardWaiting: false))
        XCTAssertFalse(DisplayAnchors.mayMove(target: .open, userOpened: true, cardWaiting: false), "hover never moves an open panel")
        XCTAssertFalse(DisplayAnchors.mayMove(target: .card, userOpened: false, cardWaiting: false))
        XCTAssertTrue(DisplayAnchors.mayMove(target: .open, userOpened: true, cardWaiting: false, explicit: true))
        XCTAssertFalse(DisplayAnchors.mayMove(target: .open, userOpened: true, cardWaiting: true, explicit: true),
                       "a waiting approval or Ask card stays where it is")
    }

    // MARK: words

    func testTheAskCardAndAttachmentNameTheDisplayOnlyWhenGiven() {
        XCTAssertEqual(ScreenCapturePolicy.confirmQuestion(provider: "claude"),
                       "Send a picture of this screen to Anthropic with your message?")
        XCTAssertEqual(ScreenCapturePolicy.confirmQuestion(provider: "claude", display: "Studio Display"),
                       "Send a picture of Studio Display to Anthropic with your message?")
        XCTAssertEqual(ScreenCapturePolicy.attachmentSummary(pixelSize: CGSize(width: 1568, height: 882), provider: "openai",
                                                             display: "Studio Display"),
                       "Screen attached · Studio Display · 1568×882 · sent to OpenAI")
    }

    // MARK: setup and the arrow

    func testSetupNumbersOnlyTheRequiredSteps() {
        let none = SetupProgress(permissions: [:])
        XCTAssertEqual(SetupProgress.requiredSteps, [.accessibility, .voice, .screenRecording, .model])
        XCTAssertEqual(none.stepNumber, 1)
        let voiceDenied = SetupProgress(permissions: [.accessibility: .granted, .microphone: .denied, .speechRecognition: .granted])
        XCTAssertEqual(voiceDenied.current, .screenRecording)
        XCTAssertEqual(voiceDenied.stepNumber, 3)
        XCTAssertEqual(voiceDenied.deniedSteps, [.voice])
        let all = SetupProgress(permissions: [.accessibility: .granted, .microphone: .granted, .speechRecognition: .granted,
                                              .screenRecording: .granted], modelDone: true)
        XCTAssertNil(all.stepNumber)
    }

    func testTheArrowAimsUpLeftInsideItsBoxWithRoomForItsEdge() {
        let points = BenjiArrow.outline
        XCTAssertEqual(points.min { $0.x + $0.y < $1.x + $1.y }, BenjiArrow.tip, "the tip is the upper-left-most point")
        XCTAssertEqual(BenjiArrow.tip, PointerCompanion.tip, "the pointer companion aims with the same tip")
        // Mirror-symmetric about the diagonal: the aim is exactly up-left, not turned.
        XCTAssertEqual(BenjiArrow.rightWing, CGPoint(x: BenjiArrow.lowerWing.y, y: BenjiArrow.lowerWing.x))
        XCTAssertEqual(BenjiArrow.notch.x, BenjiArrow.notch.y)
        // A dart: the notch sits inside the triangle of tip and wings.
        let wingsMid = CGPoint(x: (BenjiArrow.rightWing.x + BenjiArrow.lowerWing.x) / 2,
                               y: (BenjiArrow.rightWing.y + BenjiArrow.lowerWing.y) / 2)
        XCTAssertGreaterThan(BenjiArrow.notch.x, BenjiArrow.tip.x)
        XCTAssertLessThan(BenjiArrow.notch.x, wingsMid.x)
        let reach = points.map { max($0.x, $0.y) }.max()! + BenjiArrow.edgeDepth + BenjiArrow.rounding / 2
        XCTAssertLessThan(reach, BenjiArrow.box - 1, "the lower edge and rounding stay inside the 20 pt box")
    }
    func testTheBarIncludesTheTopEdgeWhereThePointerStops() {
        let anchor = DisplayAnchor(display: left.id, kind: .bar, zone: DisplayBar.hitFrame(screenFrame: left.frame))
        let point = CGPoint(x: left.frame.midX, y: left.frame.maxY)
        XCTAssertEqual(DisplayAnchors.anchor(at: point, in: [anchor])?.display, left.id)
        var rest = HoverRestDetector()
        XCTAssertFalse(rest.sample(point, at: 1, zone: anchor.restZone))
        XCTAssertTrue(rest.check(at: 1 + rest.rest), "resting against the display edge must reveal the peek")
    }

}
