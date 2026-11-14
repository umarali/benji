import XCTest
@testable import BenjiCore

final class ScreenContextTests: XCTestCase {
    func run(_ events: [CompanionEvent]) -> CompanionState {
        var s = CompanionState()
        for e in events { reduce(&s, e) }
        return s
    }

    func testAttachmentLineCarriesID() {
        let s = run([.submitText("look"), .screenAttached(id: "abc", summary: "Screen attached")])
        XCTAssertEqual(s.lines.last?.role, .attachment)
        XCTAssertEqual(s.lines.last?.attachmentID, "abc")
    }

    func testDownscalesRetinaCapture() {
        let t = ScreenCapturePolicy.targetSize(for: CGSize(width: 3024, height: 1964))
        XCTAssertLessThanOrEqual(t.width * t.height, ScreenCapturePolicy.maxPixels)   // area cap binds here
        XCTAssertEqual(t.width, 1330, accuracy: 1)
        XCTAssertEqual(t.width / t.height, 3024.0 / 1964.0, accuracy: 0.01)
    }

    func testWideDisplayHitsLongEdgeOrAreaCap() {
        let t = ScreenCapturePolicy.targetSize(for: CGSize(width: 6880, height: 2880))   // ultrawide 2x
        XCTAssertLessThanOrEqual(max(t.width, t.height), ScreenCapturePolicy.maxLongEdge)
        XCTAssertLessThanOrEqual(t.width * t.height, ScreenCapturePolicy.maxPixels)
    }

    func testNeverUpscales() {
        XCTAssertEqual(ScreenCapturePolicy.targetSize(for: CGSize(width: 800, height: 600)),
                       CGSize(width: 800, height: 600))
    }

    func testScreenSendIsAskedFirst() {
        XCTAssertEqual(ScreenCapturePolicy.confirmQuestion(provider: "claude"),
                       "Send a picture of this screen to Anthropic with your message?")
        XCTAssertTrue(ScreenCapturePolicy.confirmQuestion(provider: nil).contains("your model provider"))
        XCTAssertLessThanOrEqual(ScreenCapturePolicy.confirmTimeout, ServeProtocol.appApprovalTimeout)
    }

    func testModeCaptionsNameTheProvider() {
        // D-147: a provider by name (the engine sends its label), and a model that can't read images
        XCTAssertTrue(ScreenCapturePolicy.modeCaption(.on, provider: "DeepSeek").contains("DeepSeek"))
        let note = ScreenCapturePolicy.noVisionNote(model: "glm-5.3")
        XCTAssertTrue(note.contains("glm-5.3") && note.contains("can't read images") && note.contains("BENJI_MODEL"))
        XCTAssertEqual(ScreenCapturePolicy.modeCaption(.off, provider: "claude"), "Benji can't see your screen.")
        XCTAssertTrue(ScreenCapturePolicy.modeCaption(.ask, provider: "claude").contains("Asks before"))
        XCTAssertTrue(ScreenCapturePolicy.modeCaption(.ask, provider: "openai").contains("OpenAI"))
        let on = ScreenCapturePolicy.modeCaption(.on, provider: "claude")
        XCTAssertTrue(on.contains("Anthropic") && on.contains("display you're on") && on.contains("each message"))
        XCTAssertTrue(ScreenCapturePolicy.onIndicator(provider: "openrouter.ai").contains("openrouter.ai"))
    }

    // MARK: screen mode (D-133: a fresh install starts On, a saved choice is kept, On never lapses)

    func testAFreshInstallStartsOnAndASavedChoiceIsKept() {
        XCTAssertEqual(ScreenModeState(saved: nil).mode, .on)
        XCTAssertEqual(ScreenModeState(saved: "sometimes").mode, .on, "an unreadable value is a fresh start")
        XCTAssertEqual(ScreenModeState(saved: "on").mode, .on)
        XCTAssertEqual(ScreenModeState(saved: "ask").mode, .ask)
        XCTAssertEqual(ScreenModeState(saved: "off").mode, .off)
    }

    func testChoosingIsAllThatChangesTheMode() {
        var s = ScreenModeState(saved: nil)
        s.choose(.ask)
        XCTAssertEqual(s.mode, .ask)
        s.choose(.on)
        XCTAssertEqual(s, ScreenModeState(saved: "on"), "no idle clock or lock state rides along")
    }

    func testCaptureExclusions() {
        func r(_ id: String?, pid: Int32 = 10, title: String? = nil) -> CaptureExclusions.Reason? {
            CaptureExclusions.reason(bundleID: id, pid: pid, ownPID: 1, title: title)
        }
        XCTAssertEqual(r("com.emerssive.heybenji.app", pid: 1), .benji)
        for id in ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
                   "com.apple.keychainaccess", "com.apple.Passwords"] {
            XCTAssertEqual(r(id), .passwordManager, id)
        }
        XCTAssertEqual(r("com.apple.notificationcenterui"), .notification)
        XCTAssertEqual(r("org.mozilla.firefox", title: "Bank — Mozilla Firefox Private Browsing"), .privateBrowsing)
        XCTAssertEqual(r("com.microsoft.edgemac", title: "New tab - [InPrivate]"), .privateBrowsing)
        XCTAssertNil(r("com.apple.Safari", title: "Bank"), "Safari's private windows can't be told apart")
        XCTAssertNil(r("com.apple.finder", title: "Documents"))
        XCTAssertNil(r(nil))
    }

    func testDisclosureNamesCustomServerHost() {
        XCTAssertEqual(ScreenCapturePolicy.providerDisplayName("Anthropic"), "Anthropic")
        XCTAssertEqual(ScreenCapturePolicy.providerDisplayName("openrouter.ai"), "openrouter.ai")
        XCTAssertEqual(ScreenCapturePolicy.providerDisplayName(""), "your model provider")
    }

    func testAttachmentSummary() {
        XCTAssertEqual(
            ScreenCapturePolicy.attachmentSummary(pixelSize: CGSize(width: 1568, height: 1018), provider: "openai"),
            "Screen attached · 1568×1018 · sent to OpenAI")
        XCTAssertEqual(
            ScreenCapturePolicy.attachmentSummary(pixelSize: CGSize(width: 10, height: 10), provider: "claude", leftOut: 2),
            "Screen attached · 10×10 · sent to Anthropic · 2 windows left out")
    }
}
