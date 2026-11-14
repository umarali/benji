import XCTest
@testable import BenjiCore

final class QuietCheckTests: XCTestCase {
    typealias W = QuietSignals.Window

    func testNothingGoingOnIsNotQuiet() {
        XCTAssertNil(QuietCheck.reason(QuietSignals()))
        XCTAssertNil(QuietCheck.reason(QuietSignals(runningApps: ["us.zoom.xos"], windows: [W(owner: "us.zoom.xos", title: "Zoom Workplace")])),
                     "Zoom's home window, with no call, is not a call")
    }

    func testRecordingAndMusicAppsNeverCountAsCalls() {
        for app in MeetingApps.neverCalls {
            XCTAssertNil(QuietCheck.reason(QuietSignals(microphoneUsers: [app], cameraRunning: false, runningApps: [app])),
                         "\(app) using the microphone is not a call")
            XCTAssertNil(QuietCheck.reason(QuietSignals(microphoneUsers: [app], cameraRunning: true, runningApps: [app])),
                         "\(app) using the microphone and camera is not a call")
        }
        XCTAssertTrue(MeetingApps.neverCalls.isDisjoint(with: MeetingApps.callApps), "no app is on both lists")
        XCTAssertTrue(MeetingApps.neverCalls.isDisjoint(with: MeetingApps.browsers))
    }

    func testMicrophoneUseDecidesNothingByItself() {
        // Several apps with the microphone open, none of them a call app: not a call.
        let s = QuietSignals(microphoneUsers: ["com.apple.garageband10", "com.apple.logic10", "some.unknown.recorder"])
        XCTAssertNil(QuietCheck.reason(s))
    }

    func testACallAppWithTheMicrophoneIsACall() {
        for app in ["us.zoom.xos", "com.microsoft.teams2", "com.apple.FaceTime", "com.tinyspeck.slackmacgap"] {
            XCTAssertEqual(QuietCheck.reason(QuietSignals(microphoneUsers: [app])), .microphoneInCall, app)
        }
        // Mixed: a recorder and a call app together are still a call.
        XCTAssertEqual(QuietCheck.reason(QuietSignals(microphoneUsers: ["com.apple.garageband10", "us.zoom.xos"])), .microphoneInCall)
    }

    func testTheCameraCountsOnlyWhileACallAppIsOpen() {
        XCTAssertNil(QuietCheck.reason(QuietSignals(cameraRunning: true)), "a camera alone (Photo Booth, a recorder) is not a call")
        XCTAssertNil(QuietCheck.reason(QuietSignals(cameraRunning: true, runningApps: ["com.apple.Photobooth"])))
        XCTAssertEqual(QuietCheck.reason(QuietSignals(cameraRunning: true, runningApps: ["us.zoom.xos", "com.apple.Safari"])), .cameraInCall)
    }

    func testMeetingWindowsByTitle() {
        XCTAssertTrue(MeetingApps.isMeeting(W(owner: "us.zoom.xos", title: "Zoom Meeting")))
        XCTAssertTrue(MeetingApps.isMeeting(W(owner: "us.zoom.xos", title: "Zoom Webinar")))
        XCTAssertFalse(MeetingApps.isMeeting(W(owner: "us.zoom.xos", title: "Zoom Workplace")))
        XCTAssertFalse(MeetingApps.isMeeting(W(owner: "us.zoom.xos", title: "")))
        XCTAssertTrue(MeetingApps.isMeeting(W(owner: "com.apple.FaceTime", title: "")))
        XCTAssertTrue(MeetingApps.isMeeting(W(owner: "com.google.Chrome", title: "Meet - abc-defg-hij")))
        XCTAssertTrue(MeetingApps.isMeeting(W(owner: "com.apple.Safari", title: "Weekly sync - Google Meet")))
        XCTAssertFalse(MeetingApps.isMeeting(W(owner: "com.google.Chrome", title: "Meet the team - Acme")))
        XCTAssertFalse(MeetingApps.isMeeting(W(owner: "com.google.Chrome", title: "Inbox")))
        XCTAssertTrue(MeetingApps.isMeeting(W(owner: "com.microsoft.teams2", title: "Design review | Microsoft Teams meeting")))
        XCTAssertFalse(MeetingApps.isMeeting(W(owner: "com.microsoft.teams2", title: "Chat | Microsoft Teams")))
        // A title that merely looks like a meeting in an app that isn't a browser or a call app is nothing.
        XCTAssertFalse(MeetingApps.isMeeting(W(owner: "com.apple.garageband10", title: "Zoom Meeting - project.band")))
        XCTAssertFalse(MeetingApps.isMeeting(W(owner: "com.apple.TextEdit", title: "Meet - notes")))
        XCTAssertEqual(QuietCheck.reason(QuietSignals(windows: [W(owner: "us.zoom.xos", title: "Zoom Meeting")])), .meetingWindow)
    }

