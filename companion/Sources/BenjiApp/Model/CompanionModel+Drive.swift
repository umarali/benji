import AppKit
import Combine
import BenjiCore

extension CompanionModel {
    // MARK: drive

    /// The engine says the drive began or ended. It begins only if the user pressed Yes on its card;
    /// anything else is refused and told to the engine as a stop.
    func driveEvent(_ event: DriveEvent) {
        switch event.state {
        case .active:
            guard driveGranted else {
                backend.stopDrive(reason: "user_stop")
                return
            }
            driveGranted = false
            driveGoal = event.goal
            drivePaused = false
            handBack = DriveHandBack(pointer: NSEvent.mouseLocation)
            watchDrive?(true)
            apply(.screenActing(DriveCopy.activeLine(goal: event.goal)))
        case .ended:
            finishDrive()
            let line = event.written.isEmpty ? event.spoken : event.written
            if !line.isEmpty { showNote(line) }
        }
    }

    func finishDrive() {
        driveGranted = false
        driveResumeTimer?.invalidate()
        driveResumeTimer = nil
        drivePaused = false
        guard driveGoal != nil else { return }
        driveGoal = nil
        watchDrive?(false)
        apply(.screenActingEnded)
    }

    /// One input of the user's while a drive is on (the app's monitor calls this; Benji's own
    /// events never get here). Esc, typing, a click or a scroll hand the screen back at once; a
    /// move of the mouse pauses and nudges, and a long run of it hands the screen back.
    func driveInput(_ input: DriveHandBack.Input, at now: Double = CompanionModel.uptime()) {
        guard let goal = driveGoal else { return }
        switch handBack.observe(input, at: now) {
        case .none:
            break
        case .paused:
            if !drivePaused {
                drivePaused = true
                apply(.screenActing(DriveCopy.pausedLine(goal: goal)))
            }
            scheduleResume()
        case .handBack(let reason):
            endDriveByUser(reason)
        }
    }

    private func scheduleResume() {
        driveResumeTimer?.invalidate()
        let timer = Timer(timeInterval: DriveHandBack.resumeAfter, repeats: false) { [weak self] _ in
            guard let self, let goal = self.driveGoal, self.drivePaused else { return }
            if self.handBack.isPaused(at: Self.uptime()) { return self.scheduleResume() }
            self.drivePaused = false
            self.apply(.screenActing(DriveCopy.activeLine(goal: goal)))
        }
        RunLoop.main.add(timer, forMode: .common)
        driveResumeTimer = timer
    }

    /// The user ended the drive (Esc, typing, a click, a scroll, a long move of the mouse, or the
    /// Stop button): the step in flight stops, the engine is told why, and no more steps this turn.
    func endDriveByUser(_ reason: DriveHandBack.Reason) {
        guard driveGoal != nil else { return }
        screenStopped = true
        let why: String
        switch reason {
        case .escape: why = "user_stop"
        case .typing: why = "typing"
        case .click: why = "click"
        case .scroll: why = "scroll"
        case .movement: why = "mouse"
        }
        backend.stopDrive(reason: why)
        handBackDriveStep?()
        finishDrive()
        showNote(reason == .movement ? "Handed back: you moved the mouse." : ScreenActionPolicy.tookOverLine)
    }

    /// A step inside a drive. The step the user approved on a card (`mode` nil) is the one-use gate's;
    /// a step sent unasked is classed again here: the drive's plan can only raise what the engine
    /// said, and the actuator looks at the point and may raise it again (never lower).
    func doDriveScreenStep(request: String, step: ScreenStep, mode: ScreenStepClass?, intent: ScreenStepIntent?) {
        if screenStopped {
            return backend.finishScreenStep(request: request, result: ScreenStepResult(
                status: .stopped, text: ScreenActionPolicy.tookOverLine + ", so nothing was done."))
        }
        var approvedPID: Int32?
        var approvedEndPID: Int32?
        var cls: DriveClass?
        if let mode {
            guard actsOnSimpleSteps() else {
                return backend.finishScreenStep(request: request, result: .ask("you chose to be asked before every step"))
            }
            let (planned, why) = DriveClassifier.plan(step, intent: intent)
            let combined = max(planned, DriveClass(mode))
            if combined == .denied {
                return backend.finishScreenStep(request: request, result: ScreenStepResult(status: .refused, text: why))
            }
            if combined == .asked {
                screenAskWhy = (step, why)
                return backend.finishScreenStep(request: request, result: .ask(why))
            }
            cls = combined
        } else {
            guard let approval = screenGate.take(step) else {
                return backend.finishScreenStep(request: request, result: .refused(.notApproved))
            }
            approvedPID = approval.appPID
            approvedEndPID = approval.endAppPID
        }
        guard let shot = currentShot, let performDriveStep else {
            return backend.finishScreenStep(request: request, result: .refused(.noScreenshot))
        }
        let run = runs.live
        performDriveStep(step, shot, approvedPID, approvedEndPID, cls) { [weak self] outcome in
            guard let self, let run, self.runs.admits(run) else {   // cancelled meanwhile
                if let url = outcome.shot?.url { try? FileManager.default.removeItem(at: url) }
                return
            }
            if let next = outcome.shot {
                self.stepImageURLs.append(next.url)
                self.currentShot = next
            }
            switch outcome.status {
            case .stopped:
                self.screenStopped = true
                self.showNote(ScreenActionPolicy.tookOverLine)
            case .ask:
                self.screenAskWhy = (step, outcome.text)
            default:
                break
            }
            self.backend.finishScreenStep(request: request, result: ScreenStepResult(
                status: outcome.status, text: outcome.text, imagePath: outcome.shot?.url.path))
        }
    }
}
