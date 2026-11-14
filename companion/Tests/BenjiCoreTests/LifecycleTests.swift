import XCTest
@testable import BenjiCore

private final class FakeLoginItem: LoginItemService {
    var status: LoginItemStatus
    var refuse = false
    private(set) var registers = 0, unregisters = 0
    init(_ status: LoginItemStatus) { self.status = status }
    func register() throws {
        if refuse { throw NSError(domain: "fake", code: 1) }
        registers += 1
        status = .enabled
    }
    func unregister() throws {
        if refuse { throw NSError(domain: "fake", code: 1) }
        unregisters += 1
        status = .disabled
    }
}

final class LifecycleTests: XCTestCase {
    // MARK: open at login

    func testOpenAtLoginIsOffUntilTheUserSwitchesItOn() {
        let service = FakeLoginItem(.disabled)
        XCTAssertFalse(OpenAtLogin.isOn(service.status))
        XCTAssertEqual(service.registers, 0, "nothing registers on its own")
        let result = OpenAtLogin.set(true, service: service)
        XCTAssertEqual(result.status, .enabled)
        XCTAssertFalse(result.failed)
        XCTAssertEqual(service.registers, 1)
        XCTAssertEqual(OpenAtLogin.set(true, service: service).status, .enabled)
        XCTAssertEqual(service.registers, 1, "switching on twice registers once")
        XCTAssertEqual(OpenAtLogin.set(false, service: service).status, .disabled)
        XCTAssertEqual(service.unregisters, 1)
        _ = OpenAtLogin.set(false, service: service)
        XCTAssertEqual(service.unregisters, 1)
    }

    func testTheSwitchShowsWhatTheSystemSaysAndSaysSoWhenItRefuses() {
        XCTAssertTrue(OpenAtLogin.isOn(.enabled))
        XCTAssertTrue(OpenAtLogin.isOn(.needsApproval), "registered, waiting for the user's OK in System Settings")
        XCTAssertFalse(OpenAtLogin.isOn(.unavailable))
        let service = FakeLoginItem(.disabled)
        service.refuse = true
        let result = OpenAtLogin.set(true, service: service)
        XCTAssertTrue(result.failed)
        XCTAssertEqual(result.status, .disabled)
        XCTAssertTrue(OpenAtLogin.caption(.disabled, failed: true).contains("Login Items"))
        for status in [LoginItemStatus.enabled, .disabled, .needsApproval, .unavailable] {
            XCTAssertFalse(OpenAtLogin.caption(status).isEmpty)
        }
    }

    // MARK: permissions

    func testTheAskAtTheMomentOfNeedIsOneLineAndComesOncePerLaunch() {
        var asks = PermissionAsks()
        XCTAssertNil(asks.ask(.screenToLook, granted: true))
        let first = asks.ask(.screenToLook, granted: false)
        XCTAssertEqual(first, .screenToLook)
        XCTAssertNil(asks.ask(.screenToLook, granted: false), "not again this launch")
        XCTAssertEqual(asks.ask(.microphoneToHear, granted: false), .microphoneToHear)
        for need in [PermissionNeed.screenToLook, .microphoneToHear, .speechToTranscribe] {
            XCTAssertFalse(need.line.contains("\n"))
            XCTAssertLessThan(need.line.count, 120, "one line")
            XCTAssertTrue(need.line.contains(need.permission.title), need.line)
            XCTAssertTrue(need.buttonTitle.contains(need.permission.title))
        }
    }

