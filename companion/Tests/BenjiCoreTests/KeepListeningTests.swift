import XCTest
@testable import BenjiCore

/// "Keep listening when the panel closes" (D-122): a running conversation carries on in the notch
/// after the panel closes; closing never starts one, and the mic never comes on by itself while closed.
final class KeepListeningWhenClosedTests: XCTestCase {
    func testStoredSettingIsOnUnlessTurnedOff() {
        XCTAssertTrue(OpenListening.enabled(from: nil))
        XCTAssertFalse(OpenListening.enabled(from: false))
        XCTAssertFalse(OpenListening.enabled(from: "off"))
        XCTAssertNotEqual(OpenListening.keepWhenClosedKey, OpenListening.defaultsKey)
    }

    func testClosingKeepsARunningConversation() {
        var o = OpenListening(keepsListeningWhenClosed: true)
        XCTAssertEqual(o.update(panelOpen: true, conversationOn: false, canListen: true), .start)
        XCTAssertNil(o.update(panelOpen: false, conversationOn: true, canListen: true))
        XCTAssertFalse(o.panelOpen)
    }

    func testClosingNeverStartsOne() {
        var o = OpenListening(keepsListeningWhenClosed: true)
        _ = o.update(panelOpen: true, conversationOn: false, canListen: true)
        XCTAssertNil(o.update(panelOpen: false, conversationOn: false, canListen: true))
        // Nothing while closed starts listening, the setting turned on included.
        XCTAssertNil(o.setEnabled(false, conversationOn: false, canListen: true))
        XCTAssertNil(o.setEnabled(true, conversationOn: false, canListen: true))
        XCTAssertNil(o.setKeepsListeningWhenClosed(false, conversationOn: false))
        XCTAssertNil(o.setKeepsListeningWhenClosed(true, conversationOn: false))
    }

    func testAConversationThatEndsWhileClosedStaysEndedUntilThePanelOpens() {
        var o = OpenListening(keepsListeningWhenClosed: true)
        _ = o.update(panelOpen: true, conversationOn: false, canListen: true)
        _ = o.update(panelOpen: false, conversationOn: true, canListen: true)
        o.conversationEnded(.timeout)
        XCTAssertFalse(o.heldOff, "closed: nothing to hold off, and nothing restarts while closed")
        XCTAssertEqual(o.update(panelOpen: true, conversationOn: false, canListen: true), .start,
                       "opening the panel again starts one, as before")
    }

    func testTurningItOffWhileClosedEndsTheConversationItKept() {
        var o = OpenListening(keepsListeningWhenClosed: true)
        _ = o.update(panelOpen: true, conversationOn: false, canListen: true)
        _ = o.update(panelOpen: false, conversationOn: true, canListen: true)
        XCTAssertEqual(o.setKeepsListeningWhenClosed(false, conversationOn: true), .stop(.panelClosed))
    }

    func testTurningItOffWhileOpenChangesNothingNow() {
        var o = OpenListening(keepsListeningWhenClosed: true)
        _ = o.update(panelOpen: true, conversationOn: false, canListen: true)
        XCTAssertNil(o.setKeepsListeningWhenClosed(false, conversationOn: true))
        XCTAssertEqual(o.update(panelOpen: false, conversationOn: true, canListen: true), .stop(.panelClosed),
                       "then closing ends it, as before D-122")
    }

    func testOffKeepsTheOldRule() {
        var o = OpenListening(keepsListeningWhenClosed: false)
        _ = o.update(panelOpen: true, conversationOn: false, canListen: true)
        XCTAssertEqual(o.update(panelOpen: false, conversationOn: true, canListen: true), .stop(.panelClosed))
    }

    func testCancelWhileClosedStillEndsTheConversation() {
        var o = OpenListening(keepsListeningWhenClosed: true)
        _ = o.update(panelOpen: true, conversationOn: false, canListen: true)
        _ = o.update(panelOpen: false, conversationOn: true, canListen: true)
        XCTAssertFalse(o.keepsListeningOnCancel)
    }

    func testTheSettingIsAChange() {
        XCTAssertNotEqual(SettingsChange.keepListeningWhenClosed(true), .keepListeningWhenClosed(false))
        XCTAssertFalse(SettingsSnapshot().keepListeningWhenClosed)
    }
}
