import Foundation
import XCTest
@testable import BenjiApp
import BenjiCore

/// Framing: a figure fills the card at its own view and never runs
/// off the stage or into the label margins while it turns. A SceneKit scene is built and projected
/// through its camera; nothing is rendered and no window is made.
final class FigureFramingTests: XCTestCase {
    static let stage = FigureCardDrawing.stageRect(in: CGRect(origin: .zero, size: FigureCardDrawing.size))

    static func figure(_ file: String) throws -> Figure {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/figure-render/replies/\(file).txt")
        return try XCTUnwrap(FigureGrammar.parse(try String(contentsOf: url, encoding: .utf8)).figure)
    }

    /// The projected box of every part, in stage points, `seconds` after the figure settled.
    static func box(_ fs: FigureScene, after seconds: Double) -> CGRect {
        fs.apply(at: fs.timeline.settled + seconds)
        let (_, model) = fs.labelAnchors(fs.projector(viewSize: stage.size, live: false), viewSize: stage.size)
        return model.insetBy(dx: 6, dy: 6)   // labelAnchors pads the box by 6
    }

    @discardableResult
    func check(_ figure: Figure, minimumFill: CGFloat, file: StaticString = #filePath, line: UInt = #line) -> FigureScene {
        let fs = FigureScene(figure: figure, meshes: FigureScene.meshes(for: figure, cache: FigureMeshCache()),
                             aspect: Double(Self.stage.width / Self.stage.height))
        let card = CGRect(origin: .zero, size: Self.stage.size)
        // The model's share of the stage: the label columns take 24% of the width each side.
        let room = CGSize(width: card.width * (figure.labels.isEmpty ? 0.92 : 0.52), height: card.height * 0.84)
        let start = Self.box(fs, after: 0)
        let fill = max(start.width / room.width, start.height / room.height)
        print(String(format: "[framing] %@: fills %.0f%% of its room at its own view, %.2f× the worst-angle framing",
                     figure.title, fill * 100, fs.framingGain))
        XCTAssertGreaterThanOrEqual(fill, minimumFill, "fills its room at its own view: \(figure.title)", file: file, line: line)
        // A full idle turn, every 2.5 degrees (finer than the framing's own 7.5° samples): never off
        // the stage.
        for k in 0..<144 {
            let b = Self.box(fs, after: Double(k) / 144 * FigureTimeline.idleRevolution)
            XCTAssertTrue(card.insetBy(dx: -1, dy: -1).contains(b), "\(figure.title) at \(Double(k) * 2.5)°: \(b)", file: file, line: line)
        }
        return fs
    }

    func testTheJetEngineFillsTheCardAndStaysOnIt() throws {
        check(try Self.figure("jet-engine"), minimumFill: 0.85)
    }

    /// Three jet engines a real model wrote (kept in Tests/Fixtures): long, thin and viewed
    /// nearly end-on, they come out small unless framed at their own view. Measured: 1.27-1.35x larger than the
    /// worst-angle framing, 59-64% of their room (the rest is the end-on view the model chose).
    func testTheModelsJetEnginesFillTheirRoom() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/figure-replies/live-eval-spread/replies")
        for n in 1...3 {
            let text = try String(contentsOf: dir.appendingPathComponent("jet-engine-\(n).txt"), encoding: .utf8)
            let fs = check(try XCTUnwrap(FigureGrammar.parse(text).figure), minimumFill: 0.55)
            XCTAssertGreaterThanOrEqual(fs.framingGain, 1.2, "jet-engine-\(n)")
        }
    }

    func testTheOtherHandWrittenFiguresStayOnTheCard() throws {
        for name in ["airliner", "house", "prompt-example"] { check(try Self.figure(name), minimumFill: 0.6) }
    }

    /// A long, thin thing seen at three-quarters: framed for its side-on length, it would come
    /// out much smaller than its room.
    func testALongThinThingFillsTheCardAtItsOwnView() {
        let reply = "```figure\n{\"title\": \"Rod\", \"parts\": [{\"name\": \"rod\", \"kind\": \"capsule\", \"r\": 0.4, \"h\": 10, \"axis\": \"z\"}],"
            + " \"labels\": [{\"part\": \"rod\", \"text\": \"Rod\"}], \"view\": {\"turn\": 35, \"tilt\": 20}}\n```"
        check(FigureGrammar.parse(reply).figure!, minimumFill: 0.6)
    }

    /// The card prepares a figure off the main thread (meshes, gaps closed, bounds) and builds the
    /// scene from that on the main thread: the result is the scene built directly.
    func testAPreparedSceneIsTheDirectOne() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/figure-replies/live-eval-3/airliner.txt")
        let figure = try XCTUnwrap(FigureGrammar.parse(try String(contentsOf: url, encoding: .utf8)).figure)
        var prepared: FigureScene.Prepared?
        let done = expectation(description: "prepared off the main thread")
        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertFalse(Thread.isMainThread)
            prepared = FigureScene.prepare(figure, cache: FigureMeshCache())
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        let aspect = Double(Self.stage.width / Self.stage.height)
        let viaPrepare = FigureScene(prepared: try XCTUnwrap(prepared), aspect: aspect)
        let direct = FigureScene(figure: figure, meshes: FigureScene.meshes(for: figure, cache: FigureMeshCache()), aspect: aspect)
        XCTAssertEqual(viaPrepare.joined.map(\.parts), direct.joined.map(\.parts))
        XCTAssertFalse(viaPrepare.joined.isEmpty, "this plane's wings were off its body")
        XCTAssertEqual(viaPrepare.radius, direct.radius)
        XCTAssertEqual(viaPrepare.centre, direct.centre)
        for t in [0.0, 10, 40] {
            XCTAssertEqual(Self.box(viaPrepare, after: t), Self.box(direct, after: t))
        }
    }
}
