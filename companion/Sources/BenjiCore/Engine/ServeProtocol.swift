import Foundation

/// The app's side of `benji --serve` (docs/architecture.md): requests the app
/// writes to the engine's stdin and events it reads from its stdout, one JSON object per line.
/// Pure encoding and decoding, so it is unit-tested against example lines of the protocol.
public enum ServeProtocol {
    public static let version = 1
    /// How long the app's approval card waits before denying.
    public static let appApprovalTimeout: TimeInterval = 60
    /// The app's timeout always ends at least this long before the engine's own.
    public static let approvalMargin: TimeInterval = 5

    /// The app's approval timeout given the one the engine announced in `ready`. The engine's timeout is a
    /// backstop: the app's decision (or its timeout) must reach the engine first, so the app never
    /// waits longer than the engine's timeout minus the margin.
    public static func approvalTimeout(engineTimeout: Double?) -> TimeInterval {
        guard let engine = engineTimeout, engine.isFinite, engine > 0 else { return appApprovalTimeout }
        return max(1, min(appApprovalTimeout, engine - approvalMargin))
    }
}

/// Where the answer to an approval came from, for the engine's audit log. Only `card` (the Mac's own
/// card: its buttons or keys) can grant a drive.
public enum ApprovalSource: String, Sendable, Equatable {
    case card, phone, timeout
}

/// What the row's schedule buttons ask for; the raw values are the engine's.
public enum JobScheduleAction: String, Sendable, Equatable { case pause, resume, delete }

/// App → the engine.
public enum ServeRequest: Equatable, Sendable {
    /// The first request, with what this app can carry out: the engine offers only the tools
    /// these allow.
    case hello(capabilities: [String])
    /// The talk key went down: the engine may warm the connection to its provider if it has been
    /// idle. No answer; the engine writes the time it took to its audit log.
    case prewarm
    /// A task from the phone (docs/remote-control.md): the words only. The engine runs it as text,
    /// with no screen, jobs, cards or figures, whatever else a request says; sent only to an engine
    /// that lists `remote_text`.
    case remoteSend(id: String, text: String)
    /// `spoken`: the user said it (the reply is read aloud). `screen`: what the attached
    /// screenshot holds, sent only with `allowPointing`. `screenActions`: the app can act on that
    /// screenshot, sent only with it. `screenSimpleSteps`: and simple steps may go without
    /// a card ("Act on simple steps"), sent only with `screenActions`. `canvas`: what
    /// Benji has on the screen now, in that screenshot's pixels.
    /// `jobs`: the app shows background jobs, so the engine may offer `start_job`.
    /// `drive`: the app can carry a drive, sent only with `screenSimpleSteps`.
    case send(id: String, text: String, imagePath: String?, allowPointing: Bool,
              spoken: Bool = false, screen: ScreenshotGeometry? = nil, screenActions: Bool = false,
              screenSimpleSteps: Bool = false, canvas: CanvasSnapshot? = nil, jobs: Bool = false,
              schedules: Bool = false, drive: Bool = false)
    /// `viaCard`: the answer came from the app's own card (its button or ⌘Return). The engine grants a
    /// drive only to a yes that says so; a spoken yes, or anything else, never does.
    /// `source`: who answered, said to the engine when it is not the card (`from`).
    case approve(id: String, request: String, approved: Bool, viaCard: Bool = false, source: ApprovalSource = .card)
    /// The user ended the drive: `reason` is one of `user_stop`, `mouse`, `typing`, `click`, `scroll`.
    case driveStop(id: String, reason: String)
    /// How a `screen_action` step ended.
    case screenResult(id: String, request: String, result: ScreenStepResult)
    case cancel(id: String)
    /// Background jobs. The job's approval is answered with `approve`, its id as `id`.
    case jobStop(job: String)
    /// What the user said to steer a running job; taken between its tool steps.
    case jobSteer(job: String, text: String)
    /// Hide a job that is over.
    case jobDismiss(job: String)
    /// Continue a job that stopped or didn't finish: another run of the same job.
    case jobContinue(job: String)
    case jobResume(job: String, run: Int, generation: String, readSites: [String], actSites: [String])
    /// The row's schedule buttons: pause, resume or delete.
    case jobSchedule(job: String, action: JobScheduleAction)
    /// The user's one switch for every schedule (Settings): false stops a repeat run in flight and
    /// nothing runs until it is true again. The engine runs none until it has heard true.
    case schedulesSet(enabled: Bool)
    /// The user's switch for browser reach: true opens the engine's link for the extension's
    /// host, false closes it. The engine answers with `browser` events.
    case browserSet(enabled: Bool)
    /// The sites the user set, in Settings, to always allow reading. The engine checks
    /// each one again and answers with a `browser_always` event holding the ones it kept.
    case browserAlways(sites: [String])
    /// The user cut the answer of turn `id` off: its reply in the conversation becomes
    /// `reply` (what was heard, marked). A turn still running is stopped, keeping the message.
    case cutOff(id: String, reply: String)
    /// `droppedEarlier`: the app has already dropped older exchanges of this conversation.
    /// `taint`: what the engine said, in an earlier `answer`, this conversation holds from outside.
    case restore([ConversationMemory.Exchange], droppedEarlier: Bool = false, taint: CarriedTaint? = nil)
    case reset
    case shutdown