    func testTheLaunchLineSaysOnlyWhatMacOSTookAway() {
        let before: [String: Bool] = ["microphone": true, "speechRecognition": true, "accessibility": true, "screenRecording": true]
        XCTAssertNil(GrantChanges.launchLine(lost: GrantChanges.lost(previous: nil, now: [.screenRecording: false])), "first launch")
        XCTAssertTrue(GrantChanges.lost(previous: before, now: [.microphone: true, .speechRecognition: true, .accessibility: true, .screenRecording: true]).isEmpty)
        let lost = GrantChanges.lost(previous: before, now: [.microphone: true, .speechRecognition: true, .accessibility: false, .screenRecording: false])
        XCTAssertEqual(lost, [.accessibility, .screenRecording])
        let line = GrantChanges.launchLine(lost: lost)!
        XCTAssertTrue(line.contains("Accessibility and Screen Recording") && line.hasPrefix("macOS turned off"))
        XCTAssertEqual(GrantChanges.launchLine(lost: [.microphone])!.contains("Microphone for Benji"), true)
        // A grant that was never on, or that came on, is not mentioned.
        XCTAssertTrue(GrantChanges.lost(previous: ["microphone": false], now: [.microphone: false]).isEmpty)
        XCTAssertTrue(GrantChanges.lost(previous: ["microphone": false], now: [.microphone: true]).isEmpty)
        // A permission macOS can't report this time is not "lost".
        XCTAssertTrue(GrantChanges.lost(previous: before, now: [:]).isEmpty)
        XCTAssertEqual(GrantChanges.encode([.microphone: true, .accessibility: false]), ["microphone": true, "accessibility": false])
    }

    // MARK: relaunch

    private func run(_ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = arguments
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    func testTheRelaunchHelperWaitsForTheOldProcessToExitBeforeOpening() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("benji-relaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The opener is a script that records the time it ran, and what it was given (a path with a space and a quote).
        let marker = dir.appendingPathComponent("opened.txt")
        let opener = dir.appendingPathComponent("opener.sh")
        try "#!/bin/sh\necho \"$1\" > '\(marker.path)'\n".write(to: opener, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)

        // The "old process": a child that lives for 1.5 s.
        let old = Process()
        old.executableURL = URL(fileURLWithPath: "/bin/sleep")
        old.arguments = ["1.5"]
        try old.run()
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = RelaunchHelper.arguments(pid: old.processIdentifier, target: "/Apps/My \"Benji\".app", opener: opener.path, waitSeconds: 10)
        try helper.run()

        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(old.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "it must not open while the old process is alive")
        old.waitUntilExit()
        helper.waitUntilExit()
        XCTAssertEqual(helper.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "/Apps/My \"Benji\".app\n", "opened once the old process was gone, with the path intact")
    }

    func testTheRelaunchHelperGivesUpWaitingAfterTheLimit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("benji-relaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("opened.txt")
        let opener = dir.appendingPathComponent("opener.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: opener, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
        let stuck = Process()
        stuck.executableURL = URL(fileURLWithPath: "/bin/sleep")
        stuck.arguments = ["30"]
        try stuck.run()
        defer { stuck.terminate() }
        let started = Date()
        XCTAssertEqual(try run(RelaunchHelper.arguments(pid: stuck.processIdentifier, target: "x", opener: opener.path, waitSeconds: 1)), 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "a process that won't exit doesn't keep the user waiting forever")
    }

    func testTheHelperTakesItsValuesAsParametersNotAsScript() {
        let args = RelaunchHelper.arguments(pid: 123, target: "/tmp/$(touch pwned).app")
        XCTAssertFalse(args[1].contains("pwned"))
        XCTAssertTrue(args.contains("/tmp/$(touch pwned).app"))
        XCTAssertEqual(args[0], "-c")
    }

    // MARK: the settings page starts with everything of this change off

    func testTheSettingsSnapshotStartsWithLoginCuesAndTheKeyMoveOff() {
        let s = SettingsSnapshot()
        XCTAssertFalse(s.openAtLogin)
        XCTAssertFalse(s.cuesOn)
        XCTAssertEqual(s.keyStorage, .none)
        XCTAssertNil(s.keyMoveNote)
        XCTAssertFalse(KeyStorageStatus.none.offersMove)
    }

    func testTheKeyMoveWordsNeverHoldAKey() {
        let outcomes: [KeyMigration.Outcome] = [.moved(count: 1), .moved(count: 3), .nothingToMove, .keychainFailed(.denied),
                                                .keychainFailed(.unavailable), .keychainFailed(.failed), .fileNotCleaned]
        for outcome in outcomes {
            XCTAssertFalse(outcome.words.isEmpty)
            XCTAssertFalse(outcome.words.contains("sk-") || outcome.words.contains("FAKE"))
        }
        XCTAssertTrue(KeyMigration.Outcome.moved(count: 2).words.contains("2 keys"))
        XCTAssertTrue(KeyMigration.Outcome.keychainFailed(.denied).words.contains("still in"))
    }
}
