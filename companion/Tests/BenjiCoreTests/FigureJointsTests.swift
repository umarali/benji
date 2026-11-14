import Foundation
import XCTest
@testable import BenjiCore

/// Parts that touch nothing (D-108, after the live evals).
final class FigureJointsTests: XCTestCase {
    static let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/impl-notes/chilly-figures")

    /// Every reply the real model wrote in the live evals (committed in docs), by name.
    static func liveReplies() throws -> [(String, String)] {
        var out: [(String, String)] = []
        let fm = FileManager.default
        for dir in try fm.contentsOfDirectory(atPath: docs.path).filter({ $0.hasPrefix("live-eval-") }).sorted() {
            for sub in ["", "replies"] {
                let d = docs.appendingPathComponent(dir).appendingPathComponent(sub)
                guard let files = try? fm.contentsOfDirectory(atPath: d.path) else { continue }
                for f in files.sorted() where f.hasSuffix(".txt") {
                    out.append(("\(dir)/\(f)", try String(contentsOf: d.appendingPathComponent(f), encoding: .utf8)))
                }
            }
        }
        return out
    }

    static func fig(_ json: String) -> (Figure, [String: FigureMesh]) {
        let f = FigureGrammar.parse("```figure\n" + json + "\n```").figure!
        return (f, Dictionary(uniqueKeysWithValues: f.parts.map { ($0.name, FigureMesh.build($0.recipe)) }))
    }

    func testAGapIsFoundAndClosed() {
        let (f, m) = Self.fig(#"{"parts": [{"name": "seat", "kind": "box", "size": [2, 0.2, 2], "bevel": 0},"#
            + #" {"name": "back", "kind": "box", "size": [2, 2, 0.2], "at": [0, 2, -1], "bevel": 0}]}"#)
        let loose = FigureJoints.loose(f, meshes: m)
        XCTAssertEqual(loose.map(\.parts), [["back"]])
        XCTAssertEqual(loose[0].gap, 0.9, accuracy: 1e-6)   // the back's bottom at 1.0, the seat's top at 0.1
        XCTAssertEqual(loose[0].shift.y, -0.9, accuracy: 1e-6)
        let (full, moved) = FigureJoints.closingGaps(f, meshes: m)
        XCTAssertEqual(moved.count, 1)
        XCTAssertTrue(FigureJoints.loose(f, meshes: m, transforms: full).isEmpty)
        let back = FigureJoints.pieces(f, meshes: m, transforms: full).first { $0.part == "back" }!
        XCTAssertLessThan(back.lo.y, 0.1, "sunk a little into the seat")
        XCTAssertGreaterThan(back.lo.y, 0.0)
    }

    /// Two groups of the same size: the one written first is the object, every time.
    func testATieIsSettledByPartOrder() {
        let (f, m) = Self.fig(#"{"parts": [{"name": "left", "kind": "box", "size": 1}, {"name": "right", "kind": "box", "size": 1, "at": [3, 0, 0]}]}"#)
        for _ in 0..<20 { XCTAssertEqual(FigureJoints.loose(f, meshes: m).map(\.parts), [["right"]]) }
    }

    func testAMirroredPairMovesSymmetrically() {
        let (f, m) = Self.fig(#"{"parts": [{"name": "body", "kind": "capsule", "r": 0.5, "h": 6, "axis": "z"},"#
            + #" {"name": "wing", "kind": "box", "size": [3, 0.1, 1], "at": [3, 0, 0], "mirror": "x"}]}"#)
        XCTAssertEqual(FigureJoints.loose(f, meshes: m).count, 2)
        let (full, _) = FigureJoints.closingGaps(f, meshes: m)
        let wings = FigureJoints.pieces(f, meshes: m, transforms: full).filter { $0.part == "wing" }
        XCTAssertEqual(wings.count, 2)
        XCTAssertEqual(wings[0].lo.x, -wings[1].hi.x, accuracy: 1e-9)
        XCTAssertLessThan(min(wings[0].lo.x, abs(wings[1].hi.x)), 0.5, "each wing reaches the body")
    }

    func testPartsThatTouchAreLeftAlone() throws {
        let (f, m) = Self.fig(#"{"parts": [{"name": "a", "kind": "box", "size": 1}, {"name": "b", "kind": "box", "size": 1, "at": [1, 0, 0]}]}"#)
        XCTAssertTrue(FigureJoints.loose(f, meshes: m).isEmpty)
        let (full, moved) = FigureJoints.closingGaps(f, meshes: m)
        XCTAssertTrue(moved.isEmpty)
        XCTAssertEqual(full, FigurePlacement.fullTransforms(f))
    }

    func testTheHandWrittenFiguresNeedNoMoves() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/figure-render/replies")
        for name in ["airliner", "house", "jet-engine", "prompt-example"] {
            let f = FigureGrammar.parse(try String(contentsOf: dir.appendingPathComponent(name + ".txt"), encoding: .utf8)).figure!
            let m = Dictionary(uniqueKeysWithValues: f.parts.map { ($0.name, FigureMesh.build($0.recipe)) })
            XCTAssertEqual(FigureJoints.loose(f, meshes: m).map(\.parts), [], name)
        }
    }

    func testSurveyOfTheLiveReplies() throws {
        let replies = try Self.liveReplies()
        XCTAssertGreaterThanOrEqual(replies.count, 90)
        var flagged = 0
        for (name, text) in replies {
            guard let f = FigureGrammar.parse(text).figure else { continue }
            let meshes = Dictionary(uniqueKeysWithValues: f.parts.map { ($0.name, FigureMesh.build($0.recipe)) })
            let loose = FigureJoints.loose(f, meshes: meshes)
            if loose.isEmpty { continue }
            flagged += 1
            let (full, _) = FigureJoints.closingGaps(f, meshes: meshes)
            XCTAssertEqual(FigureJoints.loose(f, meshes: meshes, transforms: full).map(\.parts), [], "\(name) after closing")
            for l in loose {
                print(String(format: "[joints] %@: %@ (%d copies) gap %.2f = %.0f%% of radius", name, l.parts.joined(separator: ", "),
                             l.pieces.count, l.gap, l.share * 100))
            }
        }
        print("[joints] \(flagged) of \(replies.count) live figures have loose parts")
        XCTAssertEqual(flagged, 26, "the survey of 2026-10-31 (21, then 26 with the low-effort runs): update with the replies if more are added")
    }
}
