import AppKit
import Combine
import BenjiCore

extension CompanionModel {
    // MARK: screen context (Off: never; Ask: one capture after a Yes; On: one capture per message)

    /// One message, typed or spoken, with the screen as the mode says. The display it is about is
    /// latched here, once: the one chosen with Include once, else where a spoken message's talk key
    /// went down, else the panel's display for a typed one. Moving the pointer to answer the Ask card,
    /// or a capture that lands later, never changes it.
    func send(task: String, restoreText: String?, spoken: Bool) {
        let once = includeOnce
        includeOnce = nil
        captureTarget = screenModeInForce == .off ? nil : once ?? (spoken ? voiceDisplay : panelDisplay)
        switch screenModeInForce {
        case .off: run(task: task)
        case .ask where once != nil: startWithScreen(task: task, restoreText: restoreText)   // the user already said yes
        case .ask: askToSendScreen(task: task, restoreText: restoreText ?? task)
        case .on: startWithScreen(task: task, restoreText: restoreText)
        }
    }

    /// Nothing is captured until the user says Send on the card; no answer cancels the message.
    private func askToSendScreen(task: String, restoreText: String?) {
        pendingScreenSend = PendingScreenSend(task: task, restoreText: restoreText)
        settingsOpen = false   // the question needs the panel
        setExpanded(true)
        screenConfirmTimer?.invalidate()
        let serial = turnSerial
        let timer = Timer(timeInterval: ScreenCapturePolicy.confirmTimeout, repeats: false) { [weak self] _ in
            guard let self, serial == self.turnSerial, self.pendingScreenSend != nil else { return }
            self.cancel()
        }
        RunLoop.main.add(timer, forMode: .common)
        screenConfirmTimer = timer
    }

    /// The confirm card's answer: send with the screen, send without it, or cancel the message.
    func decideScreenSend(_ choice: ScreenSendChoice) {
        guard let pending = pendingScreenSend else { return }
        switch choice {
        case .send:
            endScreenConfirm()
            startWithScreen(task: pending.task, restoreText: pending.restoreText)
        case .withoutScreen:
            endScreenConfirm()
            captureTarget = nil
            run(task: pending.task)
        case .cancel:
            if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let text = pending.restoreText {
                composerText = text
            }
            cancel()
        }
    }

    func endScreenConfirm() {
        screenConfirmTimer?.invalidate()
        screenConfirmTimer = nil
        pendingScreenSend = nil
    }

    private func startWithScreen(task: String, restoreText: String?) {
        guard let captureScreen else {
            apply(.backendError("Screen capture isn't available in this build. Your message wasn't sent."))
            return
        }
        let serial = turnSerial
        captureScreen { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let shot):
                guard serial == self.turnSerial else {   // cancelled while capturing
                    try? FileManager.default.removeItem(at: shot.url)
                    return
                }
                if self.permissionAsk == .screenToLook { self.dismissPermissionAsk() }
                let id = UUID().uuidString
                self.thumbnails[id] = shot.thumbnail
                self.sentImageURL = shot.url
                self.apply(.screenAttached(
                    id: id,
                    summary: ScreenCapturePolicy.attachmentSummary(pixelSize: shot.pixelSize, provider: self.providerID,
                                                                   leftOut: shot.leftOut, display: shot.displayName)))
                self.run(task: task, shot: shot)
            case .failure(let error):
                guard serial == self.turnSerial else { return }
                if let denied = error as? ScreenCaptureError, case .permissionNeeded = denied {
                    self.needPermission(.screenToLook, granted: false)
                    // Keep typed or spoken words on the existing Ask card. Nothing has been
                    // sent, and its Without screen action can send this same turn once.
                    self.askToSendScreen(task: task, restoreText: restoreText ?? task)
                    return
                }
                self.apply(.backendError("Screen capture failed: \(error.localizedDescription) Your message wasn't sent."))
                if let restoreText { self.composerText = restoreText }
            }
        }
    }

    func discardSentImage() {
        if let url = sentImageURL { try? FileManager.default.removeItem(at: url) }
        sentImageURL = nil
        stepImageURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        stepImageURLs = []
    }
}

struct PendingScreenSend: Equatable {
    let task: String
    /// Typed or spoken words restored on explicit dismissal, only into an empty composer.
    let restoreText: String?
}

enum ScreenSendChoice {
    case send, withoutScreen, cancel
}
