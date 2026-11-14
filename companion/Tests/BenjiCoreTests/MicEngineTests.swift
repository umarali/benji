import XCTest
@testable import BenjiCore

/// The mic opens on one engine per conversation (-10875 came from two engines taking turns).
final class MicEngineTests: XCTestCase {
    func choose(_ mode: BargeInMode, _ route: OutputRoute, handsFree: Bool = true, available: Bool = true) -> MicEngine {
        MicEngine.choose(mode: mode, route: route, handsFreeOn: handsFree, handsFreeAvailable: available)
    }

    func testOffAndHeadphonesModesUseThePlainEngine() {
        for route in [OutputRoute.speakers, .unknown, .headphones] {
            XCTAssertEqual(choose(.off, route), .plain)
            XCTAssertEqual(choose(.headphones, route), .plain)
        }
    }

    func testAlwaysOnSpeakersUsesTheEchoEngineForEveryUtterance() {
        // The choice doesn't depend on whether Benji is speaking: the same engine all conversation.
        XCTAssertEqual(choose(.always, .speakers), .echoCancelling)
        XCTAssertEqual(choose(.always, .unknown), .echoCancelling)
    }

    func testAlwaysWithHeadphonesNeedsNoEchoCancelling() {
        XCTAssertEqual(choose(.always, .headphones), .plain)
    }

    func testHoldToTalkStaysOnThePlainEngine() {
        XCTAssertEqual(choose(.always, .speakers, handsFree: false), .plain)
        XCTAssertEqual(choose(.always, .speakers, available: false), .plain, "the cloud transcriber has no conversation")
    }

    func testTheFallbackIsTheOtherEngineOnce() {
        XCTAssertEqual(MicEngine.plain.other, .echoCancelling)
        XCTAssertEqual(MicEngine.echoCancelling.other, .plain)
    }

    func testTheFailureSaysTheCodeAndWhatToTry() {
        let m = MicEngine.failureMessage(code: -10875, description: "The operation couldn't be completed.", triedBoth: true)
        XCTAssertTrue(m.hasPrefix("Couldn't start recording (tried both microphone paths)"))
        XCTAssertTrue(m.contains("(error -10875)"))
        XCTAssertTrue(m.contains("Talk over Benji → Headphones"))
    }

    func testTheLogRotatesPast200KB() {
        XCTAssertEqual(VoiceLog.maximumBytes, 204_800)
        XCTAssertFalse(VoiceLog.shouldRotate(currentSize: 0, adding: 300_000), "never rotate an empty log")
        XCTAssertFalse(VoiceLog.shouldRotate(currentSize: 204_000, adding: 800))
        XCTAssertTrue(VoiceLog.shouldRotate(currentSize: 204_000, adding: 801))
    }

    func testALogLineIsOneLineWithATimestamp() {
        let date = Date(timeIntervalSince1970: 0)
        let line = VoiceLog.line("recording format=48 kHz\nsecond", at: date, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(line, "1970-01-01 00:00:00.000 [ptt] recording format=48 kHz second\n")
    }
}