    func testFocusAndScreenSharingAreSaidToBeUnread() {
        XCTAssertEqual(Set(QuietCheck.notRead.keys), ["Focus", "Screen sharing"])
        XCTAssertTrue(QuietCheck.notRead["Focus"]!.contains("permission"))
    }

    func testTheListOfUnaskedSurfacesHasNoRoomForTheUsersOwnPress() {
        // The check is only reachable through these. Adding a case here is a decision: this test makes it a visible one.
        XCTAssertEqual(Set(UnaskedSurface.allCases.map(\.rawValue)), ["cue", "notchEvent", "speech", "appOffer"])
        XCTAssertFalse(UnaskedSurface.allCases.map(\.rawValue).contains { $0.lowercased().contains("press") || $0.lowercased().contains("typed") })
    }

    func testTheGateReadsNoSignalsWhileTheSwitchIsOff() {
        var read = 0
        let off = QuietGate().verdict(switchOn: false) { read += 1; return QuietSignals() }
        XCTAssertEqual(off, .switchedOff)
        XCTAssertEqual(read, 0)
        XCTAssertEqual(QuietGate().verdict(switchOn: true) { read += 1; return QuietSignals() }, .allowed)
        XCTAssertEqual(read, 1)
        XCTAssertEqual(QuietGate().verdict(switchOn: true) { QuietSignals(microphoneUsers: ["us.zoom.xos"]) }, .quiet(.microphoneInCall))
    }
}

final class OutputSilenceTests: XCTestCase {
    func testMutedAndZeroVolumeAreSilent() {
        XCTAssertEqual(OutputSilence.of(OutputState(muted: true, volume: 0.5)), .muted)
        XCTAssertEqual(OutputSilence.of(OutputState(muted: false, volume: 0)), .zeroVolume)
        XCTAssertEqual(OutputSilence.of(OutputState(muted: false, volume: 0.004)), .zeroVolume)
        XCTAssertNil(OutputSilence.of(OutputState(muted: false, volume: 0.05)))
        XCTAssertNil(OutputSilence.of(OutputState(muted: false, volume: nil)), "an output with no volume control is not silent")
        XCTAssertNil(OutputSilence.of(nil), "when the Mac can't say, Benji speaks as before")
    }

    func testSilentOutputMeansNoSpeechAndATextNote() {
        let muted = OutputState(muted: true, volume: 0.6)
        XCTAssertFalse(SilentSpeech.shouldSpeak(wouldSpeak: true, state: muted))
        XCTAssertTrue(SilentSpeech.shouldSpeak(wouldSpeak: true, state: OutputState(muted: false, volume: 0.6)))
        XCTAssertFalse(SilentSpeech.shouldSpeak(wouldSpeak: false, state: OutputState(muted: false, volume: 0.6)))
        let note = SilentSpeech.note(wouldSpeak: true, state: muted, answer: "  It is three o'clock.\n")
        XCTAssertEqual(note, SilentAnswer(why: .muted, text: "It is three o'clock."))
        XCTAssertNil(SilentSpeech.note(wouldSpeak: false, state: muted, answer: "x"), "an answer that would not have been spoken gets no note")
        XCTAssertNil(SilentSpeech.note(wouldSpeak: true, state: OutputState(muted: false, volume: 0.5), answer: "x"))
        XCTAssertNil(SilentSpeech.note(wouldSpeak: true, state: muted, answer: "  "))
    }

    func testTheHintsSayHowToHearItAndPromiseNothingChanges() {
        XCTAssertTrue(OutputSilence.muted.hint.contains("Unmute"))
        XCTAssertTrue(OutputSilence.zeroVolume.hint.contains("volume"))
        for why in [OutputSilence.muted, .zeroVolume] {
            XCTAssertFalse(why.hint.lowercased().contains("i unmuted"), "Benji never changes the volume")
        }
        XCTAssertEqual(SilentAnswer.copyTitle, "Copy")
    }
}
