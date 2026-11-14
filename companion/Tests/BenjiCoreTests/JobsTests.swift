import XCTest
@testable import BenjiCore

/// Background jobs, the app's side (D-130 step 1): the `job` event, the shown state it carries (derived
/// by the engine in code), the row's and the peek's words, the cue mapping, the thread, and the
/// protocol lines.
final class JobsTests: XCTestCase {
    let id = "5b0f3a52-2c61-4f0e-9d0a-0f5a1c1a7e11"

    private func event(_ job: String) -> ServeEvent? {
        ServeEvent.decode(#"{"type":"job","job":\#(job)}"#)
    }

    // MARK: the event

    func testAWorkingJobDecodes() {
        let e = event(#"{"id":"\#(id)","title":"Headphones","state":"working","line":"Reading a page","pending":null,"spoken":"","files":[],"chips":[],"error":"","tainted":true}"#)
        XCTAssertEqual(e, .job(JobSnapshot(id: id, title: "Headphones", state: .working, line: "Reading a page",
                                           tainted: true)))
    }

    func testAParkedJobCarriesTheApprovalItWaitsOn() {
        guard case let .job(job)? = event(#"{"id":"\#(id)","title":"H","state":"needs-you","line":"","pending":{"request":"a1","action":"write a file (Benji read a web page this turn)","target":"/x/pairs.md"}}"#) else {
            return XCTFail("not a job")
        }
        XCTAssertEqual(job.state, .needsYou)
        XCTAssertEqual(job.pending, JobPending(request: "a1", action: "write a file (Benji read a web page this turn)",
                                               target: "/x/pairs.md"))
    }

    func testAPendingRequestOnAJobThatIsNotParkedIsIgnored() {
        guard case let .job(job)? = event(#"{"id":"\#(id)","title":"H","state":"working","pending":{"request":"a1","action":"x","target":"y"}}"#) else {
            return XCTFail("not a job")
        }
        XCTAssertNil(job.pending, "only a job the engine says needs you has a card")
    }

    func testADoneJobHasItsTurnEnd() {
        guard case let .job(job)? = event(#"{"id":"\#(id)","title":"H","state":"done","spoken":"Two pairs fit.","files":[{"name":"pairs.md","path":"/j/output/pairs.md"},{"name":"x"}],"chips":["Email it","Add prices","Check reviews","Fourth"]}"#) else {
            return XCTFail("not a job")
        }
        XCTAssertEqual(job.spoken, "Two pairs fit.")
        XCTAssertEqual(job.files, [JobFile(name: "pairs.md", path: "/j/output/pairs.md")], "a file without a path is dropped")
        XCTAssertEqual(job.chips, ["Email it", "Add prices", "Check reviews"], "at most three chips")
    }

    func testAnUnknownStateOrNoIdIsNotAJob() {
        XCTAssertEqual(event(#"{"id":"\#(id)","title":"H","state":"sleeping"}"#), .unknown(type: "job"))
        XCTAssertEqual(event(#"{"title":"H","state":"done"}"#), .unknown(type: "job"))
        XCTAssertEqual(ServeEvent.decode(#"{"type":"job"}"#), .unknown(type: "job"))
    }

    func testEveryStateTheEngineCanDeriveIsOneTheAppKnows() {
        // benji/jobs.py STATES.
        XCTAssertEqual(Set(JobState.allCases.map(\.rawValue)),
                       ["queued", "working", "needs-you", "done", "failed", "stopped"])
        XCTAssertEqual(JobState.allCases.filter(\.isLive), [.queued, .working, .needsYou])
    }

    func testReadyAnnouncesJobs() {
        guard case let .ready(r)? = ServeEvent.decode(#"{"type":"ready","protocol":1,"version":"v","provider":"p","model":"m","destination":"d","jobs":true}"#) else {
            return XCTFail("not ready")
        }
        XCTAssertTrue(r.jobs)
        guard case let .ready(old)? = ServeEvent.decode(#"{"type":"ready","protocol":1,"version":"v","provider":"p","model":"m","destination":"d"}"#) else {
            return XCTFail("not ready")
        }
        XCTAssertFalse(old.jobs, "an older engine doesn't say")
    }

    // MARK: words

    func testTheRowSaysWhatTheJobIsDoing() {
        func job(_ state: JobState, line: String = "", spoken: String = "", error: String = "",
                 pending: JobPending? = nil) -> JobSnapshot {
            JobSnapshot(id: id, title: "Headphones", state: state, line: line, pending: pending, spoken: spoken, error: error)
        }
        XCTAssertEqual(job(.queued).detail, "Starting · Esc cancels")
        XCTAssertEqual(job(.working).detail, "Working")
        XCTAssertEqual(job(.working, line: "Reading a page").detail, "Reading a page")
        XCTAssertEqual(job(.needsYou, pending: JobPending(request: "a1", action: "write a file", target: "")).detail,
                       "Waiting for your answer")
        XCTAssertEqual(job(.done, spoken: "Two fit.").detail, "Two fit.")
        XCTAssertEqual(job(.done).detail, "Done")
        XCTAssertEqual(job(.failed, error: "Benji restarted before this finished.").detail,
                       "Benji restarted before this finished.")
        XCTAssertEqual(job(.stopped).detail, "Stopped")
    }

    func testThePeekSpeaksOnlyForAJobWorthIt() {
        func peek(_ state: JobState, spoken: String = "") -> String? {
            JobSnapshot(id: id, title: "Headphones", state: state, line: "Reading a page", spoken: spoken).peekLine
        }
        XCTAssertEqual(peek(.queued), "Starting “Headphones” · Esc cancels")
        XCTAssertEqual(peek(.working), "Headphones: Reading a page")
        XCTAssertEqual(peek(.needsYou), "Headphones needs you")
        XCTAssertEqual(peek(.done, spoken: "Two fit."), "Two fit.")
        XCTAssertEqual(peek(.failed), "Headphones didn't finish")
        XCTAssertNil(peek(.stopped), "a job the user stopped says nothing")
    }

    // MARK: the written line (D-146)

    func testTheRowPeekAndThreadShowTheWrittenLineNotTheSpokenOne() throws {
        let job = JobSnapshot(id: id, title: "Tea", state: .done, spoken: "I saved output slash tea dot txt.",
                              written: "I saved output/tea.txt.", files: [JobFile(name: "tea.txt", path: "/j/tea.txt")])
        XCTAssertEqual(job.detail, "I saved output/tea.txt.")
        XCTAssertEqual(job.peekLine, "I saved output/tea.txt.")
        XCTAssertEqual(job.spoken, "I saved output slash tea dot txt.", "the speaker still has its own line")
        let thread = try XCTUnwrap(JobThread.conversation(job, started: Date(timeIntervalSince1970: 1),
                                                          now: Date(timeIntervalSince1970: 2)))
        XCTAssertEqual(thread.lines.last?.text, "I saved output/tea.txt.\n\nFiles: tea.txt")
    }

    func testAnEngineThatSendsOnlyTheSpokenLineStillShowsSomething() {
        let job = JobSnapshot(id: id, title: "Tea", state: .done, spoken: "Two fit.")
        XCTAssertEqual(job.shownResult, "Two fit.")
        XCTAssertEqual(job.detail, "Two fit.")
        XCTAssertEqual(JobSnapshot(id: id, title: "Tea", state: .done).detail, "Done")
    }

    func testTheWrittenAndTaintFieldsDecode() {
        guard case let .job(job)? = event(#"{"id":"\#(id)","title":"H","state":"done","spoken":"Saved output slash a dot md.","written":"Saved output/a.md.","tainted":true,"taint":"screen"}"#) else {
            return XCTFail("not a job")
        }
        XCTAssertEqual(job.written, "Saved output/a.md.")
        XCTAssertEqual(job.taint, "screen")
        guard case let .job(old)? = event(#"{"id":"\#(id)","title":"H","state":"done","spoken":"Two fit.","tainted":true}"#) else {
            return XCTFail("not a job")
        }
        XCTAssertEqual(old.written, "")
        XCTAssertEqual(old.taint, "")
    }

    // MARK: the label under a tainted job (D-146)

    func testTheLabelSaysWhatActuallyApplies() {
        func line(_ tainted: Bool, _ taint: String) -> String? {
            JobSnapshot(id: id, title: "t", state: .working, tainted: tainted, taint: taint).taintLine
        }
        XCTAssertEqual(line(true, "screen"), "Benji looked at your screen, so changes ask first.")
        let general = "It read outside content, so everything it changes asks first."
        for taint in ["web", "browser", "file", "screen+web", "screen+browser", "screen+file", "web+browser", ""] {
            XCTAssertEqual(line(true, taint), general, "\(taint.isEmpty ? "an engine that doesn't say" : taint) keeps the general wording")
        }
        XCTAssertNil(line(false, ""), "a job that read nothing shows no line")
        XCTAssertNil(line(false, "screen"))
    }

    func testOnlyNewsWantsAttention() {
        let wants = JobState.allCases.filter { JobSnapshot(id: id, title: "t", state: $0).wantsAttention }
        XCTAssertEqual(wants, [.needsYou, .done, .failed])
    }

    // MARK: cues

    func testCuesMapToDoneNeedsApprovalAndError() {
        XCTAssertEqual(JobCues.cue(from: .working, to: .done), .done)
        XCTAssertEqual(JobCues.cue(from: .working, to: .needsYou), .needsApproval)
        XCTAssertEqual(JobCues.cue(from: .needsYou, to: .failed), .error)
        XCTAssertNil(JobCues.cue(from: .queued, to: .working))
        XCTAssertNil(JobCues.cue(from: .working, to: .stopped), "stopping is the user's own act")
        XCTAssertNil(JobCues.cue(from: .done, to: .done), "no cue for a snapshot that changed nothing")
        XCTAssertEqual(JobCues.cue(from: nil, to: .done), .done)
    }

    func testCuesAreOffUntilSwitchedOn() {
        XCTAssertFalse(JobCues.isOn(nil))
        XCTAssertTrue(JobCues.isOn(true))
        XCTAssertTrue(JobsSetting.isOn(nil), "jobs themselves are on unless switched off")
        XCTAssertFalse(JobsSetting.isOn(false))
    }

    // MARK: the thread

    func testADoneJobsThreadIsASavedConversationUnderItsId() throws {
        let job = JobSnapshot(id: id, title: "Compare headphones", state: .done, spoken: "Two fit.",
                              files: [JobFile(name: "pairs.md", path: "/j/pairs.md")])
        let start = Date(timeIntervalSince1970: 1_000), end = Date(timeIntervalSince1970: 2_000)
        let thread = try XCTUnwrap(JobThread.conversation(job, started: start, now: end))
        XCTAssertEqual(thread.id, id)
        XCTAssertEqual(thread.title, "Job · Compare headphones")
        XCTAssertEqual(thread.lines.map(\.role), [.system, .assistant])
        XCTAssertEqual(thread.lines.last?.text, "Two fit.\n\nFiles: pairs.md")
        XCTAssertEqual(thread.started, start)
    }

    func testEachStateHasItsLine() throws {
        func lines(_ state: JobState, error: String = "") throws -> [SavedLine.Role] {
            let job = JobSnapshot(id: id, title: "t", state: state,
                                  pending: state == .needsYou ? JobPending(request: "a", action: "write", target: "") : nil,
                                  error: error)
            return try XCTUnwrap(JobThread.conversation(job, started: Date(), now: Date())).lines.map(\.role)
        }
        XCTAssertEqual(try lines(.working), [.system])
        XCTAssertEqual(try lines(.needsYou), [.system, .system])
        XCTAssertEqual(try lines(.failed, error: "boom"), [.system, .error])
        XCTAssertEqual(try lines(.stopped), [.system, .system])
    }

    func testAJobIdThatIsNotAUUIDHasNoThread() {
        XCTAssertNil(JobThread.conversation(JobSnapshot(id: "../x", title: "t", state: .done), started: Date(), now: Date()))
    }

    // MARK: the notch

    func testTheNotchPeeksForAJobOnlyWhenNothingElseIsGoingOn() {
        func size(_ phase: CompanionPhase, peek: Bool, opened: Bool = false) -> NotchSize {
            NotchPresence.targetSize(NotchPresenceInputs(phase: phase, userOpened: opened, jobPeek: peek))
        }
        XCTAssertEqual(size(.idle, peek: true), .peek)
        XCTAssertEqual(size(.idle, peek: false), .closed)
        XCTAssertEqual(size(.idle, peek: true, opened: true), .open)
        XCTAssertEqual(size(.awaitingApproval, peek: true), .open, "a turn's own approval still opens the panel")
    }

    func testAParkedJobShowsAsAnApprovalInThePeek() {
        let parked = JobSnapshot(id: id, title: "H", state: .needsYou,
                                 pending: JobPending(request: "a1", action: "write a file", target: ""))
        let info = NotchStatusInfo.make(CompanionState(), job: parked)
        XCTAssertEqual(info.status, .approval)
        XCTAssertEqual(info.tint, .approval)
        XCTAssertEqual(info.line, "H needs you: write a file")
        XCTAssertEqual(NotchStatusInfo.make(CompanionState(), job: JobSnapshot(id: id, title: "H", state: .done, spoken: "Done it.")).status, .done)
        XCTAssertEqual(NotchStatusInfo.make(CompanionState(), job: JobSnapshot(id: id, title: "H", state: .failed)).status, .error)
        XCTAssertEqual(NotchStatusInfo.make(CompanionState(), job: JobSnapshot(id: id, title: "H", state: .stopped)).status, .ready)
        XCTAssertEqual(NotchStatusInfo.make(CompanionState()).status, .ready, "no job: as before")
    }

    // MARK: the protocol

    private func object(_ r: ServeRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: r.line()) as? [String: Any])
    }

    func testJobRequests() throws {
        XCTAssertEqual(try object(.jobStop(job: id)) as NSDictionary, ["type": "job_stop", "job": id])
        XCTAssertEqual(try object(.jobSteer(job: id, text: "only Lisbon")) as NSDictionary,
                       ["type": "job_steer", "job": id, "text": "only Lisbon"])
        XCTAssertEqual(try object(.jobDismiss(job: id)) as NSDictionary, ["type": "job_dismiss", "job": id])
    }

    func testAJobsApprovalIsTheOrdinaryApproveNamingTheJob() throws {
        XCTAssertEqual(try object(.approve(id: id, request: "a1", approved: true)) as NSDictionary,
                       ["type": "approve", "id": id, "request": "a1", "decision": "yes"])
    }

    func testSendSaysJobsOnlyWhenTheAppShowsThem() throws {
        XCTAssertNil(try object(.send(id: "t1", text: "x", imagePath: nil, allowPointing: false))["jobs"])
        XCTAssertEqual(try object(.send(id: "t1", text: "x", imagePath: nil, allowPointing: false, jobs: true))["jobs"] as? Bool, true)
    }

    // MARK: second pass (D-172)

    func testTheSecondPassFieldsDecodeAndAnOlderEngineSendsNone() {
        guard case let .job(job)? = event(#"""
        {"id":"\#(id)","title":"Tea","state":"done","written":"Two things.","brief":"Goal (as Benji stated it): watch tea","run":3,
         "done":"Looked at three shops.","left":"The fourth shop.","ask":"Shall I check the fourth shop?","stopped_at_limit":false,
         "can_continue":false,"unattended":true,"news":false,"quiet":true,
         "schedule":{"text":"Every day at 09:00","next":1700000000.5,"paused":false,"reason":"","last":1699990000,"switch_on":true}}
        """#) else { return XCTFail("not a job") }
        XCTAssertEqual(job.brief, "Goal (as Benji stated it): watch tea")
        XCTAssertEqual(job.run, 3)
        XCTAssertEqual(job.reportBack, ["Done: Looked at three shops.", "Left: The fourth shop.", "Shall I check the fourth shop?"])
        XCTAssertTrue(job.unattended)
        XCTAssertFalse(job.news)
        XCTAssertTrue(job.quiet)
        XCTAssertEqual(job.schedule?.text, "Every day at 09:00")
        XCTAssertEqual(job.schedule?.next, Date(timeIntervalSince1970: 1_700_000_000.5))
        XCTAssertEqual(job.schedule?.last, Date(timeIntervalSince1970: 1_699_990_000))
        guard case let .job(old)? = event(#"{"id":"\#(id)","title":"H","state":"done","spoken":"Done."}"#) else { return XCTFail("not a job") }
        XCTAssertEqual(old.run, 1)
        XCTAssertEqual(old.brief, "")
        XCTAssertNil(old.schedule)
        XCTAssertTrue(old.news)
        XCTAssertFalse(old.quiet)
        XCTAssertFalse(old.offersContinue)
        XCTAssertEqual(old.reportBack, [])
    }

    func testAScheduleWithNoWordsOrAWrongShapeIsNoSchedule() {
        guard case let .job(a)? = event(#"{"id":"\#(id)","title":"H","state":"done","schedule":{"text":"","next":1}}"#),
              case let .job(b)? = event(#"{"id":"\#(id)","title":"H","state":"done","schedule":"every day"}"#) else { return XCTFail("not a job") }
        XCTAssertNil(a.schedule)
        XCTAssertNil(b.schedule)
    }

    func testAQuietRunMakesNoPeekAndWantsNoAttention() {
        let quietDone = JobSnapshot(id: id, title: "Tea", state: .done, written: "Same.", news: false, quiet: true)
        XCTAssertNil(quietDone.peekLine)
        XCTAssertFalse(quietDone.wantsAttention)
        let newsDone = JobSnapshot(id: id, title: "Tea", state: .done, written: "A third.", quiet: false)
        XCTAssertEqual(newsDone.peekLine, "A third.")
        XCTAssertTrue(newsDone.wantsAttention)
        let parked = JobSnapshot(id: id, title: "Tea", state: .needsYou,
                                 pending: JobPending(request: "a1", action: "write a file", target: "/x"), unattended: true)
        XCTAssertTrue(parked.wantsAttention, "a repeat run that needs the user is never quiet")
        XCTAssertFalse(quietDone.savesThread)
        XCTAssertTrue(newsDone.savesThread)
    }

    func testAJobThatStoppedAtItsLimitSaysSoAndOffersContinue() {
        let job = JobSnapshot(id: id, title: "Long", state: .stopped, written: "Stopped at the step limit. Done: the index.",
                              ask: "Shall I carry on?", stoppedAtLimit: true, canContinue: true)
        XCTAssertEqual(job.detail, "Stopped at the step limit. Done: the index.")
        XCTAssertEqual(job.peekLine, "Long stopped at its step limit")
        XCTAssertTrue(job.wantsAttention)
        XCTAssertTrue(job.offersContinue)
        let plain = JobSnapshot(id: id, title: "Long", state: .stopped, canContinue: true)
        XCTAssertEqual(plain.detail, "Stopped")
        XCTAssertNil(plain.peekLine, "stopped by the user: no peek")
        XCTAssertFalse(plain.wantsAttention)
        let thread = JobThread.conversation(job, started: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 60))
        XCTAssertTrue(thread?.lines.last?.text.contains("Stopped at the step limit") == true)
        XCTAssertTrue(thread?.lines.last?.text.contains("Shall I carry on?") == true)
    }

    func testOnlyAFailedOrStoppedJobOffersContinue() {
        for state in JobState.allCases {
            let job = JobSnapshot(id: id, title: "H", state: state, canContinue: true)
            XCTAssertEqual(job.offersContinue, state == .failed || state == .stopped, "\(state)")
        }
        XCTAssertFalse(JobSnapshot(id: id, title: "H", state: .failed, canContinue: false).offersContinue)
    }

    func testTheRowLineSaysWhatRepeatsAndWhenWithTheCalendarGiven() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US_POSIX")
        let now = Date(timeIntervalSince1970: 1_700_000_000)            // Tue 2023-11-14 22:13 UTC
        let at = { (offset: TimeInterval) in Date(timeIntervalSince1970: 1_700_000_000 + offset) }
        let line = { (s: JobSchedule) in s.rowLine(now: now, calendar: cal, locale: locale) }
        XCTAssertEqual(line(JobSchedule(text: "Every day at 09:00", next: at(3600))), "Every day at 09:00 · next today 23:13")
        XCTAssertEqual(line(JobSchedule(text: "Every day at 09:00", next: at(11 * 3600))), "Every day at 09:00 · next tomorrow 09:13")
        XCTAssertEqual(line(JobSchedule(text: "Every Monday at 07:30", next: at(5 * 86400))), "Every Monday at 07:30 · next Sun 22:13")
        XCTAssertEqual(line(JobSchedule(text: "Every day at 09:00, paused", paused: true, reason: "user")), "Every day at 09:00, paused")
        XCTAssertEqual(line(JobSchedule(text: "Every hour", next: at(60), switchOn: false)),
                       "Every hour · all repeating is switched off in Settings")
        XCTAssertTrue(JobSchedule(text: "x").canPause)
        XCTAssertTrue(JobSchedule(text: "x", paused: true).canResume)
    }

    func testTheNewRequestsAndTheScheduleFlagOnSend() throws {
        XCTAssertEqual(try object(.jobContinue(job: id)) as NSDictionary, ["type": "job_continue", "job": id])
        XCTAssertEqual(try object(.jobSchedule(job: id, action: .pause)) as NSDictionary,
                       ["type": "job_schedule", "job": id, "action": "pause"])
        XCTAssertEqual(try object(.jobSchedule(job: id, action: .resume))["action"] as? String, "resume")
        XCTAssertEqual(try object(.jobSchedule(job: id, action: .delete))["action"] as? String, "delete")
        XCTAssertEqual(try object(.schedulesSet(enabled: false)) as NSDictionary, ["type": "schedules_set", "enabled": false])
        XCTAssertNil(try object(.send(id: "t1", text: "x", imagePath: nil, allowPointing: false, jobs: true))["schedules"])
        XCTAssertEqual(try object(.send(id: "t1", text: "x", imagePath: nil, allowPointing: false, jobs: true, schedules: true))["schedules"] as? Bool, true)
        XCTAssertNil(try object(.send(id: "t1", text: "x", imagePath: nil, allowPointing: false, jobs: false, schedules: true))["schedules"],
                     "no jobs, no schedules")
    }

    func testReadyTellsWhetherTheEngineCarriesOutSchedules() {
        guard case let .ready(new)? = ServeEvent.decode(#"{"type":"ready","protocol":1,"version":"1","provider":"p","model":"m","destination":"d","jobs":true,"schedules":true}"#),
              case let .ready(old)? = ServeEvent.decode(#"{"type":"ready","protocol":1,"version":"1","provider":"p","model":"m","destination":"d","jobs":true}"#) else {
            return XCTFail("not ready")
        }
        XCTAssertTrue(new.schedules)
        XCTAssertFalse(old.schedules, "an older engine is never sent schedule requests")
    }

    func testTheSchedulesSwitchIsOnUnlessSetOffAndTheAppFindsSchedulesOnDisk() throws {
        XCTAssertTrue(JobSchedulesSetting.isOn(nil))
        XCTAssertFalse(JobSchedulesSetting.isOn(false))
        XCTAssertTrue(JobSchedulesSetting.isOn(true))
        XCTAssertTrue(JobSchedulesSetting.isOn("NO"), "only a real boolean changes it, as the other switches; anything else leaves it on")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("benji-sched-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(JobSchedulesSetting.existsOnDisk(jobsFolder: dir))
        for name in ["\(id).schedule.json.bad", "\(id).schedule.json.tmp", "not-an-id.schedule.json", "\(id)"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("{}".utf8))
        }
        XCTAssertFalse(JobSchedulesSetting.existsOnDisk(jobsFolder: dir), "a bad, temporary or oddly named file is no schedule")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("\(id).schedule.json").path, contents: Data("{}".utf8))
        XCTAssertTrue(JobSchedulesSetting.existsOnDisk(jobsFolder: dir))
        XCTAssertFalse(JobSchedulesSetting.existsOnDisk(jobsFolder: dir.appendingPathComponent("missing")))
    }
}