    var object: [String: Any] {
        switch self {
        case let .hello(capabilities):
            return ["type": "hello", "protocol": ServeProtocol.version, "capabilities": capabilities]
        case .prewarm:
            return ["type": "prewarm"]
        case let .remoteSend(id, text):
            return ["type": "send", "id": id, "text": text, "remote_text": true]
        case let .send(id, text, imagePath, allowPointing, spoken, screen, screenActions, screenSimpleSteps, canvas, jobs, schedules, drive):
            var o: [String: Any] = ["type": "send", "id": id, "text": text]
            if let imagePath { o["image"] = imagePath }
            if allowPointing {
                o["allow_pointing"] = true
                if let screen { o["screen"] = screen.object }
                if screenActions, imagePath != nil {
                    o["screen_actions"] = true
                    if screenSimpleSteps {
                        o["screen_simple_steps"] = true
                        if drive { o["drive"] = true }
                    }
                }
            }
            if spoken { o["spoken"] = true }
            if let canvas, !canvas.isEmpty { o["canvas"] = canvas.object }
            if jobs { o["jobs"] = true }
            if jobs && schedules { o["schedules"] = true }
            return o
        case let .approve(id, request, approved, viaCard, source):
            // The engine approves only the string "yes"; anything else is a No.
            var o: [String: Any] = ["type": "approve", "id": id, "request": request, "decision": approved ? "yes" : "no"]
            if viaCard { o["via"] = "card" }
            if source != .card { o["from"] = source.rawValue }
            return o
        case let .driveStop(id, reason):
            return ["type": "drive_stop", "id": id, "reason": reason]
        case let .screenResult(id, request, result):
            var o: [String: Any] = ["type": "screen_result", "id": id, "request": request,
                                    "status": result.status.rawValue, "text": result.text]
            if let path = result.imagePath { o["image"] = path }
            return o
        case let .cancel(id):
            return ["type": "cancel", "id": id]
        case let .jobStop(job):
            return ["type": "job_stop", "job": job]
        case let .jobSteer(job, text):
            return ["type": "job_steer", "job": job, "text": text]
        case let .jobDismiss(job):
            return ["type": "job_dismiss", "job": job]
        case let .jobResume(job, run, generation, readSites, actSites):
            return ["type": "job_resume", "job": job, "run": run, "generation": generation,
                    "read_sites": readSites, "act_sites": actSites]
        case let .jobContinue(job):
            return ["type": "job_continue", "job": job]
        case let .jobSchedule(job, action):
            return ["type": "job_schedule", "job": job, "action": action.rawValue]
        case let .schedulesSet(enabled):
            return ["type": "schedules_set", "enabled": enabled]
        case let .browserSet(enabled):
            return ["type": "browser_set", "enabled": enabled]
        case let .browserAlways(sites):
            return ["type": "browser_always", "sites": sites]
        case let .cutOff(id, reply):
            return ["type": "cut_off", "id": id, "reply": reply]
        case let .restore(exchanges, droppedEarlier, taint):
            var o: [String: Any] = ["type": "restore",
                                    "exchanges": exchanges.map { ["user": $0.user, "assistant": $0.assistant] }]
            if droppedEarlier { o["dropped"] = true }
            if let taint, !taint.kinds.isEmpty {
                o["taints"] = taint.kinds
                o["taint_note"] = taint.note
            }
            return o
        case .reset:
            return ["type": "reset"]
        case .shutdown:
            return ["type": "shutdown"]
        }
    }

