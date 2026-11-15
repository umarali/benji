import Foundation
@testable import BenjiApp
import BenjiCore

/// A backend that records what the model asked of it and lets a test play the engine's side,
/// late and out-of-order callbacks included. No process, no network.
final class FakeBackend: CompanionBackend, JobBackend {
    var onEvent: ((_ run: Int, BackendEvent) -> Void)?
    var onFinished: ((_ run: Int, Int32) -> Void)?
    var approvalTimeout: TimeInterval = 60

    struct Start: Equatable { let run: Int; let task: String; let spoken: Bool; let memoryEmpty: Bool; var imagePath: String? = nil }
    private(set) var starts: [Start] = []
    private(set) var approvals: [Bool] = []
    private(set) var cancels = 0

    var lastRun: Int { starts.last!.run }

    // Background jobs: what the model asked of the engine, and the engine's side.
    var onJob: ((JobSnapshot) -> Void)?
    var onEngineExit: (() -> Void)?
    private(set) var jobAnswers: [(job: String, request: String, approved: Bool)] = []
    private(set) var jobStops: [String] = []
    private(set) var jobSteers: [(job: String, text: String)] = []
    private(set) var jobDismissals: [String] = []
    func answerJob(_ job: String, request: String, approved: Bool) { jobAnswers.append((job, request, approved)) }
    func stopJob(_ job: String) { jobStops.append(job) }
    func steerJob(_ job: String, text: String) { jobSteers.append((job, text)) }
    func dismissJob(_ job: String) { jobDismissals.append(job) }
    func job(_ snapshot: JobSnapshot) { onJob?(snapshot) }
    // Continuing a job, and its schedules.
    private(set) var jobContinues: [String] = []
    private(set) var scheduleActions: [(job: String, action: JobScheduleAction)] = []
    private(set) var schedulesSwitch: [Bool] = []
    private(set) var engineStartsForSchedules = 0
    func continueJob(_ job: String) { jobContinues.append(job) }
    func scheduleJob(_ job: String, _ action: JobScheduleAction) { scheduleActions.append((job, action)) }
    func setSchedules(_ on: Bool) { schedulesSwitch.append(on) }
    func startEngineForSchedules() { engineStartsForSchedules += 1 }

    func start(run: Int, task: String, imagePath: String?, memory: ConversationMemory, allowPointing: Bool,
               spoken: Bool, screen: ScreenshotGeometry?) {
        starts.append(Start(run: run, task: task, spoken: spoken, memoryEmpty: memory.isEmpty, imagePath: imagePath))
    }
    private(set) var prewarms = 0
    func prewarm() { prewarms += 1 }
    func resolveApproval(_ approved: Bool) { approvals.append(approved) }
    func cancel() { cancels += 1 }
    func reset() {}
    func shutdown() {}

    // The engine's side.
    func say(_ event: BackendEvent, run: Int? = nil) { onEvent?(run ?? lastRun, event) }
    func finish(_ code: Int32 = 0, run: Int? = nil) { onFinished?(run ?? lastRun, code) }
}
