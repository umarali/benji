import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Drive mode: the user lets Benji take over the screen for one stated goal. The rules are
// the engine's (benji/drive.py), and this file mirrors the ones the app applies at the point, after
// looking with Accessibility, case for case: both run Tests/drive-cases.json. The app can only
// raise a class, never lower it, and nothing read from the screen is an input to any of this: a
// step, the element Accessibility found, and the consent.

/// A step's class inside a drive. `denied` is not a card: it is refused, whoever asks.
public enum DriveClass: String, Comparable, Sendable {
    case free, quiet, asked, denied

    private var rank: Int {
        switch self {
        case .free: return 0
        case .quiet: return 1
        case .asked: return 2
        case .denied: return 3
        }
    }
    public static func < (a: DriveClass, b: DriveClass) -> Bool { a.rank < b.rank }

    /// From a screen step's class (free, quiet, asked).
    public init(_ c: ScreenStepClass) {
        switch c {
        case .free: self = .free
        case .quiet: self = .quiet
        case .asked: self = .asked
        }
    }
}

public enum DriveClassifier {
    // MARK: text that must not fool a rule

    /// Look-alike letters of other scripts (benji/drive.py CONFUSABLES, same table).
    static let confusables: [Character: Character] = [
        "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "х": "x", "у": "y", "і": "i", "ј": "j", "ѕ": "s",
        "ԁ": "d", "һ": "h", "ԛ": "q", "ԝ": "w", "к": "k", "м": "m", "т": "t", "н": "h", "в": "b", "ь": "b",
        "α": "a", "ο": "o", "ρ": "p", "ν": "v", "ι": "i", "τ": "t", "υ": "u", "κ": "k", "χ": "x", "ε": "e",
        "γ": "y", "ω": "w",
        "ı": "i", "ɩ": "i", "ł": "l", "ø": "o", "đ": "d", "ɡ": "g", "ƅ": "b", "ǀ": "l", "ꜱ": "s", "ɑ": "a",
    ]

