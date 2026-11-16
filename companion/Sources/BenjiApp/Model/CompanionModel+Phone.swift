import Foundation
import BenjiCore

/// Phone control (docs/remote-control.md). The phone sends commands through `RemoteControl`; this is
/// where each is checked against what the Mac is doing, and where the phone's view of its own task is
/// kept. The phone's task runs in the Mac's conversation, as text, one at a time.
extension CompanionModel {
    // MARK: phone control

    /// The Mac can take a task from the phone now: nothing running, listening, waiting on the screen
    /// card or running in the background.
    var phoneMayStartTask: Bool {
        !state.isBusy && !runs.isLive && !conversationOn && pendingScreenSend == nil && !(job?.state.isLive ?? false)
    }

    /// What the phone page is shown: whether it may send, why not, and its own task. Never a line from
    /// before the task, and never a job's approval.
    var remoteSnapshot: [String: Any] {
        let available = phoneMayStartTask
        var result: [String: Any] = ["available": available]
        if !available {
            if phoneTaskRunning { result["unavailableReason"] = "Benji is working on your task. You can stop it below." }
            else if job?.state.isLive == true { result["unavailableReason"] = "Finish or stop the background job on your Mac first." }
            else if pendingScreenSend != nil { result["unavailableReason"] = "Answer the screen prompt on your Mac first." }
            else if conversationOn || state.phase == .listening || state.phase == .transcribing {
                result["unavailableReason"] = "Finish the voice conversation on your Mac first."
            } else { result["unavailableReason"] = "Benji is busy on your Mac. Wait for it to finish." }
        }
        guard let id = phoneTaskID else { return result }
        var task: [String: Any] = ["id": id, "text": phoneTaskText, "running": phoneTaskRunning,
                                   "status": phoneTaskStatus, "lines": phoneLines, "stream": phoneStream]
        if let req = phoneApproval {
            if phoneAnswersApprovals() {
                task["approval"] = ["id": req.id, "action": req.action, "target": req.target]
            } else {
                // No request id: the page shows it without buttons, and an answer couldn't name it.
                task["approval"] = ["action": req.action, "target": req.target]
                task["status"] = "Waiting for your answer on the Mac"
            }
        } else if phoneTaskRunning && state.pendingApproval != nil {
            task["status"] = "Needs a decision on the Mac. This approval can't be shown on the phone."
        }
        result["task"] = task
        return result
    }

    /// The approval waiting now, if the phone may see it: an ordinary one of the phone's own task,
    /// short enough to show in full. A screen step's or a drive's card never is.
    private var phoneApproval: ApprovalRequest? {
        guard phoneTaskRunning, let req = state.pendingApproval, screenCard == nil, driveCardID == nil,
              req.action.utf8.count + req.target.utf8.count <= PhoneControl.maxApprovalBytes else { return nil }
        return req
    }

    /// One command from the phone, already checked for its shape by the listener. Returns whether it
    /// was taken and the words the phone shows. This is the final check: a task starts only when the
    /// Mac is free, and a stop or an answer must name the phone's running task (and its waiting request).
    func remoteCommand(_ command: [String: Any]) -> (Bool, String) {
        guard let op = command["op"] as? String else { return (false, "Invalid request.") }
        if op == "send" {
            guard phoneMayStartTask else { return (false, "Benji is busy on the Mac. Wait for it to finish.") }
            guard let id = command["id"] as? String, !id.isEmpty,
                  let text = command["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= PhoneControl.maxTask else {
                return (false, "Write a task of at most \(PhoneControl.maxTask) characters.")
            }
            phoneTaskID = id
            phoneTaskText = text
            phoneTaskRunning = true
            phoneTaskStatus = "Working"
            phoneLines = []
            phoneStream = ""
            phoneLineStart = state.lines.count + 1   // after the task's own line
            producedOutput = false
            voiceTurn = false
            turnSerial += 1
            onHidePointer?()
            apply(.submitText(text))
            // Straight to a text run: the Mac's draft, Screen mode and "include once" are left alone.
            run(task: text)
            showNote("Task from your phone")
            return (true, "Task received by your Mac.")
        }
        guard phoneTaskRunning, let id = phoneTaskID, command["task"] as? String == id else {
            return (false, "That phone task is no longer running.")
        }
        if op == "stop" {
            cancel()
            return (true, "Stopped this phone task.")
        }
        guard op == "approve" else { return (false, "Invalid request.") }
        guard phoneAnswersApprovals() else {
            return (false, "Approvals from the phone are turned off. Answer on your Mac.")
        }
        guard let request = command["request"] as? String, let approved = command["approved"] as? Bool,
              let pending = phoneApproval, request == pending.id else {
            return (false, "That approval has expired or has already been answered.")
        }
        decideApproval(approved ? .yes : .no, request: request, from: .phone)
        return (true, approved ? "Action approved." : "Action declined.")
    }

    /// Phone control was turned off (or on again): the phone's running task stops, and what it was
    /// shown is forgotten. A Mac task that started after it is left alone.
    func endRemoteControl() {
        if phoneTaskRunning { cancel() }
        phoneTaskID = nil
        phoneTaskText = ""
        phoneLines = []
        phoneStream = ""
    }

    /// Copies the phone task's lines, stream and status from the panel's state, after every change.
    func updatePhoneTask() {
        guard phoneTaskRunning else { return }
        phoneLines = state.lines.dropFirst(phoneLineStart).suffix(PhoneControl.shownLines).map {
            ["role": $0.role.rawValue, "text": PhoneControl.shown($0.text)]
        }
        phoneStream = PhoneControl.shown(streamingText)
        if state.pendingApproval != nil { phoneTaskStatus = "Needs your decision" }
        else if state.phase == .error { phoneTaskStatus = "Failed" }
        else { phoneTaskStatus = "Working" }
    }

    /// The run ended (`code` 0: normally). The phone's task, if it was this run, is done.
    func phoneTaskEnded(code: Int32) {
        guard phoneTaskRunning else { return }
        updatePhoneTask()
        phoneTaskStatus = code == 0 && state.phase != .error ? "Done" : "Failed"
        phoneTaskRunning = false
    }

    /// The run was cancelled, from the Mac or the phone.
    func phoneTaskStopped() {
        guard phoneTaskRunning else { return }
        phoneTaskStatus = "Stopped"
        phoneTaskRunning = false
        phoneStream = ""
    }
}
