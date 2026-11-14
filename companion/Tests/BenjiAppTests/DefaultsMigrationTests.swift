import XCTest
import BenjiCore
@testable import BenjiApp

/// The settings carried over from the older bundle ids. `domain` is a table here, so no test ever reads a
/// real settings domain.
final class DefaultsMigrationTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "benji-defaults-migration-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws { defaults.removePersistentDomain(forName: suite) }

    private func run(_ domains: [String: [String: Any]]) {
        let own = Bundle.main.bundleIdentifier
        DefaultsMigration.run(defaults) { name in
            if name == own { return domains["own"] }
            return domains[name]
        }
    }

    func testModelSourceAndPendingTestAreMigratedTogether() {
        let settings: [String: Any] = [
            "setupModelProvider": "ollama", "setupLocalModel": "test-local-model",
            "setupLocalEndpoint": "http://localhost:11434/v1", "setupModelNeedsTest": true,
        ]
        DefaultsMigration.run(defaults, finish: false) { $0 == "com.chilly.app" ? settings : nil }
        XCTAssertEqual(defaults.string(forKey: ModelSetupPreferences.providerKey), "ollama")
        XCTAssertEqual(defaults.string(forKey: ModelSetupPreferences.modelKey), "test-local-model")
        XCTAssertEqual(defaults.string(forKey: ModelSetupPreferences.endpointKey), "http://localhost:11434/v1")
        XCTAssertTrue(defaults.bool(forKey: ModelSetupPreferences.needsTestKey))
    }

    func testTheUsersChoicesComeAcross() {
        run(["com.chilly.app": ["talkKey": "off", "browserForJobs": false, "browserAlwaysRead": ["https://example.com"], "keySource": "keychain",
                                "figureStage": false, "kokoroVoice": "af_sky", "migratedFromPalCompanion": true, "figureStageSensing": true]])
        XCTAssertEqual(defaults.string(forKey: "talkKey"), "off")
        XCTAssertEqual(defaults.object(forKey: "browserForJobs") as? Bool, false, "a browser that was off stays off")
        XCTAssertEqual(defaults.stringArray(forKey: "browserAlwaysRead"), ["https://example.com"])
        XCTAssertEqual(defaults.string(forKey: "keySource"), "keychain", "the key source goes with them")
        XCTAssertEqual(defaults.object(forKey: "figureStage") as? Bool, false)
        XCTAssertTrue(defaults.bool(forKey: "migratedFromPalCompanion"), "the older marker comes too, so that work isn't redone")
        XCTAssertTrue(defaults.bool(forKey: "figureStageSensing"))
    }

    func testNoPermissionNoteIsCopied() {
        var old: [String: Any] = [:]
        for key in DefaultsMigration.neverCopied { old[key] = true }
        run(["com.chilly.app": old])
        for key in DefaultsMigration.neverCopied { XCTAssertNil(defaults.object(forKey: key), key) }
    }

    func testAValueAlreadySetHereWins() {
        run(["own": ["talkKey": "rightOption"], "com.chilly.app": ["talkKey": "off", "kokoroSpeed": 1.2]])
        XCTAssertNil(defaults.object(forKey: "talkKey"), "not written over")
        XCTAssertEqual(defaults.double(forKey: "kokoroSpeed"), 1.2)
    }

    func testWhileTheOldAppRunsTheSettingsStillComeButItIsNotDone() {
        DefaultsMigration.run(defaults, finish: false) { $0 == "com.chilly.app" ? ["keySource": "keychain", "talkKey": "off"] : nil }
        XCTAssertEqual(defaults.string(forKey: "keySource"), "keychain", "this run needs the key source")
        XCTAssertFalse(defaults.bool(forKey: DefaultsMigration.doneKey))
        run(["com.chilly.app": ["talkKey": "off", "kokoroSpeed": 1.1], "own": ["keySource": "keychain", "talkKey": "off"]])
        XCTAssertEqual(defaults.double(forKey: "kokoroSpeed"), 1.1, "the next start copies what is still missing")
        XCTAssertTrue(defaults.bool(forKey: DefaultsMigration.doneKey))
    }

    func testRunsOnce() {
        run(["com.chilly.app": ["talkKey": "off"]])
        defaults.removeObject(forKey: "talkKey")
        run(["com.chilly.app": ["talkKey": "off"]])
        XCTAssertNil(defaults.object(forKey: "talkKey"), "a setting cleared later isn't brought back")
    }

    func testTheOldestDomainFillsGapsOnlyIfItWasNeverMigrated() {
        run(["com.pal.companion": ["talkKey": "pal", "ttsVoice": "v"], "com.chilly.app": ["talkKey": "chilly"]])
        XCTAssertEqual(defaults.string(forKey: "talkKey"), "chilly", "the newer domain wins")
        XCTAssertEqual(defaults.string(forKey: "ttsVoice"), "v")
    }

    func testPalIsLeftAloneOnceChillyHadItsTurn() {
        run(["com.pal.companion": ["ttsVoice": "v"], "com.chilly.app": ["migratedFromPalCompanion": true]])
        XCTAssertNil(defaults.object(forKey: "ttsVoice"), "a value cleared since then stays cleared")
    }
}
