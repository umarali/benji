import Foundation
import XCTest
@testable import BenjiCore

/// The figure block. The shared cases in Tests/figure-cases.json are also run by
/// selftest.py against benji/figures.py: both must give the same summary, byte for byte.
final class FigureGrammarTests: XCTestCase {
    struct Case: Decodable { let name: String; let reply: String; let summary: String }

    static func cases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("figure-cases.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    func testSharedCasesMatchPython() throws {
        let cases = try Self.cases()
        XCTAssertGreaterThanOrEqual(cases.count, 30)
        for c in cases {
            XCTAssertEqual(FigureGrammar.summary(c.reply), c.summary, c.name)
        }
    }

    func testAirliner() throws {
        let reply = try Self.cases().first { $0.name == "airliner" }!.reply
        let (text, figure) = FigureGrammar.parse(reply)
        let f = try XCTUnwrap(figure)
        XCTAssertEqual(f.title, "How a plane flies")
        XCTAssertEqual(f.parts.count, 10)
        XCTAssertEqual(f.labels.map(\.part), ["cockpit window", "wing", "engine", "tail fin", "tailplane", "cabin windows"])
        XCTAssertTrue(text.hasPrefix("A plane flies") && !text.contains("```"))
        XCTAssertEqual(f.part(named: "wing")?.instances, 2)
        XCTAssertEqual(f.part(named: "cabin windows")?.instances, 32)
        XCTAssertLessThanOrEqual(f.vertices, FigureGrammar.maxVertices)
    }

    /// The worked example in the prompt (benji/prompts.py, copied into the renders' replies and
    /// checked there by selftest) parses whole in Swift too.
    func testThePromptExampleParses() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/figure-render/replies/prompt-example.txt")
        let f = try XCTUnwrap(FigureGrammar.parse(try String(contentsOf: url, encoding: .utf8)).figure)
        XCTAssertEqual(f.parts.map(\.name), ["base", "switch", "lower arm", "joint", "upper arm", "shade", "bulb"])
        XCTAssertEqual(f.labels.count, 3)
        XCTAssertEqual(f.dropped, 0)
    }

    func testAFigureBlockMidReplyKeepsTheWordsAroundIt() {
        let reply = "Wings make lift.\n```figure\n{\"parts\": [{\"kind\": \"sphere\", \"r\": 1}]}\n```\nEngines push it forward."
        let (text, figure) = FigureGrammar.parse(reply)
        XCTAssertNotNil(figure)
        XCTAssertEqual(text, "Wings make lift.\nEngines push it forward.")
        XCTAssertNil(FigureGrammar.parse(reply.replacingOccurrences(of: "```figure", with: "```json")).figure,
                     "a json block counts only at the end")
    }

    func testFailedBlockStaysInText() {
        for body in ["{parts: [}", "[1, 2]", "{\"title\": \"x\"}", "{\"parts\": [{\"kind\": \"sphere\", \"r\": NaN}]}",
                     "{\"parts\": [{\"kind\": \"sphere\", \"r\": 1e999}]}", "{\"parts\": [{\"kind\": \"blob\"}]}"] {
            let reply = "Ok.\n```figure\n\(body)\n```"
            let (text, figure) = FigureGrammar.parse(reply)
            XCTAssertNil(figure, body)
            XCTAssertEqual(text, reply, body)
        }
    }

    func testOversizedBlockFails() {
        let body = "{\"parts\": [{\"kind\": \"sphere\", \"r\": 1}]}" + String(repeating: " ", count: FigureGrammar.maxBlockChars)
        XCTAssertNil(FigureGrammar.parse("Ok.\n```figure\n\(body)\n```").figure)
        XCTAssertNotNil(FigureGrammar.parse("Ok.\n```figure\n{\"parts\": [{\"kind\": \"sphere\", \"r\": 1}]}\n```").figure)
    }

    func testNumbersAndBooleansStayApart() throws {
        let one = try JSONDecoder().decode(JSONValue.self, from: Data("1".utf8))
        let yes = try JSONDecoder().decode(JSONValue.self, from: Data("true".utf8))
        XCTAssertEqual(one, .number(1))
        XCTAssertEqual(yes, .bool(true))
        XCTAssertNil(FigureGrammar.parse("```figure\n{\"parts\": [{\"kind\": \"sphere\", \"r\": true}]}\n```").figure)
    }

    func testCanonicalNumbers() {
        XCTAssertEqual([1.0, 0.25, -0.00004, 0.00005, -1.00005, 2.5e-5, 12.3].map(Canonical.number),
                       ["1", "0.25", "0", "0.0001", "-1.0001", "0", "12.3"])
    }

    func testRecipeIgnoresPlacementSoCopiesShareAMesh() {
        let reply = "```figure\n{\"parts\": [{\"name\": \"a\", \"kind\": \"box\", \"size\": 1, \"at\": [1, 0, 0], \"mat\": \"steel\"},"
            + " {\"name\": \"b\", \"kind\": \"box\", \"size\": [1, 1, 1], \"rot\": 30, \"mirror\": \"x\"}]}\n```"
        let f = FigureGrammar.parse(reply).figure!
        XCTAssertEqual(f.parts[0].recipe, f.parts[1].recipe)
        XCTAssertEqual(f.parts[0].recipe.canonical, "{\"bevel\":0.06,\"kind\":\"box\",\"size\":[1,1,1]}")
    }

    func testExtrudeOutlines() throws {
        XCTAssertEqual(FigurePath.pointCount("M0 0 L1 0 L1 1 Z"), 3)
        XCTAssertEqual(FigurePath.pointCount("M0 0 L1 0 L1 1 L0 0"), 3)
        XCTAssertNil(FigurePath.pointCount("M0 0 L1 0"))
        XCTAssertNil(FigurePath.pointCount("M0 0 A1 1 0 0 1 2 2 Z"))
        XCTAssertEqual(FigurePath.pointCount("m0 0 l1 0 0 1z M5 5 Q 6 6 7 5 Z"), 12)
        let curve = try XCTUnwrap(FigurePath.outlines("M0 0 L2 0 C2 2 0 2 0 0 Z"))
        XCTAssertEqual(curve[0].count, 9)
        XCTAssertEqual(curve[0][1], SIMD2(2, 0))
        XCTAssertTrue(curve[0].allSatisfy { $0.y >= 0 && $0.y <= 1.5 + 1e-9 })
    }
}
