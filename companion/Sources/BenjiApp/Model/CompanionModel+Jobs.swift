import AppKit
import Combine
import BenjiCore

extension CompanionModel {
    // MARK: jobs

    /// The notch peeks for the job: during its beat (so Esc can be seen to work), and for news
    /// the user hasn't seen (it needs them, or it ended).
    var jobPeek: Bool {
        guard let job else { return false }
        // News waits while the user is on a call (the row and the resting mark still show it).
        return job.state == .queued || (job.wantsAttention && !jobSeen && quietNow?() == nil)
    }

    func handleJob(_ snapshot: JobSnapshot, now: Date = Date()) {
        // A quiet repeat run of some other job (nothing new) never takes over the row the user
        // is looking at, and makes no sound, no peek and no thread entry.
        if snapshot.quiet, let current = job, current.id != snapshot.id { return }
        let before = job?.id == snapshot.id ? job?.state : nil
        if before == nil { jobStarted[snapshot.id] = jobStarted[snapshot.id] ?? now }
        job = snapshot
        // A job already over when first heard of (the engine's last one, after a restart) is old news.
        jobSeen = (before == nil && !snapshot.state.isLive && snapshot.state != .needsYou) || expanded
        if snapshot.state != .needsYou { answeredJobRequests = [] }
        if !snapshot.quiet, let cue = JobCues.cue(from: before, to: snapshot.state),
           JobCues.isOn(UserDefaults.standard.object(forKey: JobCues.defaultsKey)) {
            onJobCue?(cue)
        }
        watchJobBeat?(snapshot.state == .queued)
        if snapshot.savesThread,
           let thread = JobThread.conversation(snapshot, started: jobStarted[snapshot.id] ?? now, now: now) {
            history.saveJob(thread)
        }
    }

    /// The engine ended with a job in flight: it is lost with it (the record says so at the next start).
    func engineExited() {
        guard let job, job.state.isLive else { return }
        handleJob(JobSnapshot(id: job.id, title: job.title, state: .failed,
                              error: "Benji restarted before this finished.", tainted: job.tainted, taint: job.taint,
                              sites: job.sites, brief: job.brief, run: job.run, canContinue: true,
                              schedule: job.schedule, actSites: job.actSites))
    }

    /// The user's switch for repeating jobs, passed to the engine.
    func setSchedules(_ on: Bool) { backend.setSchedules(on) }

    /// Start the engine at launch when a schedule exists, so it can run while Benji is open and idle.
    func startEngineForSchedules() { backend.startEngineForSchedules() }

    /// The row's Continue: another run of a job that failed or stopped. Only the user's button.
    func continueJob() {
        guard let job, job.offersContinue else { return }
        jobBackend?.continueJob(job.id)
    }

    /// The row's schedule buttons: pause, resume, delete. Only what the schedule offers.
    func scheduleJob(_ action: JobScheduleAction) {
        guard let job, let schedule = job.schedule else { return }
        switch action {
        case .pause where !schedule.canPause, .resume where !schedule.canResume: return
        default: jobBackend?.scheduleJob(job.id, action)
        }
    }

    /// The user's switch for browser reach, passed to the engine.
    func setBrowser(_ on: Bool) { backend.setBrowser(on) }
    func setBrowserAlways(_ sites: [String]) { backend.setBrowserAlways(sites) }

    /// The row's Yes or No. Only the app's own button answers a job's approval. Once per request.
    func answerJob(_ approved: Bool) {
        guard let job, let pending = job.pending, !answeredJobRequests.contains(pending.request) else { return }
        answeredJobRequests.insert(pending.request)
        jobBackend?.answerJob(job.id, request: pending.request, approved: approved)
    }

    func stopJob() {
        guard let job, job.state.isLive else { return }
        jobBackend?.stopJob(job.id)
    }

    /// Esc during the job's beat cancels it before it starts. True when it did.
    @discardableResult
    func jobEscape() -> Bool {
        guard job?.state == .queued else { return false }
        stopJob()
        return true
    }

    /// What the user says to steer the running job; the engine takes it between tool steps.
    @discardableResult
    func steerJob(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let job, job.state == .working || job.state == .needsYou, !t.isEmpty else { return false }
        jobBackend?.steerJob(job.id, text: t)
        return true
    }

    /// Clears a job that is over from the row.
    func dismissJob() {
        guard let job, !job.state.isLive else { return }
        jobBackend?.dismissJob(job.id)
        self.job = nil
        jobExpanded = false
        watchJobBeat?(false)
    }

    /// The job's thread, in the history view like any saved conversation.
    func openJobThread() {
        guard let job else { return }
        openConversation(job.id)
    }

    /// A next-step chip: its words are sent as a typed message, through the gate like any message.
    func askJobChip(_ chip: String) { ask(chip) }

    /// Opens the panel on its settings page (the gear, or the menu bar's Settings…).
    func openSettings(_ section: SettingsSection? = nil) {
        if let section { settings.section = section }
        settings.refresh()
        settingsOpen = true
        setExpanded(true)
    }

    func closeSettings() { settingsOpen = false }

    /// Expand / Shrink in the band; remembered for the next open and the next launch.
    func setPanelExpanded(_ on: Bool, defaults: UserDefaults = .standard) {
        guard on != panelExpanded else { return }
        panelExpanded = on
        defaults.set(on, forKey: PanelGeometry.expandedKey)
    }
}
