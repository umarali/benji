import XCTest
@testable import BenjiApp
import BenjiCore

/// Background jobs through the coordinator (D-130 step 1): the row's state is the engine's, a
/// parked approval is answered by the app's button once, Esc cancels only in the beat, the peek
/// speaks for unseen news, the thread opens in the history view, and a lost engine ends the job.
final class CompanionModelJobTests: XCTestCase {
    let id = "5b0f3a52-2c61-4f0e-9d0a-0f5a1c1a7e11"
    var backend: FakeBackend!
    var model: CompanionModel!
    var history: ConversationHistory!
    var defaults: UserDefaults!
    var root: URL!

    override func setUp() {
        backend = FakeBackend()
        defaults = UserDefaults(suiteName: "benji-job-tests-\(UUID().uuidString)")!
        defaults.set(ScreenMode.off.rawValue, forKey: ScreenModeState.defaultsKey)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("benji-job-\(UUID().uuidString)")
        history = ConversationHistory(store: ConversationStore(directory: root.appendingPathComponent("conversations")),
                                      defaults: defaults)
        model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: defaults), history: history)
        history.flush()     // the folder read at start lands first, so it can't replace a thread saved after
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    override func tearDown() {
        history.flush()
        try? FileManager.default.removeItem(at: root)
    }

    private func job(_ state: JobState, line: String = "", pending: JobPending? = nil, spoken: String = "",
                     chips: [String] = []) -> JobSnapshot {
        JobSnapshot(id: id, title: "Headphones", state: state, line: line, pending: pending, spoken: spoken, chips: chips)
    }
    private let parked = JobPending(request: "a1", action: "write a file", target: "/j/output/pairs.md")

    func testTheRowShowsWhateverTheEngineSays() {
        XCTAssertNil(model.job)
        backend.job(job(.queued))
        XCTAssertEqual(model.job?.state, .queued)
        backend.job(job(.working, line: "Reading a page"))
        XCTAssertEqual(model.job?.detail, "Reading a page")
    }

    func testAParkedJobIsAnsweredByTheButtonOncePerRequest() {
        backend.job(job(.needsYou, pending: parked))
        model.answerJob(true)
        model.answerJob(true)
        model.answerJob(false)
        XCTAssertEqual(backend.jobAnswers.count, 1)
        XCTAssertEqual(backend.jobAnswers.first?.job, id)
        XCTAssertEqual(backend.jobAnswers.first?.request, "a1")
        XCTAssertEqual(backend.jobAnswers.first?.approved, true)
        XCTAssertTrue(backend.approvals.isEmpty, "the foreground approval path is never the job's")
    }

    func testANewRequestOnTheSameJobCanBeAnswered() {
        backend.job(job(.needsYou, pending: parked))
        model.answerJob(false)
        backend.job(job(.working))
        backend.job(job(.needsYou, pending: JobPending(request: "a2", action: "send", target: "")))
        model.answerJob(true)
        XCTAssertEqual(backend.jobAnswers.map(\.request), ["a1", "a2"])
    }

    func testNoPendingRequestMeansNothingToAnswer() {
        backend.job(job(.working))
        model.answerJob(true)
        XCTAssertTrue(backend.jobAnswers.isEmpty)
    }

    func testEscCancelsOnlyInTheBeat() {
        backend.job(job(.queued))
        XCTAssertTrue(model.jobEscape())
        XCTAssertEqual(backend.jobStops, [id])
        backend.job(job(.working))
        XCTAssertFalse(model.jobEscape(), "once it runs, Esc isn't the job's")
        XCTAssertEqual(backend.jobStops.count, 1)
    }

    func testStopOnlyWhileLive() {
        backend.job(job(.working))
        model.stopJob()
        backend.job(job(.done))
        model.stopJob()
        XCTAssertEqual(backend.jobStops, [id])
    }

    func testSteerGoesToTheEngineOnlyForARunningJob() {
        backend.job(job(.queued))
        XCTAssertFalse(model.steerJob("only Lisbon"))
        backend.job(job(.working))
        XCTAssertFalse(model.steerJob("   "))
        XCTAssertTrue(model.steerJob("  only Lisbon  "))
        XCTAssertEqual(backend.jobSteers.map(\.text), ["only Lisbon"])
        XCTAssertEqual(backend.jobSteers.first?.job, id)
        backend.job(job(.done))
        XCTAssertFalse(model.steerJob("too late"))
    }

    func testClearRemovesAJobThatIsOverAndNotOneThatIsLive() {
        backend.job(job(.working))
        model.dismissJob()
        XCTAssertNotNil(model.job)
        backend.job(job(.done))
        model.dismissJob()
        XCTAssertNil(model.job)
        XCTAssertEqual(backend.jobDismissals, [id])
    }

    func testThePeekSpeaksForTheBeatAndForNewsNotYetSeen() {
        XCTAssertFalse(model.jobPeek)
        backend.job(job(.queued))
        XCTAssertTrue(model.jobPeek, "the beat is shown, so Esc can be seen to work")
        backend.job(job(.working))
        XCTAssertFalse(model.jobPeek, "a working job is quiet")
        backend.job(job(.needsYou, pending: parked))
        XCTAssertTrue(model.jobPeek)
        model.setExpanded(true)
        XCTAssertFalse(model.jobPeek, "opening the panel is seeing it")
        model.setExpanded(false)
        backend.job(job(.done, spoken: "Two fit."))
        XCTAssertTrue(model.jobPeek, "news while the panel is closed is unseen")
    }

    func testAJobAlreadyOverWhenFirstHeardOfIsOldNews() {
        backend.job(job(.failed))
        XCTAssertFalse(model.jobPeek, "the engine's last job, shown after a restart, doesn't pop the notch")
        XCTAssertEqual(model.job?.state, .failed)
    }

    func testNewsOnAnOpenPanelIsSeenAtOnce() {
        model.setExpanded(true)
        backend.job(job(.working))
        backend.job(job(.done, spoken: "Done."))
        XCTAssertFalse(model.jobPeek)
    }

    func testChipsAreSentAsTypedMessages() {
        backend.job(job(.done, spoken: "Two fit.", chips: ["Email it to me"]))
        model.askJobChip("Email it to me")
        XCTAssertEqual(backend.starts.last?.task, "Email it to me")
        XCTAssertEqual(backend.starts.last?.spoken, false)
    }

    func testCuesFireOnlyWhenSwitchedOn() {
        var cues: [JobCue] = []
        model.onJobCue = { cues.append($0) }
        backend.job(job(.working))
        backend.job(job(.needsYou, pending: parked))
        XCTAssertTrue(cues.isEmpty, "off by default")
        UserDefaults.standard.set(true, forKey: JobCues.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: JobCues.defaultsKey) }
        backend.job(job(.working))
        backend.job(job(.done))
        backend.job(job(.done))
        XCTAssertEqual(cues, [.done])
    }

    func testTheBeatIsWatchedForEscOnlyWhileQueued() {
        var watching: [Bool] = []
        model.watchJobBeat = { watching.append($0) }
        backend.job(job(.queued))
        backend.job(job(.working))
        XCTAssertEqual(watching, [true, false])
    }

    func testALostEngineEndsALiveJobAsFailed() {
        backend.job(job(.working))
        backend.onEngineExit?()
        XCTAssertEqual(model.job?.state, .failed)
        XCTAssertEqual(model.job?.error, "Benji restarted before this finished.")
        backend.onEngineExit?()
        XCTAssertEqual(model.job?.state, .failed)
    }

    func testTheEndedJobsThreadOpensInTheHistoryView() throws {
        backend.job(job(.working))
        backend.job(job(.done, spoken: "Two pairs fit."))
        history.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(history.summaries.map(\.id), [id])
        XCTAssertEqual(history.summaries.first?.title, "Job · Headphones")
        model.openJobThread()
        XCTAssertEqual(history.currentID, id)
        XCTAssertEqual(model.state.lines.last?.text, "Two pairs fit.")
    }

    func testAJobThreadYouContinueIsNotOverwrittenByTheJob() throws {
        backend.job(job(.done, spoken: "Two pairs fit."))
        history.flush()
        model.openJobThread()
        let before = history.summaries
        backend.job(job(.done, spoken: "Changed"))
        XCTAssertEqual(history.summaries, before)
    }

    // MARK: second pass (D-172)

    private let otherId = "9d3c1f6e-7a52-4b83-8c11-2e4f5a6b7c8d"

    func testAQuietRunOfAnotherJobNeverTakesOverTheRowOrMakesAThread() {
        backend.job(JobSnapshot(id: id, title: "Headphones", state: .done, written: "Two pairs fit."))
        backend.job(JobSnapshot(id: otherId, title: "Tea", state: .done, written: "Same.", news: false, quiet: true))
        XCTAssertEqual(model.job?.id, id, "the row the user is looking at stays")
        history.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(history.summaries.map(\.id), [id], "only the job the user is looking at has a thread")
        backend.job(JobSnapshot(id: otherId, title: "Tea", state: .done, written: "A third thing.", quiet: false))
        XCTAssertEqual(model.job?.id, otherId, "news from another job is shown, as before")
    }

    func testAQuietRunOfTheShownJobUpdatesItWithoutAPeek() {
        backend.job(JobSnapshot(id: id, title: "Tea", state: .done, written: "Two things."))
        model.setExpanded(true, byBenji: false)
        model.setExpanded(false, byBenji: false)
        backend.job(JobSnapshot(id: id, title: "Tea", state: .working, line: "Reading a page", run: 2, unattended: true, quiet: true))
        backend.job(JobSnapshot(id: id, title: "Tea", state: .done, written: "Same.", run: 2, unattended: true, news: false, quiet: true))
        XCTAssertEqual(model.job?.run, 2)
        XCTAssertFalse(model.jobPeek, "a repeat run with nothing new is quiet")
    }

    func testNoCueForAQuietRunAndOneForNews() {
        defaults.set(true, forKey: JobCues.defaultsKey)
        UserDefaults.standard.set(true, forKey: JobCues.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: JobCues.defaultsKey) }
        var cues: [JobCue] = []
        model.onJobCue = { cues.append($0) }
        backend.job(JobSnapshot(id: id, title: "Tea", state: .working))
        backend.job(JobSnapshot(id: id, title: "Tea", state: .done, news: false, quiet: true))
        XCTAssertEqual(cues, [])
        backend.job(JobSnapshot(id: id, title: "Tea", state: .working))
        backend.job(JobSnapshot(id: id, title: "Tea", state: .done, written: "New.", quiet: false))
        XCTAssertEqual(cues, [.done])
    }

    func testContinueIsTheUsersButtonAndOnlyForAJobThatCanBeContinued() {
        backend.job(JobSnapshot(id: id, title: "H", state: .working))
        model.continueJob()
        XCTAssertEqual(backend.jobContinues, [], "a job that is working isn't continued")
        backend.job(JobSnapshot(id: id, title: "H", state: .failed, error: "Benji couldn't reach the model service.", canContinue: true))
        model.continueJob()
        XCTAssertEqual(backend.jobContinues, [id])
        backend.job(JobSnapshot(id: id, title: "H", state: .done, canContinue: false))
        model.continueJob()
        XCTAssertEqual(backend.jobContinues, [id])
    }

    func testTheScheduleButtonsAskOnlyForWhatTheScheduleOffers() {
        backend.job(JobSnapshot(id: id, title: "Tea", state: .done, schedule: JobSchedule(text: "Every day at 09:00")))
        model.scheduleJob(.resume)
        XCTAssertEqual(backend.scheduleActions.count, 0, "it isn't paused: nothing to resume")
        model.scheduleJob(.pause)
        model.scheduleJob(.delete)
        XCTAssertEqual(backend.scheduleActions.map(\.action), [.pause, .delete])
        XCTAssertEqual(backend.scheduleActions.first?.job, id)
        backend.job(JobSnapshot(id: id, title: "Tea", state: .done, schedule: JobSchedule(text: "Every day, paused", paused: true, reason: "user")))
        model.scheduleJob(.pause)
        model.scheduleJob(.resume)
        XCTAssertEqual(backend.scheduleActions.map(\.action), [.pause, .delete, .resume])
        backend.job(JobSnapshot(id: id, title: "No schedule", state: .done))
        model.scheduleJob(.delete)
        XCTAssertEqual(backend.scheduleActions.count, 3, "a job with no schedule has nothing to delete")
    }

    func testTheSwitchAndTheLaunchStartReachTheBackend() {
        model.setSchedules(false)
        model.setSchedules(true)
        model.startEngineForSchedules()
        XCTAssertEqual(backend.schedulesSwitch, [false, true])
        XCTAssertEqual(backend.engineStartsForSchedules, 1)
    }

    func testALostEngineKeepsWhatTheUserWasToldAndOffersContinue() {
        backend.job(JobSnapshot(id: id, title: "Tea", state: .working, brief: "Goal (as Benji stated it): tea", run: 2,
                                schedule: JobSchedule(text: "Every day at 09:00")))
        backend.onEngineExit?()
        XCTAssertEqual(model.job?.state, .failed)
        XCTAssertEqual(model.job?.brief, "Goal (as Benji stated it): tea")
        XCTAssertEqual(model.job?.offersContinue, true)
        XCTAssertEqual(model.job?.schedule?.text, "Every day at 09:00")
    }

    /// Follow-ups sent while the user is looking at something new carry a fresh screenshot (the changelog
    /// check of D-172): with Screen on, every message takes its own capture, a job's chip included.
    func testEveryFollowUpTakesAFreshScreenshotWhenScreenIsOn() {
        model.setScreenMode(.on)
        var captures = 0
        model.captureScreen = { done in
            captures += 1
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("benji-fresh-\(UUID().uuidString).jpg")
            FileManager.default.createFile(atPath: url.path, contents: Data([1]))
            done(.success(CapturedScreen(url: url, pixelSize: CGSize(width: 100, height: 60), thumbnail: NSImage(), screenFrame: .zero)))
        }
        model.composerText = "what is this page?"
        model.submit()
        XCTAssertEqual(captures, 1)
        backend.say(.pointedAnswer(text: "A shop.", targets: []))
        backend.finish()
        backend.job(JobSnapshot(id: id, title: "Tea", state: .done, chips: ["Email it to me"]))
        model.askJobChip("Email it to me")
        XCTAssertEqual(captures, 2, "a job's chip is a follow-up like any other: it looks at the screen as it is now")
        XCTAssertEqual(backend.starts.map(\.task), ["what is this page?", "Email it to me"])
    }
}
