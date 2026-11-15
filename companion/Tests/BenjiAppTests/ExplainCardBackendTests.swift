import AppKit
import XCTest
@testable import BenjiApp
import BenjiCore

/// The explanation card hook: on by default it tells the engine, takes the card block out
/// of answers (the panel and the voice never see it) and hands the card, with what the reply
/// points at, to the stage; a chip's words go out as a typed message. No window is made here.
final class ExplainCardBackendTests: XCTestCase {
    let reply = "Three states.\n```card\n{\"title\":\"States\",\"layout\":\"flow\",\"items\":[\"Listen\",\"Think\",\"Speak\"]}\n```"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: ExplainCardStage.defaultsKey)
        unsetenv(ExplainCardBackend.engineFlag)
    }

    func testOnByDefaultAndTheEngineIsTold() {
        UserDefaults.standard.removeObject(forKey: ExplainCardStage.defaultsKey)
        let fake = FakeBackend()
        XCTAssertFalse(ExplainCardBackend.wrap(fake) === fake)
        XCTAssertEqual(ProcessInfo.processInfo.environment[ExplainCardBackend.engineFlag], "1")
    }

    func testTurnedOffTheBackendIsUntouched() {
        UserDefaults.standard.set(false, forKey: ExplainCardStage.defaultsKey)
        unsetenv(ExplainCardBackend.engineFlag)
        let fake = FakeBackend()
        XCTAssertTrue(ExplainCardBackend.wrap(fake) === fake)
        XCTAssertNil(ProcessInfo.processInfo.environment[ExplainCardBackend.engineFlag])
    }

    /// Records what the hook asks of the stage.
    final class FakeStage: ExplainCardShowing {
        var opened: [(script: CardScript, targets: [PointingTarget])] = []
        var updates: [CardScript] = []
        var withdrawn = 0
        var hurried = 0
        var onOpen: (() -> Void)?
        func open(_ script: CardScript, run: Int, busy: ExplainBusyScreen?, targets: [PointingTarget]) {
            XCTAssertNil(busy, "no screenshot, no busy map")
            opened.append((script, targets))
            onOpen?()
        }
        func update(_ script: CardScript, run: Int) { updates.append(script) }
        func withdraw(run: Int) { withdrawn += 1 }
        func hurry(run: Int) { hurried += 1 }
    }

    /// The hooks made in a test, kept alive to its end (the backend holds its hook weakly).
    var kept: [AnyObject] = []

    func hook(_ stage: FakeStage) -> (FakeBackend, ExplainCardBackend, () -> [BackendEvent]) {
        let fake = FakeBackend()
        let wrapped = ExplainCardBackend(fake, stage: stage)
        kept += [wrapped, stage]
        var clock = 0.0
        wrapped.now = { clock += 0.1; return clock }
        var seen: [BackendEvent] = []
        wrapped.onEvent = { _, e in seen.append(e) }
        return (fake, wrapped, { seen })
    }

    func waitForOpen(_ stage: FakeStage, count: Int = 1) {
        let done = expectation(description: "opened")
        done.expectedFulfillmentCount = count
        stage.onOpen = { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    let open = ExplainCardLine.open(ExplainCardHeader(title: "Letter", layout: .flow))
    func item(_ label: String) -> ExplainCardLine { .item(.init(label: label)) }

    /// The engine's card events open the card at once and grow it; they never reach the panel.
    func testStreamedCardLinesOpenTheCardAndGrowIt() {
        let stage = FakeStage()
        let (fake, _, seen) = hook(stage)
        fake.onEvent?(1, .cardLine(open, at: 0))
        XCTAssertTrue(stage.opened.isEmpty, "a first line waits for the first words: is the reply streaming?")
        fake.onEvent?(1, .delta("You drop it in.\n"))
        waitForOpen(stage)
        XCTAssertEqual(stage.opened[0].script.draft?.items.count, 0, "open with no body yet")
        fake.onEvent?(1, .cardLine(item("Box"), at: 16))
        fake.onEvent?(1, .delta("A van takes it.\n"))
        fake.onEvent?(1, .cardLine(item("Van"), at: 32))
        fake.onEvent?(1, .cardLine(.chips(["Why?"]), at: 32))
        fake.onEvent?(1, .cardEnd)
        fake.onEvent?(1, .pointedAnswer(text: "You drop it in.\nA van takes it.\n", targets: []))
        XCTAssertEqual(seen(), [.delta("You drop it in.\n"), .delta("A van takes it.\n"),
                                .pointedAnswer(text: "You drop it in.\nA van takes it.\n", targets: [])])
        let last = stage.updates.last!
        XCTAssertEqual(last.owners, [0, 1])
        XCTAssertEqual(last.draft?.chips, ["Why?"])
        XCTAssertTrue(last.ended)
        XCTAssertEqual(stage.opened.count, 1)
    }

    /// An answer that still holds its card lines: they are read as if streamed.
    func testAnAnswerWithCardLinesIsReadWhole() {
        let stage = FakeStage()
        let (fake, _, seen) = hook(stage)
        let raw = "card: {\"title\":\"Letter\"}\nYou drop it in.\nitem: {\"label\":\"Box\"}\nchips: [\"Why?\"]\n[POINT:10,20:Box]"
        fake.onEvent?(1, .answer(raw))
        waitForOpen(stage)
        XCTAssertEqual(seen(), [.answer("You drop it in.\n[POINT:10,20:Box]")])
        XCTAssertEqual(stage.opened[0].script.owners, [0])
        XCTAssertTrue(stage.opened[0].script.ended)
    }

    /// Streaming off: the lines come just before the answer, each with its place in the words.
    func testLinesThatComeWithTheAnswerKeepTheirSentences() {
        let stage = FakeStage()
        let (fake, _, seen) = hook(stage)
        fake.onEvent?(1, .cardLine(open, at: 0))
        fake.onEvent?(1, .cardLine(item("Box"), at: 16))
        fake.onEvent?(1, .cardLine(item("Van"), at: 32))
        fake.onEvent?(1, .cardEnd)
        XCTAssertTrue(stage.opened.isEmpty, "held for the answer")
        fake.onEvent?(1, .pointedAnswer(text: "You drop it in.\nA van takes it.\n", targets: []))
        waitForOpen(stage)
        XCTAssertEqual(stage.opened[0].script.owners, [0, 1])
        XCTAssertEqual(seen(), [.pointedAnswer(text: "You drop it in.\nA van takes it.\n", targets: [])])
    }

    /// A card written as a fenced block, the form saved replies may hold, still makes a card, with
    /// what the reply points at.
    func testAFencedBlockIsStillACard() {
        let stage = FakeStage()
        let (fake, _, seen) = hook(stage)
        let save = PointingTarget(shape: .point(x: 10, y: 20), label: "Save")
        fake.onEvent?(1, .pointedAnswer(text: reply, targets: [save]))
        waitForOpen(stage)
        fake.onEvent?(2, .answer("No card here."))
        fake.onEvent?(3, .answer("Broken.\n```card\n{oops\n```"))
        XCTAssertEqual(seen(), [.pointedAnswer(text: "Three states.", targets: [save]), .answer("No card here."),
                                .answer("Broken.\n```card\n{oops\n```")])
        XCTAssertEqual(stage.opened[0].script.draft?.items.map(\.label), ["Listen", "Think", "Speak"])
        XCTAssertEqual(stage.opened[0].script.owners, [nil, nil, nil], "drawn at once, as before")
        XCTAssertEqual(stage.opened[0].targets, [save])
    }

    func testAResetTakesTheCardBack() {
        let stage = FakeStage()
        let (fake, _, _) = hook(stage)
        fake.onEvent?(1, .cardLine(open, at: 0))
        fake.onEvent?(1, .delta("Let me look.\n"))
        fake.onEvent?(1, .deltaReset)
        XCTAssertEqual(stage.withdrawn, 1)
        fake.onEvent?(1, .pointedAnswer(text: "Found two files.", targets: []))
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertTrue(stage.opened.isEmpty, "the withdrawn card never lands")
    }

    /// Cut off (or cancelled): what isn't drawn is drawn now, and nothing of that reply comes later.
    func testCutOffHurriesTheCardAndDropsLaterLines() {
        let stage = FakeStage()
        let (fake, wrapped, seen) = hook(stage)
        fake.onEvent?(1, .cardLine(open, at: 0))
        fake.onEvent?(1, .delta("One.\n"))
        waitForOpen(stage)
        fake.onEvent?(1, .cardLine(item("A"), at: 5))
        wrapped.cutOff(reply: "One. … [cut off]", running: true)
        XCTAssertEqual(stage.hurried, 1)
        let updates = stage.updates.count
        fake.onEvent?(1, .cardLine(item("B"), at: 10))
        fake.onEvent?(1, .delta("Two.\n"))
        XCTAssertEqual(stage.updates.count, updates, "a late line never reaches the card")
        XCTAssertEqual(seen().last, .delta("Two.\n"), "the panel's own events still pass")
        fake.onEvent?(2, .cardLine(open, at: 0))
        fake.onEvent?(2, .delta("Again.\n"))
        waitForOpen(stage)
        wrapped.cancel()
        XCTAssertEqual(stage.hurried, 2)
        XCTAssertEqual(fake.cancels, 2, "both reach the engine (a running cut-off cancels, by default)")
    }

    /// A new reply starts while the last card still waits on its voice: that card is finished now.
    func testANewReplyFinishesTheLastCard() {
        let stage = FakeStage()
        let (fake, _, _) = hook(stage)
        fake.onEvent?(1, .cardLine(open, at: 0))
        fake.onEvent?(1, .delta("Hi.\n"))
        waitForOpen(stage)
        fake.onEvent?(2, .delta("Hello."))
        XCTAssertEqual(stage.hurried, 1)
    }

    func testAFigureBlockStillReachesTheFigureWrapperOutside() {
        let fake = FakeBackend()
        let stage = FakeStage()
        stage.onOpen = { XCTFail("a figure is not a card") }
        let cards = ExplainCardBackend(fake, stage: stage)
        let figures = FigureStageBackend(cards, stage: { nil })
        var seen: [BackendEvent] = []
        figures.onEvent = { _, e in seen.append(e) }
        fake.onEvent?(1, .answer("A ball.\n```figure\n{\"title\":\"Ball\",\"parts\":[{\"name\":\"b\",\"kind\":\"sphere\",\"r\":1}]}\n```"))
        XCTAssertEqual(seen, [.answer("A ball.")])
    }

    func testEverythingElsePassesThrough() {
        let fake = FakeBackend()
        let wrapped = ExplainCardBackend(fake, stage: FakeStage())
        var finished: [Int32] = []
        wrapped.onFinished = { _, code in finished.append(code) }
        wrapped.start(run: 3, task: "t", imagePath: nil, memory: ConversationMemory(), allowPointing: false, spoken: true, screen: nil)
        wrapped.resolveApproval(false)
        wrapped.cancel()
        fake.finish(0)
        XCTAssertEqual(fake.starts.map(\.run), [3])
        XCTAssertEqual(fake.approvals, [false])
        XCTAssertEqual(fake.cancels, 1)
        XCTAssertEqual(finished, [0])
    }

    /// A screenshot of half text, half flat colour: the map finds the text side busy.
    func testScreenshotIsMeasuredForBusySpace() throws {
        let screen = try XCTUnwrap(NSScreen.main, "needs a display")
        let size = screen.frame.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.4, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        NSColor.white.setFill()
        CGRect(x: 0, y: 0, width: size.width / 2, height: size.height).fill()
        let line = String(repeating: "Words on a page, line after line. ", count: 20)
        var y: CGFloat = 10
        while y < size.height {
            (line as NSString).draw(in: CGRect(x: 10, y: y, width: size.width / 2 - 20, height: 18),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
            y += 20
        }
        NSGraphicsContext.restoreGraphicsState()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("benji-card-test-\(UUID().uuidString).png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let measured = try XCTUnwrap(ExplainBusyScreen.measure(path: url.path, screen: screen))
        let left = CGRect(x: 40, y: 40, width: size.width / 2 - 140, height: size.height - 80)
        let right = CGRect(x: size.width / 2 + 100, y: 40, width: size.width / 2 - 140, height: size.height - 80)
        XCTAssertGreaterThan(measured.map.coverage(of: left), 0.8)
        XCTAssertEqual(measured.map.coverage(of: right), 0, accuracy: 0.01)
        XCTAssertEqual(measured.pixelSize, CGSize(width: Int(size.width), height: Int(size.height)))
    }
}

/// A chip's words are sent like a typed message; while a turn runs they wait in the composer.
final class CompanionModelChipTests: XCTestCase {
    func testChipSendsItsWordsAsTheNextMessage() {
        let backend = FakeBackend()
        let suite = UserDefaults(suiteName: "benji-app-tests-\(UUID().uuidString)")!
        suite.set(ScreenMode.off.rawValue, forKey: ScreenModeState.defaultsKey)
        let model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: suite))
        model.ask("  Can I interrupt it? ")
        XCTAssertEqual(backend.starts.map(\.task), ["Can I interrupt it?"])
        XCTAssertEqual(model.composerText, "")
        model.ask("How does it know I'm done?")
        XCTAssertEqual(backend.starts.count, 1, "a turn is running")
        XCTAssertEqual(model.composerText, "How does it know I'm done?")
        model.ask("   ")
        XCTAssertEqual(model.composerText, "How does it know I'm done?")
    }
}
