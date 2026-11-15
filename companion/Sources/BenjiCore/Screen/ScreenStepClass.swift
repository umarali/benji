import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Which screen steps Benji does without a card. Every step is free
// (done after the usual ring), quiet (done after a visible beat any input of the user's stops) or
// asked (an approval card). The engine plans the class from the step, the model's stated confidence,
// the setting and the user's message (benji/screen_class.py `plan_class`); the app looks at the
// point with Accessibility and may only raise it (`final`). This file mirrors the Python case for
// case; both run Tests/screen-class-cases.json.

/// A step's class. Ordered: a stricter class wins.
public enum ScreenStepClass: String, Comparable, Sendable {
    case free, quiet, asked

    private var rank: Int { self == .free ? 0 : self == .quiet ? 1 : 2 }
    public static func < (a: ScreenStepClass, b: ScreenStepClass) -> Bool { a.rank < b.rank }
}

/// What the model said a step is for, and how sure it is (`intent`, `confidence` on the step).
public struct ScreenStepIntent: Equatable, Sendable {
    public enum Confidence: String, CaseIterable, Sendable { case high, medium, low }
    public let intent: String
    public let confidence: Confidence?

    public init(intent: String = "", confidence: Confidence? = nil) {
        self.intent = intent
        self.confidence = confidence
    }

    /// From a step object; nil when it says neither (the model gave no intent or confidence).
    public static func decode(_ o: [String: Any]) -> ScreenStepIntent? {
        let intent = (o["intent"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let confidence = (o["confidence"] as? String).flatMap(Confidence.init(rawValue:))
        return intent.isEmpty && confidence == nil ? nil : ScreenStepIntent(intent: intent, confidence: confidence)
    }
}

/// What Accessibility found where a step acts: under the point for a click, the field with the
/// keyboard for typing. `role` is the first control role in the leaf and its two parents.
public struct ScreenElement: Equatable, Sendable {
    public let role: String
    public let subrole: String?
    public let title: String
    public let description: String
    /// A sheet, dialog or alert is above it.
    public let inSheet: Bool
    /// It is inside a web page (an AXWebArea is above it). Nil: not known (the caller didn't
    /// look), so it may be.
    public let inWebArea: Bool?
    /// More of what the page or app calls it (help text, a web page's own id): read by a drive's
    /// outbound and secret-field checks, never by the step classes outside a drive.
    public let hints: String

    public init(role: String, subrole: String? = nil, title: String = "", description: String = "", inSheet: Bool = false,
                inWebArea: Bool? = nil, hints: String = "") {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.description = description
        self.inSheet = inSheet
        self.inWebArea = inWebArea
        self.hints = hints
    }

    public var names: String { "\(title) \(description)" }
}

public enum ScreenStepClassifier {
    /// Words on a click's target that mean it may commit something (benji/screen_class.py
    /// COMMIT_WORDS). A word matches with the endings below; phrases match as consecutive words.
    public static let commitWords = [
        "send", "submit", "post", "publish", "buy", "purchase", "pay", "checkout", "check out",
        "place order", "order now", "confirm", "delete", "remove", "trash", "discard", "erase",
        "sign out", "log out", "close", "quit", "accept", "agree", "allow", "install", "update",
        "upgrade", "unsubscribe", "transfer",
    ]
    static let endings: Set<String> = ["", "e", "s", "es", "d", "ed", "ing", "ment"]
    /// The roles that find the control a step is on in the leaf and its two parents (the text
    /// inside a button names the button).
    public static let controlRoles: Set<String> = [
        "AXButton", "AXLink", "AXDisclosureTriangle", "AXMenuItem", "AXMenuBarItem", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTab", "AXSwitch",
    ]
    /// A click is quiet only on a tab, menu item, disclosure, link, checkbox, radio or pop-up. A
    /// plain button is asked whatever its title: a title can't be trusted to say what it commits.
    public static let quietRoles: Set<String> = [
        "AXLink", "AXDisclosureTriangle", "AXMenuItem", "AXMenuBarItem", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXTab",
    ]
    /// Roles that press when they have the keyboard: any key then is asked.
    public static let buttonRoles: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton"]
    /// Why a drag is asked (outside a drive always; inside one, unless DriveClassifier finds a real
    /// slider or divider): it can move a file, or delete one by dropping it on the Trash.
    public static let dragWhy = "a drag can move or delete something"
    /// At most this many free or quiet steps in one turn; the next is asked.
    public static let maxUnaskedSteps = 5
    public static let windowButtonSubroles: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton",
                                                           "AXFullScreenButton"]
    public static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    /// A click is quiet on a control, or on a text field (it only puts the caret there).
    public static var quietClickRoles: Set<String> { quietRoles.union(textRoles) }
    /// Where the app looks for the control a step is on: a control or a field.
    public static var lookRoles: Set<String> { controlRoles.union(textRoles) }
    static let navKeys: Set<String> = ["up", "down", "left", "right", "page_up", "page_down", "home", "end", "tab"]
    static let kindWords: Set<String> = [
        "a", "an", "the", "button", "link", "tab", "menu", "item", "icon", "checkbox", "check", "box",
        "radio", "toggle", "switch", "option", "field", "label", "on", "in", "of", "to", "for", "at",
        "this", "that", "pop", "up", "popup",
    ]

    static func words(_ text: String) -> [String] {
        var out: [String] = [], word = ""
        for scalar in text.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else if !word.isEmpty {
                out.append(word)
                word = ""
            }
        }
        if !word.isEmpty { out.append(word) }
        return out
    }