    /// One request line, newline-terminated. Keys are sorted so the output is stable.
    public func line() -> Data {
        // The object holds only strings, numbers, booleans, arrays and dictionaries.
        var data = (try? JSONSerialization.data(withJSONObject: object,
                                                 options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// What the engine says about itself in `ready`.
public struct ServeReady: Equatable, Sendable {
    public let protocolVersion: Int
    public let version: String
    public let provider: String
    public let model: String
    public let destination: String
    public let approvalTimeout: Double?
    /// The engine can run background jobs. False when `ready` leaves it out.
    public let jobs: Bool
    /// The engine can open a link for the browser extension. False when `ready` leaves it out.
    public let browser: Bool
    /// The engine can run schedules inside a job and carry out the row's schedule buttons.
    /// False when `ready` leaves it out.
    public let schedules: Bool
    /// The host the engine sends to ("api.deepseek.com"), never a key. Nil when `ready` leaves it out.
    public let host: String?
    /// The model can read images. True when `ready` leaves it out.
    public let vision: Bool
    /// What the engine can do beyond protocol 1: "hello_caps", "prewarm", "policy", "tool_cap",
    /// "image_hash", "error_reasons", "remote_text". Empty when `ready` leaves it out.
    public let capabilities: [String]

    public init(protocolVersion: Int, version: String, provider: String, model: String, destination: String,
                approvalTimeout: Double?, jobs: Bool = false, browser: Bool = false,
                host: String? = nil, vision: Bool = true, schedules: Bool = false, capabilities: [String] = []) {
        self.capabilities = capabilities
        self.protocolVersion = protocolVersion
        self.version = version
        self.provider = provider
        self.model = model
        self.destination = destination
        self.approvalTimeout = approvalTimeout
        self.jobs = jobs
        self.browser = browser
        self.schedules = schedules
        self.host = host
        self.vision = vision
    }
}

/// Engine → app.
public enum ServeEvent: Equatable, Sendable {
    case ready(ServeReady)
    /// The engine took the turn (its first event).
    case accepted(id: String)
    case tool(id: String, name: String, detail: String)
    /// A tool that actually ran: a kind ("command", "file_saved", …) and, for a saved file, its
    /// name. Never the command, a path or contents.
    case activity(id: String, kind: String, name: String?)
    case approval(id: String, request: String, action: String, target: String)
    /// An approval for a screen step: the `approval` event with its `screen` step, so the
    /// app can word its own card and name the app. An approval whose step doesn't decode is a
    /// plain `approval`.
    /// `intent`: what the model said the step is for, for the card.
    case screenApproval(id: String, request: String, action: String, target: String, step: ScreenStep,
                        intent: ScreenStepIntent? = nil)
    /// The engine asks the app to act on an approved step and answer with `screen_result`.
    /// `step` is nil when it doesn't decode (the app refuses it; it must still answer). `mode`
    /// free or quiet: the step wasn't asked about; the app looks again and may answer
    /// `ask`. Nil: the step the user just approved.
    case screenAction(id: String, request: String, step: ScreenStep?, mode: ScreenStepClass? = nil,
                      intent: ScreenStepIntent? = nil, drive: Bool = false)
    /// The drive card: an `approval` with a `drive` object. The app words it from the goal.
    case driveApproval(id: String, request: String, goal: String, seconds: Double)
    /// The drive began or ended.
    case drive(id: String, event: DriveEvent)
    /// `why` is "yes", "no" or "timeout".
    case approvalResult(id: String, request: String, approved: Bool, why: String)
    /// With `allow_pointing`, the engine strips the tags itself and sends the targets. In the beats
    /// form each target has its `at`, and edits of what is already drawn come after the marks as
    /// `.edit` targets.
    /// `taint`: outside content the conversation holds once this turn is committed; nil when none.
    case answer(id: String, text: String, targets: [PointingTarget], taint: CarriedTaint? = nil)
    /// A piece of the reply as the model writes it (the engine streams only with
    /// BENJI_STREAM=1). The deltas after the last `deltaReset` join to the answer's text.
    case delta(id: String, text: String)
    /// The text streamed so far came before a tool call: it isn't the answer; forget it.
    case deltaReset(id: String)
    /// A card line of the reply as it closes (only when the app said it shows
    /// cards): `card`, `card_item`, `card_takeaway`, `card_chips`. Never in the deltas.
    /// `at`: characters of spoken text before the line (Unicode scalars), to place lines that come
    /// only with the answer (streaming off).
    case cardLine(id: String, line: ExplainCardLine, at: Int?)
    /// The reply's last card line has been sent (just before its `answer`).
    case cardEnd(id: String)
    case usage(id: String, calls: Int, inputTokens: Int, outputTokens: Int)
    /// Outside content the conversation holds, told when no answer carries it: turn `id` was cut
    /// off while it was still being written, and the words heard stay in the conversation.
    case taint(id: String, taint: CarriedTaint)
    case error(id: String?, code: String, text: String)
    /// `status` is "ok", "cancelled" or "error". Always the last event of a turn.
    case done(id: String, status: String)
    /// A background job as it is now: any change of its state, its line, its pending
    /// approval or its ending. Not tied to a turn.
    case job(JobSnapshot)
    /// The state of the link to the browser extension, on every change.
    case browser(BrowserStatus)
    /// The sites the engine kept from the "always allow reading" list the app sent.
    case browserAlways([String])
    /// A well-formed event of a type this build doesn't know (a newer engine).
    case unknown(type: String)

    /// Decodes one stdout line. Nil when the line isn't a JSON object with a string `type`.
    public static func decode(_ line: String) -> ServeEvent? {
        guard let data = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = o["type"] as? String else { return nil }
        func str(_ key: String) -> String { o[key] as? String ?? "" }
        func int(_ key: String) -> Int { (o[key] as? NSNumber)?.intValue ?? 0 }
        switch type {
        case "ready":
            return .ready(ServeReady(protocolVersion: int("protocol"), version: str("version"),
                                     provider: str("provider"), model: str("model"),
                                     destination: str("destination"),
                                     approvalTimeout: (o["approval_timeout"] as? NSNumber)?.doubleValue,
                                     jobs: o["jobs"] as? Bool ?? false, browser: o["browser"] as? Bool ?? false,
                                     host: o["host"] as? String, vision: o["vision"] as? Bool ?? true,
                                     schedules: o["schedules"] as? Bool ?? false,
                                     capabilities: (o["capabilities"] as? [Any])?.compactMap { $0 as? String } ?? []))
        case "accepted":
            return .accepted(id: str("id"))
        case "tool":
            return .tool(id: str("id"), name: str("name"), detail: str("detail"))
        case "activity":
            return .activity(id: str("id"), kind: str("kind"), name: o["name"] as? String)
        case "approval":
            if let d = o["drive"] as? [String: Any], let goal = d["goal"] as? String, !goal.isEmpty {
                let seconds = (d["seconds"] as? NSNumber)?.doubleValue ?? DriveCopy.cardSeconds
                return .driveApproval(id: str("id"), request: str("request"), goal: goal,
                                      seconds: seconds.isFinite && seconds > 0 ? min(seconds, DriveCopy.cardSeconds) : DriveCopy.cardSeconds)
            }
            if let raw = o["screen"] as? [String: Any], let step = ScreenStep.decode(raw) {
                return .screenApproval(id: str("id"), request: str("request"), action: str("action"),
                                       target: str("target"), step: step, intent: ScreenStepIntent.decode(raw))
            }
            return .approval(id: str("id"), request: str("request"), action: str("action"), target: str("target"))
        case "screen_action":
            let raw = o["step"] as? [String: Any]
            // Only free or quiet mean unasked; anything else is treated as the approved step's gate.
            let mode = (o["mode"] as? String).flatMap(ScreenStepClass.init(rawValue:)).flatMap { $0 == .asked ? nil : $0 }
            let unknownMode = o["mode"] != nil && mode == nil
            return .screenAction(id: str("id"), request: str("request"),
                                 step: unknownMode ? nil : raw.flatMap(ScreenStep.decode), mode: mode,
                                 intent: raw.flatMap(ScreenStepIntent.decode), drive: o["drive"] as? Bool == true)
        case "drive":
            guard let event = DriveEvent.decode(o) else { return .unknown(type: type) }
            return .drive(id: str("id"), event: event)
        case "approval_result":
            return .approvalResult(id: str("id"), request: str("request"),
                                   approved: o["approved"] as? Bool ?? false, why: str("why"))
        case "answer":
            let raw = o["targets"] as? [[String: Any]] ?? []
            let edits = (o["edits"] as? [[String: Any]] ?? []).compactMap(edit)
            let kinds = (o["taints"] as? [Any])?.compactMap { $0 as? String } ?? []
            return .answer(id: str("id"), text: str("text"),
                           targets: PointingTags.capped(raw.compactMap(target) + edits),
                           taint: kinds.isEmpty ? nil : CarriedTaint(kinds: kinds, note: str("taint_note")))
        case "delta":
            return .delta(id: str("id"), text: str("text"))
        case "delta_reset":
            return .deltaReset(id: str("id"))
        case "card", "card_item", "card_takeaway", "card_chips":
            let key = ["card": "card", "card_item": "item", "card_takeaway": "text", "card_chips": "chips"][type]!
            guard let raw = o[key], let json = try? JSONSerialization.data(withJSONObject: [raw]),
                  case .array(let wrapped)? = try? JSONDecoder().decode(JSONValue.self, from: json), let value = wrapped.first,
                  let line = ExplainCardGrammar.line(event: type, json: value) else { return .unknown(type: type) }
            return .cardLine(id: str("id"), line: line, at: (o["at"] as? NSNumber)?.intValue)
        case "card_end":
            return .cardEnd(id: str("id"))
        case "taint":
            let kinds = (o["taints"] as? [Any])?.compactMap { $0 as? String } ?? []
            guard !kinds.isEmpty else { return .unknown(type: type) }
            return .taint(id: str("id"), taint: CarriedTaint(kinds: kinds, note: str("taint_note")))
        case "usage":
            return .usage(id: str("id"), calls: int("calls"),
                          inputTokens: int("input_tokens"), outputTokens: int("output_tokens"))
        case "error":
            return .error(id: o["id"] as? String, code: str("code"), text: str("text"))
        case "done":
            return .done(id: str("id"), status: str("status"))
        case "job":
            guard let snapshot = (o["job"] as? [String: Any]).flatMap(JobSnapshot.decode) else {
                return .unknown(type: type)
            }
            return .job(snapshot)
        case "browser":
            guard let state = BrowserStatus.decode(o["state"]) else { return .unknown(type: type) }
            return .browser(state)
        case "browser_always":
            guard let sites = o["sites"] as? [String] else { return .unknown(type: type) }
            return .browserAlways(sites.filter { $0.hasPrefix("https://") })
        default:
            return .unknown(type: type)
        }
    }

    /// `{kind, coords, label}` as the engine's `pointing.Target`; anything malformed is dropped.
    static func target(_ o: [String: Any]) -> PointingTarget? {
        guard let kind = o["kind"] as? String, let raw = o["coords"] as? [Any] else { return nil }
        let n = raw.compactMap { ($0 as? NSNumber)?.intValue }
        guard n.count == raw.count else { return nil }
        guard kind == kind.lowercased(), let shape = PointingTags.shape(kind: kind.uppercased(), n) else { return nil }
        return PointingTarget(shape: shape, label: o["label"] as? String ?? "", at: (o["at"] as? NSNumber)?.intValue)
    }

    /// `{part, op, args, text, at}` as the engine's `pointing.Edit`, read back through the tag
    /// grammar so the two can't disagree; anything malformed is dropped.
    static func edit(_ o: [String: Any]) -> PointingTarget? {
        guard let part = o["part"] as? String, let op = o["op"] as? String else { return nil }
        let args = (o["args"] as? [NSNumber] ?? []).map { n -> String in
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 1e6 ? String(Int(d)) : String(d)
        }
        var body = "EDIT:\(part):\(op)"
        switch op {
        case "move": body += " " + args.joined(separator: ",")
        case "scale": body += " " + (args.first ?? "")
        case "relabel", "recolor": body += " " + (o["text"] as? String ?? "")
        default: break
        }
        guard let e = DrawingEdit.parse(Substring(body)) else { return nil }
        return PointingTarget(shape: .edit(e), label: "", at: (o["at"] as? NSNumber)?.intValue)
    }
}


/// What this app can carry out, said in `hello`. The engine offers a tool only if the app can
/// do it; a name the engine doesn't know is ignored, and an app that sends no list is taken at its
/// `send`. The names are the engine's `APP_CAPS` (benji/serve.py).
public enum AppCapabilities {
    /// - Parameters:
    ///   - screenActions: this app can act on a screenshot (click, scroll, type, press keys). It can
    ///     only if the user hasn't switched it off in Settings and macOS has given Benji Accessibility.
    ///   - jobs / browser: the job row and the browser switch exist in this build.
    ///   - schedules: the row can show and carry out a job's schedule; for jobs only.
    ///   - drive: this app can carry out a drive: the consent card, the notch state, the hand-back and
    ///     the drive's rules at the point. Only with screen actions, and only if the user hasn't switched
    ///     drive mode off. The engine offers the drive tools only when this is listed.
    ///   - browserActing: this app can show and answer the cards of a job that clicks, types and uploads in the
    ///     user's browser: the second grant per site, a send, an upload, the row's act sites and the
    ///     stop on the browser's debugging bar. Listed as `browser_act` and `browser_upload`; the engine offers
    ///     those tools only when they are, and `policy.json` can switch either off on its own.
    public static func list(screenActions: Bool, jobs: Bool = true, browser: Bool = true, schedules: Bool = true,
                            drive: Bool = false, browserActing: Bool = true) -> [String] {
        var caps = ["pointing", "cards", "figures", "prewarm"]
        if screenActions { caps.append("screen_actions") }
        if screenActions && drive { caps.append("drive") }
        if jobs { caps += ["jobs", "job_resume"] }
        if browser && jobs { caps.append("browser") }
        if browser && jobs && browserActing { caps += ["browser_act", "browser_upload"] }
        if schedules && jobs { caps.append("schedules") }
        return caps
    }
}
