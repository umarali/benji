import XCTest
@testable import BenjiCore

final class PermissionSetupTests: XCTestCase {
    private func progress(_ p: [CompanionPermission: PermissionStatus]) -> SetupProgress {
        SetupProgress(permissions: p, modelDone: true)
    }

    private let allGranted: [CompanionPermission: PermissionStatus] = [
        .accessibility: .granted, .microphone: .granted, .speechRecognition: .granted, .screenRecording: .granted,
    ]

    func testPermissionsAloneNeverCompleteSetup() {
        let p = SetupProgress(permissions: allGranted)
        XCTAssertFalse(p.isComplete)
        var almost = allGranted
        almost[.screenRecording] = .notYet
        XCTAssertFalse(p.announcement(since: SetupProgress(permissions: almost))?.contains("All set.") ?? false)
    }

    func testStepOrder() {
        XCTAssertEqual(SetupStep.allCases, [.accessibility, .voice, .screenRecording, .automation, .model])
        XCTAssertFalse(SetupStep.automation.isRequired)
        XCTAssertTrue(SetupStep.automation.permissions.isEmpty)
    }

    func testEveryPermissionBelongsToOneStep() {
        let covered = SetupStep.allCases.flatMap(\.permissions)
        XCTAssertEqual(Set(covered), Set(CompanionPermission.allCases))
        XCTAssertEqual(covered.count, CompanionPermission.allCases.count)
    }

    func testVoiceStepCombinesMicAndSpeech() {
        XCTAssertEqual(SetupStep.voice.status([.microphone: .granted, .speechRecognition: .granted]), .granted)
        XCTAssertEqual(SetupStep.voice.status([.microphone: .granted, .speechRecognition: .notYet]), .notYet)
        XCTAssertEqual(SetupStep.voice.status([.microphone: .granted]), .notYet)
        XCTAssertEqual(SetupStep.voice.status([.microphone: .denied, .speechRecognition: .notYet]), .denied)
        XCTAssertEqual(SetupStep.automation.status(allGranted), .notYet)
    }

    func testNothingGrantedStartsAtAccessibility() {
        let p = progress([:])
        XCTAssertEqual(p.current, .accessibility)
        XCTAssertFalse(p.isComplete)
        XCTAssertFalse(p.endedWithGaps)
    }

    func testAdvancesInOrder() {
        XCTAssertEqual(progress([.accessibility: .granted]).current, .voice)
        XCTAssertEqual(progress([.accessibility: .granted, .microphone: .granted, .speechRecognition: .granted]).current,
                       .screenRecording)
        // A later grant doesn't skip an earlier step.
        XCTAssertEqual(progress([.screenRecording: .granted]).current, .accessibility)
    }

    func testAutomationNeverBlocksDone() {
        let p = progress(allGranted)
        XCTAssertNil(p.current)
        XCTAssertTrue(p.isComplete)
        XCTAssertFalse(p.endedWithGaps)
    }

    func testDeniedStepIsPassedOver() {
        let p = progress([.accessibility: .granted, .microphone: .denied, .speechRecognition: .notYet])
        XCTAssertEqual(p.status(of: .voice), .denied)
        XCTAssertEqual(p.current, .screenRecording)
    }

    func testOnlyDenialsLeftEndsWithGaps() {
        var perms = allGranted
        perms[.microphone] = .denied
        let p = progress(perms)
        XCTAssertNil(p.current)
        XCTAssertFalse(p.isComplete)
        XCTAssertTrue(p.endedWithGaps)
    }

    func testNewlyGrantedAndAnnouncement() {
        let before = progress([:])
        let after = progress([.accessibility: .granted])
        XCTAssertEqual(after.newlyGranted(since: before), [.accessibility])
        XCTAssertEqual(after.announcement(since: before), "Accessibility granted. Next: Microphone and Speech Recognition.")
        XCTAssertNil(after.announcement(since: after))
        // Only mic granted: the voice step isn't granted yet, so nothing to announce.
        let micOnly = progress([.accessibility: .granted, .microphone: .granted])
        XCTAssertNil(micOnly.announcement(since: after))
    }

    func testAnnouncementWhenComplete() {
        var almost = allGranted
        almost[.screenRecording] = .notYet
        XCTAssertEqual(progress(allGranted).announcement(since: progress(almost)), "Screen Recording granted. All set.")
    }

    func testAutoOpenOnceOnFirstLaunch() {
        XCTAssertTrue(SetupAutoOpen.shouldOpen(alreadyShown: false, resumeAfterRelaunch: false, isComplete: false))
        XCTAssertFalse(SetupAutoOpen.shouldOpen(alreadyShown: false, resumeAfterRelaunch: false, isComplete: true))
        XCTAssertFalse(SetupAutoOpen.shouldOpen(alreadyShown: true, resumeAfterRelaunch: false, isComplete: false))
        XCTAssertTrue(SetupAutoOpen.shouldOpen(alreadyShown: true, resumeAfterRelaunch: true, isComplete: false))
    }

    func testStatusWords() {
        XCTAssertEqual(PermissionStatus.granted.word, "Granted")
        XCTAssertEqual(PermissionStatus.notYet.word, "Not yet")
        XCTAssertEqual(PermissionStatus.denied.word, "Denied")
    }
}