    static func matches(_ word: String, _ base: String) -> Bool {
        let stem = base.hasSuffix("e") ? String(base.dropLast()) : base
        return word == base || (word.hasPrefix(stem) && endings.contains(String(word.dropFirst(stem.count))))
    }

    /// The first commit word or phrase in `text`, or nil.
    public static func commitWord(_ text: String) -> String? {
        let w = words(text)
        for entry in commitWords {
            let parts = entry.split(separator: " ").map(String.init)
            guard w.count >= parts.count else { continue }
            for i in 0...(w.count - parts.count) {
                let hit = parts.indices.allSatisfy { j in
                    j == parts.count - 1 ? matches(w[i + j], parts[j]) : w[i + j] == parts[j]
                }
                if hit { return entry }
            }
        }
        return nil
    }

    /// The model's label and the element's names share a word that names it (kind words such as
    /// "button" don't count).
    public static func namesMatch(label: String, names: String) -> Bool {
        let wanted = Set(words(label)).subtracting(kindWords)
        return !wanted.isDisjoint(with: words(names))
    }

    /// The engine's class (benji/screen_class.py `plan_class`), and why it is asked.
    /// `unaskedSoFar`: free and quiet steps already done this turn; the sixth is asked.
    public static func plan(_ step: ScreenStep, intent: ScreenStepIntent?, askEveryStep: Bool,
                            askedForText: Bool, unaskedSoFar: Int = 0) -> (ScreenStepClass, String) {
        if askEveryStep { return (.asked, "you chose to be asked before every step") }
        guard intent?.confidence == .high else { return (.asked, "Benji isn't sure this is what you want") }
        if unaskedSoFar >= maxUnaskedSteps {
            return (.asked, "Benji has taken \(maxUnaskedSteps) steps without asking this turn")
        }
        switch step {
        case .scroll:
            return (.free, "")
        case let .pressKey(key, mods):
            if key == "return" || key == "enter" { return (.asked, "Return can send or submit") }
            if key == "escape" { return (.asked, "Escape can close a dialog of yours") }
            if key == "space" { return (.asked, "Space can press a button") }
            if key == "delete" || key == "forward_delete" { return (.asked, "Delete can remove something") }
            if mods.contains(.cmd), ["q", "w", "s", "z", "x", "v"].contains(key) {
                return (.asked, "this shortcut can quit, close, save or change something")
            }
            if mods.contains(.control) { return (.asked, "a Control shortcut can stop a program") }
            if navKeys.contains(key), mods.isEmpty { return (.free, "") }
            return (.quiet, "")
        case .typeText:
            return askedForText ? (.quiet, "") : (.asked, "your message didn't ask for this text")
        case let .click(_, _, _, _, label):
            if let word = commitWord(label) { return (.asked, "“\(word)” may commit something") }
            return (.quiet, "")
        case .drag:
            return (.asked, dragWhy)
        }
    }

