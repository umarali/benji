import XCTest
@testable import BenjiCore

final class EngineLaunchTests: XCTestCase {
    func testSourceEntryDescriptionsPreserveArgumentsAndWorkingDirectory() throws {
        XCTAssertFalse(EngineLaunch.isDistribution)
        let root = "/private/tmp/source's space"
        for entry in [EngineLaunch.Entry.engine, .remote, .modelSetup] {
            let launch = try EngineLaunch.make(entry: entry, arguments: ["one word", "'literal'"], sourceDirectory: root,
                                               environment: ["FIXTURE": "kept", "PYTHONPATH": "source-keeps-this"])
            XCTAssertEqual(launch.executable.path, "/bin/zsh")
            XCTAssertEqual(launch.directory.path, root)
            XCTAssertEqual(Array(launch.arguments.suffix(3)), ["benji", "one word", "'literal'"])
            XCTAssertEqual(launch.arguments[0], "-lc")
            XCTAssertTrue(launch.arguments[1].hasPrefix("cd \"$BENJI_DIR\" && exec python3"))
            XCTAssertTrue(launch.arguments[1].hasSuffix(" \"$@\""))
            XCTAssertEqual(launch.environment["BENJI_DIR"], root)
            XCTAssertEqual(launch.environment["FIXTURE"], "kept")
            XCTAssertEqual(launch.environment["PYTHONPATH"], "source-keeps-this")
        }
        let host = try EngineLaunch.make(entry: .nativeHost, arguments: ["origin"], sourceDirectory: root, environment: [:])
        XCTAssertEqual(host.executable.path, "/usr/bin/env")
        XCTAssertEqual(host.arguments, ["python3", "-I", root + "/benji/browser_host.py", "origin"])
        XCTAssertThrowsError(try EngineLaunch.make(entry: .tts, sourceDirectory: root, environment: [:]))
        let tts = try EngineLaunch.make(entry: .tts, arguments: ["literal text"], sourceDirectory: root, environment: [:], optionalPython: "/fixture/python")
        XCTAssertEqual(tts.executable.path, "/fixture/python")
        XCTAssertEqual(tts.arguments, ["-m", "benji", "--tts", "literal text"])
    }

    func testSourceEngineReallyLaunchesVersion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), output = Pipe()
        let launch = try EngineLaunch.make(entry: .engine, arguments: ["--version"], sourceDirectory: root.path,
                                           environment: ProcessInfo.processInfo.environment)
        launch.apply(to: process); process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Benji 0.1.0"))
    }
}
