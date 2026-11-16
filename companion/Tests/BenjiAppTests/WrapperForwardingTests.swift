import XCTest
@testable import BenjiApp
import BenjiCore

/// The app talks to the engine through `FigureStageBackend(ExplainCardBackend(bare))`. The
/// backend protocol gives most calls a do-nothing default, so a call a wrapper forgets to
/// forward is dropped without a word. Every call the model can make must reach the bare backend.
final class WrapperForwardingTests: XCTestCase {
    final class Recording: CompanionBackend {
        var calls: [String] = []
        var onEvent: ((_ run: Int, BackendEvent) -> Void)?
        var onFinished: ((_ run: Int, Int32) -> Void)?
        var approvalTimeout: TimeInterval = 60
        func start(run: Int, task: String, imagePath: String?, memory: ConversationMemory, allowPointing: Bool,
                   spoken: Bool, screen: ScreenshotGeometry?) { calls.append("start") }
        func startRemote(run: Int, task: String, memory: ConversationMemory) { calls.append("startRemote") }
        func resolveApproval(_ approved: Bool, from source: ApprovalSource) { calls.append("resolveApproval:\(source)") }
        func cancel() { calls.append("cancel") }
        func cutOff(reply: String, running: Bool) { calls.append("cutOff") }
        func reset() { calls.append("reset") }
        func shutdown() { calls.append("shutdown") }
        func restartEngine() { calls.append("restartEngine") }
        func finishScreenStep(request: String, result: ScreenStepResult) { calls.append("finishScreenStep") }
        func setBrowser(_ on: Bool) { calls.append("setBrowser") }
        func setBrowserAlways(_ sites: [String]) { calls.append("setBrowserAlways") }
        func stopDrive(reason: String) { calls.append("stopDrive") }
        func setSchedules(_ on: Bool) { calls.append("setSchedules") }
        func startEngineForSchedules() { calls.append("startEngineForSchedules") }
        func prewarm() { calls.append("prewarm") }
    }

    func testEveryCallReachesTheBareBackendThroughBothWrappers() {
        let bare = Recording()
        let chain: CompanionBackend = FigureStageBackend(
            ExplainCardBackend(bare, stage: ExplainCardBackendTests.FakeStage()), stage: { nil })
        chain.start(run: 1, task: "hi", imagePath: nil, memory: ConversationMemory(), allowPointing: false,
                    spoken: false, screen: nil)
        chain.startRemote(run: 2, task: "from the phone", memory: ConversationMemory())
        chain.resolveApproval(true)
        chain.resolveApproval(true, from: .phone)
        chain.cancel()
        chain.cutOff(reply: "heard so far", running: true)
        chain.reset()
        chain.restartEngine()
        chain.finishScreenStep(request: "s1", result: .ask("test"))
        chain.setBrowser(true)
        chain.setBrowserAlways(["https://example.com"])
        chain.stopDrive(reason: "user_stop")
        chain.setSchedules(true)
        chain.startEngineForSchedules()
        chain.prewarm()
        chain.shutdown()
        XCTAssertEqual(bare.calls, ["start", "startRemote", "resolveApproval:card", "resolveApproval:phone", "cancel", "cutOff", "reset", "restartEngine",
                                    "finishScreenStep", "setBrowser", "setBrowserAlways", "stopDrive",
                                    "setSchedules", "startEngineForSchedules", "prewarm", "shutdown"])
    }
}