    /// The app's class at the point (benji/screen_class.py `final_class`). Never lower than `planned`.
    public static func final(_ step: ScreenStep, planned: ScreenStepClass, element: ScreenElement?,
                             sameApp: Bool) -> (ScreenStepClass, String) {
        if planned == .asked { return (.asked, "") }
        if !sameApp { return (.asked, "it's in another app than the one Benji looked at") }
        switch step {
        case let .click(_, _, _, _, label):
            guard let element else { return (.asked, "Benji can't tell what is under the point") }
            if element.inSheet { return (.asked, "it's in a dialog") }
            if element.role == "AXButton", element.inWebArea ?? true {
                return (.asked, "it's a button in a web page, and a page can name its buttons anything")
            }
            if !quietClickRoles.contains(element.role) || element.subrole.map(windowButtonSubroles.contains) == true {
                return (.asked, "only tabs, links, menu items, checkboxes and fields are clicked without asking")
            }
            if let word = commitWord(element.names) { return (.asked, "“\(word)” may commit something") }
            if !namesMatch(label: label, names: element.names) {
                return (.asked, "what is there doesn't match what Benji named")
            }
            return (planned, "")
        case .typeText:
            guard let element, textRoles.contains(element.role) || element.subrole.map(textRoles.contains) == true else {
                return (.asked, "no text field has the keyboard")
            }
            return (planned, "")
        case .pressKey:
            // What has the keyboard: a dialog's control, or a button a key can press.
            if let element, element.inSheet { return (.asked, "a dialog is open, and a key can answer it") }
            if let element, buttonRoles.contains(element.role) {
                return (.asked, "a button has the keyboard, and a key can press it")
            }
            return (planned, "")
        case .scroll:
            return (planned, "")
        case .drag:
            return (.asked, dragWhy)
        }
    }
}

/// "Act on simple steps" / "Ask before every step" (Settings › Screen). Stored as
/// `screenActionsAsk`: `defaults write com.emerssive.heybenji.app screenActionsAsk -bool YES` asks every step.
public enum ScreenAutonomy {
    public static let defaultsKey = "screenActionsAsk"

    /// Simple steps happen without a card unless the user chose to be asked (the default is on).
    public static func actsOnSimpleSteps(_ stored: Any?) -> Bool { !((stored as? Bool) ?? false) }

    /// How long the target is ringed before Benji acts: a quiet step's beat is longer, and says
    /// how to stop it.
    public static func ringTime(_ mode: ScreenStepClass?) -> Double { mode == .quiet ? 1.2 : 0.6 }

    // Settings › Screen.
    public static let simpleTitle = "Act on simple steps"
    public static let simpleCaption = "Scrolling, tabs, links and menus happen at once while you watch. Anything that could send, buy, delete or close something still asks."
    public static let askTitle = "Ask before every step"
    public static let askCaption = "Every click, scroll or key waits for your OK."
    public static let settingsFooter = "Moving the mouse, typing or pressing Esc stops Benji at once."

    public static let stopHint = "Esc stops"
    public static let actingFallback = "Benji is acting"

    /// The peek's and panel's line while Benji acts unasked: "Scrolling down in Safari · Esc stops".
    public static func actingLine(_ step: ScreenStep?, app: String?) -> String {
        (step.map { ScreenStepCard.acting($0, app: app) } ?? actingFallback) + ActivityLine.separator + stopHint
    }

    /// The label beside a quiet step's ring: "Clicking Settings · Esc stops".
    public static func beatLabel(_ step: ScreenStep) -> String {
        ScreenStepCard.acting(step, app: nil) + ActivityLine.separator + stopHint
    }
}

/// The ring before an unasked (or approved) step: it lasts `ScreenAutonomy.ringTime`, and the
/// user's own input during it stops the step, as `TakeOverWatch` decides.
public struct StepBeat: Equatable, Sendable {
    public enum Decision: Equatable, Sendable { case wait, act, stop }

    public let duration: Double
    /// Benji's own moves are told to it while it acts (`benjiActs`, `benjiMovedPointer`).
    public var watch: TakeOverWatch

    public init(mode: ScreenStepClass?, pointer: CGPoint) {
        duration = ScreenAutonomy.ringTime(mode)
        watch = TakeOverWatch(pointer: pointer)
    }

    @discardableResult
    public mutating func observe(_ input: TakeOverWatch.Input, synthetic: Bool = false) -> Bool {
        watch.observe(input, synthetic: synthetic)
    }

    public func decision(elapsed: Double) -> Decision {
        if watch.tookOver { return .stop }
        return elapsed >= duration ? .act : .wait
    }
}
