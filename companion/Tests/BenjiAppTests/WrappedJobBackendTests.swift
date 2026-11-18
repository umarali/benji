import XCTest
import SwiftUI
import AppKit
@testable import BenjiApp
import BenjiCore

/// The app builds its model on `FigureStageBackend(ExplainCardBackend(bare))`. The job row and its
/// buttons reach the engine through `backend as? JobBackend`, so both wrappers must pass the job
/// calls through; a cast that fails there leaves a job parked on its first approval with nothing
/// to answer it. The model's other job tests use the bare backend and can't see that.
final class WrappedJobBackendTests: XCTestCase {
    let id = "5b0f3a52-2c61-4f0e-9d0a-0f5a1c1a7e11"

    /// A backend that is not a JobBackend.
    final class Plain: CompanionBackend {
        var onEvent: ((_ run: Int, BackendEvent) -> Void)?
        var onFinished: ((_ run: Int, Int32) -> Void)?
        var approvalTimeout: TimeInterval = 60
        func start(run: Int, task: String, imagePath: String?, memory: ConversationMemory, allowPointing: Bool,
                   spoken: Bool, screen: ScreenshotGeometry?) {}
        func resolveApproval(_ approved: Bool, from source: ApprovalSource) {}
        func cancel() {}
        func reset() {}
        func shutdown() {}
    }

    private func chain(_ bare: CompanionBackend) -> CompanionBackend {
        FigureStageBackend(ExplainCardBackend(bare, stage: ExplainCardBackendTests.FakeStage()), stage: { nil })
    }