    /// `text` lower-cased with compatibility forms folded, accents and invisible characters dropped
    /// and look-alike letters turned into the Latin letter (benji/drive.py `skeleton`).
    public static func skeleton(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .format:
                continue
            case .control where scalar != "\n" && scalar != "\t":
                continue
            default:
                break
            }
            if let mapped = confusables[Character(scalar)] {
                out.append(contentsOf: String(mapped).unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    static func words(_ text: String) -> [String] { ScreenStepClassifier.words(skeleton(text)) }

    /// What may commit something outside the user's screen or lose something: the commit words of a
    /// click and the ones a drive adds, because a drive clicks more.
    static let extraOutbound = [
        "reply", "comment", "share", "tweet", "retweet", "forward", "invite", "book", "reserve", "order",
        "donate", "withdraw", "apply", "enroll", "register", "subscribe", "upload", "merge", "deploy",
        "empty", "reset", "wipe", "format", "uninstall", "revoke", "deactivate", "terminate", "end call",
        "leave meeting", "sign up", "signup", "unfollow", "block", "report", "authorize", "authorise",
    ]
    public static let outboundWords: [String] =
        ScreenStepClassifier.commitWords + extraOutbound.filter { !ScreenStepClassifier.commitWords.contains($0) }

    /// The tokens, each pair of neighbours run together, and each run of three or more single
    /// letters joined: the ways a word is split to dodge a list.
    static func candidates(_ tokens: [String]) -> [String] {
        var cands = tokens
        if tokens.count > 1 {
            for i in 0..<(tokens.count - 1) { cands.append(tokens[i] + tokens[i + 1]) }
        }
        var run: [String] = []
        for t in tokens + [""] {
            if t.count == 1 { run.append(t); continue }
            if run.count >= 3 { cands.append(run.joined()) }
            run = []
        }
        return cands
    }

    /// The first outbound or destructive word or phrase in `text`, read through `skeleton` and the
    /// splitting tricks, or nil.
    public static func outboundWord(_ text: String) -> String? {
        let tokens = words(text)
        guard !tokens.isEmpty else { return nil }
        let cands = candidates(tokens)
        for entry in outboundWords {
            let parts = entry.split(separator: " ").map(String.init)
            if parts.count == 1 {
                if cands.contains(where: { ScreenStepClassifier.matches($0, entry) }) { return entry }
                continue
            }
            guard tokens.count >= parts.count else { continue }
            for i in 0...(tokens.count - parts.count) {
                let hit = parts.indices.allSatisfy { j in
                    j == parts.count - 1 ? ScreenStepClassifier.matches(tokens[i + j], parts[j]) : tokens[i + j] == parts[j]
                }
                if hit { return entry }
            }
        }
        return nil
    }

    // MARK: fields that are never typed into

    static let secretPhrases = [
        "password", "passwd", "passcode", "pass code", "cvv", "cvc", "otp", "one time", "verification code",
        "security code", "card number", "credit card", "debit card", "card no", "2fa", "authenticator",
        "pin code", "ssn", "social security", "routing number", "account number", "iban", "api key", "secret key",
        "recovery code", "backup code", "sms code", "login code", "sign in code",
    ]
    static let messageWords: Set<String> = ["message", "chat", "reply", "comment", "compose", "post", "tweet", "dm",
                                            "caption", "body", "subject", "mail", "email", "write", "say"]
    static let searchWords: Set<String> = ["search", "find", "address", "url", "location", "filter", "spotlight"]

    public enum FieldKind: String, Sendable { case secret, search, message, other }

    static func elementText(_ e: ScreenElement) -> String { "\(e.title) \(e.description) \(e.hints)" }

    /// What the focused field is for.
    public static func fieldKind(_ element: ScreenElement?) -> FieldKind {
        guard let e = element else { return .other }
        if e.subrole == "AXSecureTextField" || e.role == "AXSecureTextField" { return .secret }
        let joined = words(elementText(e)).joined(separator: " ")
        let padded = " \(joined) "
        if secretPhrases.contains(where: { padded.contains(" \($0) ") }) { return .secret }
        let tokens = Set(joined.split(separator: " ").map(String.init))
        if e.subrole == "AXSearchField" || e.role == "AXSearchField" || !tokens.isDisjoint(with: searchWords) {
            return .search
        }
        if !tokens.isDisjoint(with: messageWords) { return .message }
        return .other
    }

    static func luhnOK(_ digits: [Int]) -> Bool {
        var total = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { total += d * 2 > 9 ? d * 2 - 9 : d * 2 } else { total += d }
        }
        return total % 10 == 0
    }

    /// Text that is a payment card number: 13 to 19 digits, spaces and dashes allowed, passing Luhn.
    public static func looksLikeCard(_ text: String) -> Bool {
        let s = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard (13...28).contains(s.count), s.first?.isASCIIDigit == true, s.last?.isASCIIDigit == true,
              s.allSatisfy({ $0.isASCIIDigit || $0 == " " || $0 == "-" }) else { return false }
        let digits = s.compactMap { $0.isASCIIDigit ? Int(String($0)) : nil }
        return (13...19).contains(digits.count) && luhnOK(digits)
    }

    // MARK: the classes

    /// The engine's class for a step from the step alone (benji/drive.py `plan_class`).
    public static func plan(_ step: ScreenStep, intent: ScreenStepIntent?) -> (DriveClass, String) {
        if case .scroll = step { return (.free, "") }
        if intent?.confidence == .low { return (.asked, "Benji isn't sure this is what you want") }
        switch step {
        case .scroll:
            return (.free, "")
        case let .click(_, _, _, _, label), let .drag(_, _, _, _, label):   // a drag planned quiet is quiet only on a real slider or divider
            if let word = outboundWord(label) { return (.asked, "“\(word)” may send, buy, delete or commit something") }
            return (.quiet, "")
        case let .typeText(text):
            if looksLikeCard(text) { return (.denied, "that is a card number, and Benji never types one") }
            return (.quiet, "")
        case let .pressKey(key, mods):
            if (key == "return" || key == "enter") && !mods.isEmpty { return (.asked, "this shortcut can send or submit") }
            if mods.contains(.control) { return (.asked, "a Control shortcut can stop a program") }
            if mods.contains(.cmd), ["q", "w", "delete", "forward_delete"].contains(key) {
                return (.asked, "this shortcut can quit, close or erase something")
            }
            if (key == "delete" || key == "forward_delete") && !mods.isEmpty {
                return (.asked, "Delete with a modifier can remove something")
            }
            return (.quiet, "")
        }
    }

    /// The controls a drag may move unasked in a drive.
    public static let quietDragRoles: Set<String> = ["AXSlider", "AXSplitter"]

    /// Which level of the chain (leaf first) a quiet drag must let go inside: a slider's own, or the
    /// split group holding a divider, whose far end is in the pane beside it. Nil: not such a control.
    public static func dragBoundsLevel(roles: [String]) -> Int? {
        guard let level = roles.firstIndex(where: quietDragRoles.contains) else { return nil }
        if roles[level] == "AXSlider" { return level }
        return level + 1 < roles.count && roles[level + 1] == "AXSplitGroup" ? level + 1 : nil
    }

    /// A drag is quiet only on one native slider or split divider of the app Benji looked at, with
    /// the far end still on that control and no dialog open. It can't carry a file and dragging back
    /// undoes it. A web page can make anything report itself as a slider, so a page's never counts.
    private static func dragClass(label: String, element: ScreenElement?, endElement: ScreenElement?,
                                  sameApp: Bool, sameControl: Bool) -> (DriveClass, String) {
        guard sameApp, sameControl, let element, let endElement, element.inWebArea == false,
              quietDragRoles.contains(element.role) else { return (.asked, ScreenStepClassifier.dragWhy) }
        if element.inSheet || endElement.inSheet { return (.asked, "it's in a dialog") }
        if let word = outboundWord(elementText(element)) {
            return (.asked, "“\(word)” may send, buy, delete or commit something")
        }
        if element.role == "AXSlider" {     // a divider has no name to check
            let names = "\(element.title) \(element.description)".trimmingCharacters(in: .whitespaces)
            if names.isEmpty { return (.asked, "nothing names this slider") }
            if !ScreenStepClassifier.namesMatch(label: label, names: names) {
                return (.asked, "what is there doesn't match what Benji named")
            }
        }
        return (.quiet, "")
    }

    static let printingKeys: Set<String> = Set(
        "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init)
            + ["space", "minus", "equal", "comma", "period", "slash", "semicolon", "quote", "left_bracket",
               "right_bracket", "backslash", "grave"])
    static let secretWhy = "that field is for a password, a card or a code, and Benji never types in one"

    /// The app's class at the point (benji/drive.py `final_class`). Never lower than `planned`.
    /// `endElement`: what is where a drag lets go. `sameControl`: it lets go still on the control it pressed.
    public static func final(_ step: ScreenStep, planned: DriveClass, element: ScreenElement?,
                             sameApp: Bool, endElement: ScreenElement? = nil, sameControl: Bool = false) -> (DriveClass, String) {
        if planned == .asked || planned == .denied { return (planned, "") }
        let textRoles = ScreenStepClassifier.textRoles
        func isText(_ e: ScreenElement) -> Bool {
            textRoles.contains(e.role) || (e.subrole.map(textRoles.contains) ?? false)
        }
        if case let .drag(_, _, _, _, label) = step {
            if [element, endElement].compactMap({ $0 }).contains(where: { isText($0) && fieldKind($0) == .secret }) {
                return (.denied, secretWhy)
            }
            return dragClass(label: label, element: element, endElement: endElement, sameApp: sameApp, sameControl: sameControl)
        }
        if !sameApp { return (.asked, "it's in another app than the one Benji looked at") }
        switch step {
        case .scroll:
            return (planned, "")
        case let .click(_, _, _, _, label):
            guard let element else { return (.asked, "Benji can't tell what is under the point") }
            if element.inSheet { return (.asked, "it's in a dialog") }
            if element.subrole.map(ScreenStepClassifier.windowButtonSubroles.contains) == true {
                return (.asked, "that closes, hides or resizes a window")
            }
            if let word = outboundWord(elementText(element)) {
                return (.asked, "“\(word)” may send, buy, delete or commit something")
            }
            let names = "\(element.title) \(element.description)".trimmingCharacters(in: .whitespaces)
            if ScreenStepClassifier.buttonRoles.contains(element.role), names.isEmpty {
                return (.asked, "nothing names this button")
            }
            if !names.isEmpty, !ScreenStepClassifier.namesMatch(label: label, names: names) {
                return (.asked, "what is there doesn't match what Benji named")
            }
            return (planned, "")
        case .typeText:
            guard let element, isText(element) else { return (.asked, "no text field has the keyboard") }
            if fieldKind(element) == .secret { return (.denied, secretWhy) }
            if element.inSheet { return (.asked, "it's in a dialog") }
            return (planned, "")
        case let .pressKey(key, mods):
            let focused = fieldKind(element)
            if element != nil, focused == .secret, printingKeys.contains(key) || key == "return" || key == "enter" {
                return (.denied, secretWhy)
            }
            if key == "return" || key == "enter" {
                guard let element else { return (.asked, "Benji can't tell what Return would do") }
                if element.inSheet { return (.asked, "a dialog is open, and Return can answer it") }
                if ScreenStepClassifier.buttonRoles.contains(element.role) {
                    return (.asked, "a button has the keyboard, and Return can press it")
                }
                if isText(element), focused == .search { return (planned, "") }
                if isText(element), focused == .message { return (.asked, "Return in a message field can send it") }
                return (.asked, "Return here may send or submit")
            }
            if let element, element.inSheet, key == "space" { return (.asked, "a dialog is open, and Space can answer it") }
            if key == "space", let element, ScreenStepClassifier.buttonRoles.contains(element.role) {
                return (.asked, "a button has the keyboard, and Space can press it")
            }
            if (key == "delete" || key == "forward_delete"), mods.isEmpty {
                if !(element.map(isText) ?? false) { return (.asked, "Delete outside a text field can remove something") }
            }
            if mods.contains(.cmd), key == "v", focused == .secret { return (.denied, secretWhy) }
            return (planned, "")
        case .drag:
            return (.asked, ScreenStepClassifier.dragWhy)   // handled above; a drag never gets here
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { self >= "0" && self <= "9" }
}

// MARK: the hand-back

/// When the user's own input ends a drive or only pauses it. Esc, typing, a click or a
/// scroll of the user's ends it at once. A mouse move only pauses and nudges; control returns to
/// the user after a run of movement of at least `minRunSeconds` and `minRunPoints`.
///
/// A run is movement with gaps no longer than `runGap` between samples; its length is the distance
/// the pointer travelled (the path, not the straight line), counted from the first move. Benji's
/// own events carry the app's marker and are not told to this watch (`synthetic`).
public struct DriveHandBack: Equatable, Sendable {
    public static let minRunSeconds: Double = 3
    public static let minRunPoints: CGFloat = 150
    public static let runGap: Double = 0.4
    /// How long the pointer must be still before a pause lifts.
    public static let resumeAfter: Double = 0.8
    /// A pointer this far (points) from where it should be has been moved by the user.
    public static let tolerance: CGFloat = 6

    public enum Input: Equatable, Sendable {
        case pointerMoved(CGPoint)
        case keyDown(UInt16)
        case mouseDown
        case scroll
    }

    public enum Reason: String, Equatable, Sendable { case escape, typing, click, scroll, movement }

    public enum Outcome: Equatable, Sendable {
        case none
        /// The user is moving the mouse: Benji waits and nudges.
        case paused
        case handBack(Reason)
    }

    public private(set) var handedBack: Reason?
    private var expected: CGPoint
    private var runStart: Double?
    private var lastMove: Double?
    private var last: CGPoint?
    private var runDistance: CGFloat = 0

    public init(pointer: CGPoint) {
        expected = pointer
        last = pointer
    }

    /// Benji moved the pointer itself (to click or scroll there).
    public mutating func benjiMovedPointer(to p: CGPoint) {
        expected = p
        last = p
    }

    /// True while the user's movement has not been still for `resumeAfter` seconds.
    public func isPaused(at now: Double) -> Bool {
        guard handedBack == nil, let lastMove else { return false }
        return now - lastMove < Self.resumeAfter
    }

    /// The outcome of one input of the user's at `now` (seconds, a monotonic clock).
    @discardableResult
    public mutating func observe(_ input: Input, at now: Double, synthetic: Bool = false) -> Outcome {
        if let reason = handedBack { return .handBack(reason) }
        guard !synthetic else { return .none }
        switch input {
        case let .keyDown(code):
            return end(code == KeyCodes.escape ? .escape : .typing)
        case .mouseDown:
            return end(.click)
        case .scroll:
            return end(.scroll)
        case let .pointerMoved(p):
            if hypot(p.x - expected.x, p.y - expected.y) <= Self.tolerance, runStart == nil { last = p; return .none }
            if let lastMove, now - lastMove > Self.runGap {   // a new run
                runStart = nil
                runDistance = 0
            }
            if runStart == nil {
                runStart = now
                runDistance = 0
                last = expected
            }
            if let from = last { runDistance += hypot(p.x - from.x, p.y - from.y) }
            last = p
            lastMove = now
            if let start = runStart, now - start >= Self.minRunSeconds, runDistance >= Self.minRunPoints {
                return end(.movement)
            }
            return .paused
        }
    }

    private mutating func end(_ reason: Reason) -> Outcome {
        handedBack = reason
        return .handBack(reason)
    }
}

// MARK: words the user reads

public enum DriveCopy {
    /// The consent card declines itself after this long (the engine waits two seconds more).
    public static let cardSeconds: TimeInterval = 45
    public static let stopHint = "Esc stops"
    public static let defaultsKey = "driveMode"

    /// On unless set to false (`defaults write com.emerssive.heybenji.app driveMode -bool NO`), and only
    /// where Benji may act on simple steps: a user who chose "Ask before every step" is never offered a drive.
    public static func isOn(_ stored: Any?) -> Bool { (stored as? Bool) ?? true }

    /// The card's headline and body: the goal, in the user's words as the model gave them, and what
    /// is and isn't covered. Granted only by the card's own button or ⌘Return.
    public static let cardAction = "take over your screen"
    public static func cardTarget(goal: String) -> String {
        "\(goal)\nBenji will scroll, click, type and move sliders while you watch. Anything that could send, buy, pay, delete or post still asks you first, and it never types a password, card or code. Esc, typing or the Stop button ends it."
    }
    public static func expiryLine(_ seconds: TimeInterval = cardSeconds) -> String {
        "No answer in \(max(1, Int(seconds.rounded()))) s means No."
    }

    /// The notch's line while a drive is on: "Driving · fill in the form · Esc stops".
    public static func activeLine(goal: String) -> String {
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return (g.isEmpty ? "Driving" : "Driving · \(g)") + ActivityLine.separator + stopHint
    }
    /// While the user's mouse is moving: Benji waits and says why.
    public static func pausedLine(goal: String) -> String {
        "Paused: you're moving the mouse" + ActivityLine.separator + stopHint
    }
}

/// What the engine says about the drive (`drive` event): it began, or it ended with a plain line.
public struct DriveEvent: Equatable, Sendable {
    public enum State: String, Sendable { case active, ended }
    public let state: State
    public let goal: String
    /// Why it ended (`finished`, `user_stop`, `mouse`, `typing`, `click`, `scroll`, `limit`, `time`,
    /// `tainted`, `turn_over`, `app_stop`, `error`); empty while active.
    public let reason: String
    public let spoken: String
    public let written: String
    public let steps: Int

    public init(state: State, goal: String, reason: String = "", spoken: String = "", written: String = "", steps: Int = 0) {
        self.state = state
        self.goal = goal
        self.reason = reason
        self.spoken = spoken
        self.written = written
        self.steps = steps
    }

    public static func decode(_ o: [String: Any]) -> DriveEvent? {
        guard let state = (o["state"] as? String).flatMap(State.init(rawValue:)) else { return nil }
        return DriveEvent(state: state, goal: o["goal"] as? String ?? "", reason: o["reason"] as? String ?? "",
                          spoken: o["spoken"] as? String ?? "", written: o["written"] as? String ?? "",
                          steps: (o["steps"] as? NSNumber)?.intValue ?? 0)
    }
}
