import AppKit
import Combine
import BenjiCore

extension CompanionModel {
    // MARK: backend → state

    func handle(_ event: BackendEvent) {
        if phoneTaskRunning, event.actsOnTheScreen {
            // A phone task is never offered the screen; if the engine asks anyway, stop rather than ask.
            cancel()
            phoneTaskStatus = "Stopped. Screen control needs the Mac."
            return
        }
        defer { updatePhoneTask() }
        switch event {
        case .tool(let name, let detail):
            producedOutput = true
            apply(.toolProgress(name: name, detail: detail))
        case .answer(let raw):
            // Only screen-context answers may point; the tag is never shown or spoken.
            let (text, targets) = currentShot != nil ? PointingTags.parse(raw) : (raw, [])
            showAnswer(text, targets: targets)
        case .pointedAnswer(let text, let targets):
            showAnswer(text, targets: currentShot != nil ? targets : [])
        case .error(let text):
            producedOutput = true
            apply(.backendError(text))
        case .approval(let action, let target):
            producedOutput = true
            // One at a time: a pending request is never replaced (the serve backend refuses a
            // second one itself; the engine asks one at a time anyway).
            guard state.pendingApproval == nil else { return }
            let req = ApprovalRequest(id: UUID().uuidString, action: action, target: target)
            apply(.approvalRequested(req))
            startApprovalTimer(for: req)
            onApprovalNeeded?(req)
        case let .screenApproval(_, _, step, intent):
            producedOutput = true
            guard state.pendingApproval == nil else { return }
            // The card names the app the step would act in, worded from the step itself, with what
            // it is for and, when Benji's own look asked, why.
            let found = describeScreenStep?(step, currentShot)
            let end = describeScreenStepEnd?(step, currentShot)
            let why = screenAskWhy?.step == step ? screenAskWhy?.why : nil
            screenAskWhy = nil
            let req = ApprovalRequest(id: UUID().uuidString,
                                      action: ScreenStepCard.action(step, app: found?.appName, endApp: end?.appName),
                                      target: ScreenStepCard.target(step, intent: intent, why: why))
            screenCard = (req.id, step, found?.pid, end?.pid)
            apply(.approvalRequested(req))
            startApprovalTimer(for: req)
            onApprovalNeeded?(req)
        case let .driveApproval(goal, seconds):
            producedOutput = true
            guard state.pendingApproval == nil else { return }
            // One card per drive, naming the goal; it declines itself after 45 s and is answered only
            // by its own buttons or ⌘Return (a spoken yes never reaches it).
            let req = ApprovalRequest(id: UUID().uuidString, action: DriveCopy.cardAction,
                                      target: DriveCopy.cardTarget(goal: goal))
            driveCardID = req.id
            apply(.approvalRequested(req))
            startApprovalTimer(for: req, timeout: min(seconds, DriveCopy.cardSeconds))
            onApprovalNeeded?(req)
        case .drive(let event):
            producedOutput = true
            driveEvent(event)
        case let .screenAction(request, step, mode, intent, drive):
            producedOutput = true
            if drive, driveGoal != nil, let step {
                doDriveScreenStep(request: request, step: step, mode: mode, intent: intent)
            } else if let mode, let step {
                doSimpleScreenStep(request: request, step: step, mode: mode, intent: intent)
            } else {
                doScreenStep(request: request, step: step)
            }
        case .delta(let piece):
            producedOutput = true
            latency.mark(.firstText, at: Self.now())
            latency.streamed = true
            rawStream += piece
            let visible = StreamingReply.visible(rawStream)
            let shown = visible.trimmingCharacters(in: .whitespacesAndNewlines)
            if shown != streamingText { streamingText = shown }
            guard speaksWhileStreaming else { break }
            for sentence in sentences.feed(visible) {
                let plain = SpeechText.plain(sentence)
                guard !plain.isEmpty else { continue }
                latency.mark(.firstSentence, at: Self.now())
                speechStreamOpen = true
                speechForRun = true
                speakingTypedAnswer = !voiceTurn
                awaitsAudio = true
                onSpeakSentence?(plain)
            }
        case .cardLine, .cardEnd:
            break   // the card stage's (ExplainCardBackend); never shown or said
        case .deltaReset:
            rawStream = ""
            if !streamingText.isEmpty { streamingText = "" }
            sentences.reset()   // what was said stays said; the answer starts a new segment
        case .carriedTaint(let taint):
            keepTaint(taint)      // `listen` takes these first; kept here too for a direct call
        case .accepted:
            latency.mark(.accepted, at: Self.now())
            apply(.engineAccepted)   // not output: a run that then says nothing is still a failure
        case .activity(let kind, let name):
            producedOutput = true
            if let activity = TurnActivity(kind: kind, name: name) { apply(.activity(activity)) }
        }
    }

