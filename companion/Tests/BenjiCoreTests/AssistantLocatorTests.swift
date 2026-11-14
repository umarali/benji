import Foundation
import XCTest
@testable import BenjiCore

final class AssistantLocatorTests: XCTestCase {
    private let bundle = URL(fileURLWithPath: "/work/benji/companion/Benji.app")

    private func resolve(env: [String: String] = [:], executable: String? = nil, cwd: String = "/somewhere/else",
                         roots: Set<String>) -> String {
        AssistantLocator.resolve(
            environment: env, bundleURL: bundle, executableURL: executable.map { URL(fileURLWithPath: $0) },
            currentDirectory: cwd, fileExists: { roots.contains($0) })
    }

    func testTheEnvironmentOverrideWins() {
        XCTAssertEqual(resolve(env: ["BENJI_DIR": "/opt/benji"], roots: ["/work/benji/benji/__main__.py"]), "/opt/benji")
    }

    func testAnEmptyOverrideIsIgnored() {
        XCTAssertEqual(resolve(env: ["BENJI_DIR": ""], roots: ["/work/benji/benji/__main__.py"]), "/work/benji")
    }

    func testTheRepositoryIsFoundFromTheBundle() {
        XCTAssertEqual(resolve(roots: ["/work/benji/benji/__main__.py"]), "/work/benji")
    }

    func testTheRepositoryIsFoundFromTheExecutableWhenTheBundleIsMovedAway() {
        let moved = AssistantLocator.resolve(
            environment: [:], bundleURL: URL(fileURLWithPath: "/Applications/Benji.app"),
            executableURL: URL(fileURLWithPath: "/work/benji/companion/.build/release/BenjiApp"),
            currentDirectory: "/", fileExists: { $0 == "/work/benji/benji/__main__.py" })
        XCTAssertEqual(moved, "/work/benji")
    }

    func testTheWorkingDirectoryIsTheLastResort() {
        let found = AssistantLocator.resolve(
            environment: [:], bundleURL: URL(fileURLWithPath: "/Applications/Benji.app"), executableURL: nil,
            currentDirectory: "/src/benji/companion", fileExists: { $0 == "/src/benji/benji/__main__.py" })
        XCTAssertEqual(found, "/src/benji")
    }

    func testNothingFoundNamesTheFolderAboveTheBundle() {
        XCTAssertEqual(resolve(roots: []), "/work/benji")
    }

    func testNoMachineSpecificHomeIsBakedIn() {
        let none = AssistantLocator.resolve(
            environment: [:], bundleURL: URL(fileURLWithPath: "/Applications/Benji.app"), executableURL: nil,
            currentDirectory: "/", fileExists: { _ in false })
        XCTAssertFalse(none.contains("/Users/"))
    }
}
