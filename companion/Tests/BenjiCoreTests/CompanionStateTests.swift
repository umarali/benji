import XCTest
@testable import BenjiCore

final class CompanionStateTests: XCTestCase {
    func apply(_ events: [CompanionEvent], from start: CompanionState = CompanionState()) -> CompanionState {
        var s = start
        for e in events { reduce(&s, e) }
        return s
    }

    func testSubmitEntersThinking() {
        let s = apply([.submitText("what's in my folder?")])
        XCTAssertEqual(s.phase, .thinking)
        XCTAssertEqual(s.lines.count, 1)
        XCTAssertEqual(s.lines.last?.role, .user)
        XCTAssertTrue(s.isBusy)
    }

    func testEmptySubmitIgnored() {
        let s = apply([.submitText("   ")])
        XCTAssertEqual(s.phase, .idle)
        XCTAssertTrue(s.lines.isEmpty)
    }

    func testHappyPathBackToIdle() {
        let s = apply([
            .submitText("list the folder"),
            .backendStarted,
            .toolProgress(name: "list_dir", detail: "."),
            .assistantAnswer("Two folders: output and tmp."),
            .backendFinished(0),
        ])
        XCTAssertEqual(s.phase, .idle)
        XCTAssertEqual(s.lines.map { $0.role }, [.user, .tool, .assistant])
        XCTAssertNil(s.pendingApproval)
    }

    func testApprovalRequestedEntersAwaiting() {
        let s = apply([
            .submitText("delete logs"),
            .approvalRequested(ApprovalRequest(id: "1", action: "run a destructive shell command", target: "rm -rf logs")),
        ])
        XCTAssertEqual(s.phase, .awaitingApproval)
        XCTAssertEqual(s.pendingApproval?.target, "rm -rf logs")
    }

    func testApprovalDeniedResumesAndRecordsDenial() {
        let s = apply([
            .submitText("delete logs"),
            .approvalRequested(ApprovalRequest(id: "1", action: "run a destructive shell command", target: "rm -rf logs")),
            .approvalResolved(false),
        ])
        XCTAssertNil(s.pendingApproval)
        XCTAssertEqual(s.phase, .thinking)
        XCTAssertEqual(s.lines.last?.role, .system)
        XCTAssertTrue(s.lines.last?.text.hasPrefix("Denied:") ?? false)
    }

    func testApprovalTimeoutIsADenialRecordedAsTimedOut() {
        let s = apply([
            .submitText("delete logs"),
            .approvalRequested(ApprovalRequest(id: "1", action: "run a destructive shell command", target: "rm -rf logs")),
            .approvalTimedOut,
        ])
        XCTAssertNil(s.pendingApproval)
        XCTAssertEqual(s.phase, .thinking)
        XCTAssertEqual(s.lines.last?.role, .system)
        XCTAssertEqual(s.lines.last?.text, "Timed out, so I didn't do it: run a destructive shell command")
    }

    func testApprovalApprovedRecordsApproval() {
        let s = apply([
            .approvalRequested(ApprovalRequest(id: "1", action: "overwrite existing file", target: "/tmp/x")),
            .approvalResolved(true),
        ])
        XCTAssertTrue(s.lines.last?.text.hasPrefix("Approved:") ?? false)
    }

    func testCancelWhileAwaitingApprovalDeniesSafely() {
        let s = apply([
            .submitText("delete logs"),
            .approvalRequested(ApprovalRequest(id: "1", action: "run a destructive shell command", target: "rm -rf logs")),
            .cancel,
        ])
        XCTAssertNil(s.pendingApproval)          // default-safe: no lingering request
        XCTAssertEqual(s.phase, .idle)
        XCTAssertTrue(s.lines.last?.text.contains("cancelled") ?? false)
    }

    func testBackendErrorEntersErrorState() {
        let s = apply([
            .submitText("do a thing"),
            .backendError("HTTP 401 from api.anthropic.com"),
        ])
        XCTAssertEqual(s.phase, .error)
        XCTAssertEqual(s.lastError, "HTTP 401 from api.anthropic.com")
        XCTAssertEqual(s.lines.last?.role, .error)
        XCTAssertFalse(s.isBusy)
    }

    func testCancelClearsBusyState() {
        let s = apply([.submitText("long task"), .backendStarted, .cancel])
        XCTAssertEqual(s.phase, .idle)
        XCTAssertFalse(s.isBusy)
    }

    // MARK: voice states

    func testMicStartedEntersListening() {
        let s = apply([.micStarted])
        XCTAssertEqual(s.phase, .listening)
        XCTAssertTrue(s.micActive)
    }

    func testTranscribingTurnsMicOff() {
        let s = apply([.micStarted, .transcribingStarted])
        XCTAssertEqual(s.phase, .transcribing)
        XCTAssertFalse(s.micActive)
    }

    func testTranscribedAddsUserLineAndThinks() {
        let s = apply([.micStarted, .transcribingStarted, .transcribed("open my notes")])
        XCTAssertEqual(s.phase, .thinking)
        XCTAssertFalse(s.micActive)
        XCTAssertEqual(s.lines.last?.role, .user)
        XCTAssertEqual(s.lines.last?.text, "open my notes")
    }

    func testEmptyTranscriptAddsNoLine() {
        let s = apply([.micStarted, .transcribingStarted, .transcribed("   ")])
        XCTAssertTrue(s.lines.isEmpty)
        XCTAssertEqual(s.phase, .thinking)
    }

    func testSpeakingThenIdle() {
        let s = apply([.speakingStarted])
        XCTAssertEqual(s.phase, .speaking)
        let s2 = apply([.speakingStarted, .speakingFinished])
        XCTAssertEqual(s2.phase, .idle)
    }

    func testCancelWhileListeningStopsMic() {
        let s = apply([.micStarted, .cancel])
        XCTAssertFalse(s.micActive)
        XCTAssertEqual(s.phase, .idle)
    }
}