    private func model(_ backend: CompanionBackend) -> CompanionModel {
        let suite = UserDefaults(suiteName: "benji-wrapped-job-\(UUID().uuidString)")!
        suite.set(ScreenMode.off.rawValue, forKey: ScreenModeState.defaultsKey)
        return CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: suite))
    }

    func testTheWrappedChainStillCastsToJobBackend() {
        XCTAssertNotNil(chain(FakeBackend()) as? JobBackend)
    }

    func testAJobSnapshotReachesTheModelThroughBothWrappers() {
        let fake = FakeBackend()
        let model = model(chain(fake))
        XCTAssertNil(model.job)
        fake.job(JobSnapshot(id: id, title: "Headphones", state: .working, line: "Reading a page"))
        XCTAssertEqual(model.job?.state, .working)
        XCTAssertEqual(model.job?.detail, "Reading a page")
    }

    func testResumeConsentReachesTheEngineAndRejectsStaleOrWiderScope() {
        let fake = FakeBackend()
        let model = model(chain(fake))
        let offered = JobSnapshot(id: id, title: "Read", state: .failed, run: 2,
                                  canResume: true, recoveryGeneration: "g1")
        fake.job(offered)
        model.resumeJob(offered, readSites: ["https://wide.example"], actSites: [])
        XCTAssertTrue(fake.jobResumes.isEmpty)
        model.resumeJob(offered, readSites: [], actSites: [])
        XCTAssertEqual(fake.jobResumes.count, 1)
        XCTAssertEqual(fake.jobResumes[0].generation, "g1")
        XCTAssertEqual(fake.jobResumes[0].run, 2)
        fake.job(JobSnapshot(id: id, title: "Read", state: .failed, run: 2,
                             canResume: true, recoveryGeneration: "g2"))
        model.resumeJob(offered, readSites: [], actSites: [])
        XCTAssertEqual(fake.jobResumes.count, 1)
    }

    @MainActor
    func testResumeConsentFitsTheExistingNarrowPanelWithManySites() async {
        let sites = (0..<30).map { "https://site-\($0)-with-a-long-name.example" }
        let offered = JobSnapshot(id: id, title: "Read pages", state: .failed, sites: sites,
                                  run: 2, actSites: sites, canResume: true, recoveryGeneration: "g1")
        let width = PanelGeometry.openSize.width - 56 // panel and job row padding
        let hosting = NSHostingView(rootView: JobResumeConsent(job: offered, cancel: {}, confirm: { _, _ in })
            .frame(width: width))
        let measured = hosting.fittingSize
        XCTAssertGreaterThan(measured.height, 0)
        XCTAssertLessThanOrEqual(measured.width, width + 1)
        XCTAssertLessThanOrEqual(measured.height, 230, "Site lists scroll inside the existing row; they cannot grow the panel.")
    }

    func testTheButtonsReachTheEngineThroughBothWrappers() {
        let fake = FakeBackend()
        let model = model(chain(fake))
        let parked = JobPending(request: "a1", action: "write a file", target: "/j/output/pairs.md")
        fake.job(JobSnapshot(id: id, title: "Headphones", state: .needsYou, pending: parked))
        model.answerJob(true)
        XCTAssertEqual(fake.jobAnswers.count, 1)
        XCTAssertEqual(fake.jobAnswers.first?.job, id)
        XCTAssertEqual(fake.jobAnswers.first?.request, "a1")
        XCTAssertEqual(fake.jobAnswers.first?.approved, true)
        XCTAssertTrue(fake.approvals.isEmpty, "the foreground approval path is never the job's")

        fake.job(JobSnapshot(id: id, title: "Headphones", state: .working, line: "Reading a page"))
        XCTAssertTrue(model.steerJob("use the cheaper ones"))
        XCTAssertEqual(fake.jobSteers.first?.text, "use the cheaper ones")
        model.stopJob()
        XCTAssertEqual(fake.jobStops, [id])

        fake.job(JobSnapshot(id: id, title: "Headphones", state: .done, spoken: "Done."))
        model.dismissJob()
        XCTAssertEqual(fake.jobDismissals, [id])
    }

    func testALostEngineReachesTheModelThroughBothWrappers() {
        let fake = FakeBackend()
        let model = model(chain(fake))
        fake.job(JobSnapshot(id: id, title: "Headphones", state: .working, line: "Reading a page"))
        fake.onEngineExit?()
        XCTAssertEqual(model.job?.state, .failed)
    }

    func testABackendWithoutJobsStaysWorkingWithNoJobsToForward() {
        let plain = Plain()
        let wrapped = chain(plain)
        let model = model(wrapped)
        let jobs = wrapped as? JobBackend
        XCTAssertNil(jobs?.onJob)
        jobs?.answerJob(id, request: "a1", approved: true)   // nothing to answer: no crash, no effect
        jobs?.stopJob(id)
        XCTAssertNil(model.job)
    }

    func testContinueScheduleAndTheSwitchReachTheEngineThroughBothWrappers() {
        let fake = FakeBackend()
        let model = model(chain(fake))
        fake.job(JobSnapshot(id: id, title: "Tea", state: .failed, error: "x", canContinue: true,
                             schedule: JobSchedule(text: "Every day at 09:00")))
        model.continueJob()
        model.scheduleJob(.pause)
        model.scheduleJob(.delete)
        model.setSchedules(false)
        model.startEngineForSchedules()
        XCTAssertEqual(fake.jobContinues, [id], "a cast that fails in either wrapper would leave the button dead")
        XCTAssertEqual(fake.scheduleActions.map(\.action), [.pause, .delete])
        XCTAssertEqual(fake.schedulesSwitch, [false])
        XCTAssertEqual(fake.engineStartsForSchedules, 1)
    }

    func testTheSwitchAndTheButtonsAreHarmlessOnABackendWithoutJobsThroughBothWrappers() {
        let wrapped = chain(Plain())
        let model = model(wrapped)
        model.setSchedules(true)
        model.startEngineForSchedules()
        (wrapped as? JobBackend)?.continueJob(id)
        (wrapped as? JobBackend)?.scheduleJob(id, .pause)
        XCTAssertNil(model.job)
    }
}