    /// Acts on the step the user just approved (only that one, once) on the latest screenshot,
    /// then tells the engine how it went. The screen after it is the turn's screenshot from now on:
    /// the next step's coordinates and the answer's marks are in its pixels.
    private func doScreenStep(request: String, step: ScreenStep?) {
        guard let step else { return backend.finishScreenStep(request: request, result: .refused(.unreadable)) }
        guard let approval = screenGate.take(step) else {
            return backend.finishScreenStep(request: request, result: .refused(.notApproved))
        }
        guard let shot = currentShot, let performScreenStep else {
            return backend.finishScreenStep(request: request, result: .refused(.noScreenshot))
        }
        let run = runs.live
        performScreenStep(step, shot, approval.appPID, approval.endAppPID) { [weak self] outcome in
            guard let self, let run, self.runs.admits(run) else {   // cancelled meanwhile
                if let url = outcome.shot?.url { try? FileManager.default.removeItem(at: url) }
                return
            }
            if let next = outcome.shot {
                self.stepImageURLs.append(next.url)
                self.currentShot = next
            }
            if outcome.status == .stopped {
                self.screenStopped = true
                self.showNote(ScreenActionPolicy.tookOverLine)
            }
            self.backend.finishScreenStep(request: request, result: ScreenStepResult(
                status: outcome.status, text: outcome.text, imagePath: outcome.shot?.url.path))
        }
    }

    /// A step the engine didn't ask about, free or quiet. The app checks it again before
    /// anything shows: the setting, a take-over earlier this turn, and the class from the step and
    /// the model's confidence (the engine is trusted only on whether the message asked for text).
    /// Then the actuator rings it, looks at what is really there and may still answer "ask".
    private func doSimpleScreenStep(request: String, step: ScreenStep, mode: ScreenStepClass, intent: ScreenStepIntent?) {
        guard actsOnSimpleSteps() else {
            return backend.finishScreenStep(request: request, result: .ask("you chose to be asked before every step"))
        }
        if screenStopped {
            return backend.finishScreenStep(request: request, result: ScreenStepResult(
                status: .stopped, text: ScreenActionPolicy.tookOverLine + ", so nothing was done."))
        }
        let (planned, why) = ScreenStepClassifier.plan(step, intent: intent, askEveryStep: false, askedForText: true,
                                                       unaskedSoFar: unaskedSteps)
        let mode = max(planned, mode)
        if mode == .asked {
            screenAskWhy = (step, why)
            return backend.finishScreenStep(request: request, result: .ask(why))
        }
        guard let shot = currentShot, let performSimpleScreenStep else {
            return backend.finishScreenStep(request: request, result: .refused(.noScreenshot))
        }
        apply(.screenActing(ScreenAutonomy.actingLine(step, app: describeScreenStep?(step, shot)?.appName)))
        if !watchingScreenTurn {
            watchingScreenTurn = true
            watchScreenTurn?(true)
        }
        let run = runs.live
        performSimpleScreenStep(step, shot, mode) { [weak self] outcome in
            guard let self, let run, self.runs.admits(run) else {   // cancelled meanwhile
                if let url = outcome.shot?.url { try? FileManager.default.removeItem(at: url) }
                return
            }
            self.apply(.screenActingEnded)
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
            case .done:
                self.unaskedSteps += 1
            default:
                break
            }
            self.backend.finishScreenStep(request: request, result: ScreenStepResult(
                status: outcome.status, text: outcome.text, imagePath: outcome.shot?.url.path))
        }
    }

    /// Esc between steps while a turn acts unasked: the next step is stopped, and the engine is
    /// told so when it asks for it.
    func screenTurnEscape() {
        guard runs.isLive, watchingScreenTurn, !screenStopped else { return }
        screenStopped = true
        apply(.screenActingEnded)
        showNote(ScreenActionPolicy.tookOverLine)
    }
}
