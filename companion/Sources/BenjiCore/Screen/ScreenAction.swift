import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Acting on the screen: the engine's click, scroll, type_text, press_key and drag tools. The
// engine asks over `benji --serve` (`screen_action`), the app acts on one approved step and
// answers (`screen_result`). Everything here is a pure decision, so it is unit-tested: the step's
// wire form, the card's words, the mapping to the display, the refusals, the take-over watch,
// the one-approval-one-step gate and when the screen has settled. benji/tools/screen_actions.py
// validates the same steps on the engine's side.

/// One step, as the engine sends it (benji/tools/screen_actions.py `screen_step`).
public enum ScreenStep: Equatable, Sendable {
    case click(x: Int, y: Int, button: MouseButton, count: Int, label: String)
    case scroll(x: Int, y: Int, direction: ScrollDirection, amount: Int, label: String)
    case typeText(String)
    case pressKey(key: String, modifiers: [KeyModifier])
    /// Press at (x, y), move to (toX, toY), let go. `label` names what moves and where to.
    case drag(x: Int, y: Int, toX: Int, toY: Int, label: String)

    public enum MouseButton: String, Sendable { case left, right }
    public enum ScrollDirection: String, Sendable { case up, down, left, right }
    public enum KeyModifier: String, CaseIterable, Sendable { case cmd, shift, option, control }

    public static let maxTypedCharacters = 500
    public static let maxScroll = 10

    /// The step's point in the screenshot, for a click or a scroll; where a drag presses.
    public var point: (x: Int, y: Int)? {
        switch self {
        case let .click(x, y, _, _, _), let .scroll(x, y, _, _, _), let .drag(x, y, _, _, _): return (x, y)
        case .typeText, .pressKey: return nil
        }
    }

    /// Where a drag lets go, in the screenshot. Nil for every other step.
    public var endPoint: (x: Int, y: Int)? {
        guard case let .drag(_, _, toX, toY, _) = self else { return nil }
        return (toX, toY)
    }

    /// It goes to the keyboard: the app in front, not the thing under a point.
    public var usesKeyboard: Bool { point == nil }

    /// A key that can send, submit, delete, close or quit something. Mirrors
    /// benji/tools/screen_actions.py `key_may_commit`.
    public var mayCommit: Bool {
        guard case let .pressKey(key, modifiers) = self else { return false }
        if key == "return" || key == "enter" { return true }
        if modifiers.contains(.cmd), ["delete", "forward_delete", "q", "w", "s", "z", "x", "v"].contains(key) { return true }
        return (key == "delete" || key == "forward_delete") && !modifiers.isEmpty
    }

    /// From the `step` object of a `screen_action` event (or an approval's `screen`). Nil for
    /// anything malformed: the app refuses it rather than guess.
    public static func decode(_ o: [String: Any]) -> ScreenStep? {
        func whole(_ key: String) -> Int? {
            guard let n = o[key] as? NSNumber else { return nil }
            let d = n.doubleValue
            guard d.isFinite, d == d.rounded() else { return nil }
            return n.intValue
        }
        func point() -> (Int, Int)? {
            guard let x = whole("x"), let y = whole("y"), x >= 0, y >= 0 else { return nil }
            return (x, y)
        }
        let label = (o["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch o["kind"] as? String {
        case "click":
            guard let (x, y) = point(), !label.isEmpty,
                  let button = MouseButton(rawValue: o["button"] as? String ?? "left"),
                  let count = o["count"] == nil ? 1 : whole("count"), count == 1 || count == 2 else { return nil }
            return .click(x: x, y: y, button: button, count: count, label: label)
        case "scroll":
            guard let (x, y) = point(), let direction = ScrollDirection(rawValue: o["direction"] as? String ?? ""),
                  let amount = whole("amount"), (1...maxScroll).contains(amount) else { return nil }
            return .scroll(x: x, y: y, direction: direction, amount: amount, label: label)
        case "type_text":
            guard let text = o["text"] as? String, !text.isEmpty, text.count <= maxTypedCharacters,
                  !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
            return .typeText(text)
        case "press_key":
            guard let key = o["key"] as? String, KeyCodes.code(for: key) != nil,
                  let raw = (o["modifiers"] ?? [Any]()) as? [Any] else { return nil }
            var mods: [KeyModifier] = []
            for m in raw {
                guard let name = m as? String, let mod = KeyModifier(rawValue: name) else { return nil }
                if !mods.contains(mod) { mods.append(mod) }
            }
            return .pressKey(key: key, modifiers: KeyModifier.allCases.filter(mods.contains))
        case "drag":
            guard let (x, y) = point(), let toX = whole("to_x"), let toY = whole("to_y"), toX >= 0, toY >= 0,
                  (x, y) != (toX, toY), !label.isEmpty else { return nil }
            return .drag(x: x, y: y, toX: toX, toY: toY, label: label)
        default:
            return nil
        }
    }

    /// The wire form (benji/tools/screen_actions.py `screen_step`), keys as the engine writes them.
    public var object: [String: Any] {
        switch self {
        case let .click(x, y, button, count, label):
            return ["kind": "click", "x": x, "y": y, "button": button.rawValue, "count": count, "label": label]
        case let .scroll(x, y, direction, amount, label):
            return ["kind": "scroll", "x": x, "y": y, "direction": direction.rawValue, "amount": amount, "label": label]
        case let .typeText(text):
            return ["kind": "type_text", "text": text]
        case let .pressKey(key, modifiers):
            return ["kind": "press_key", "key": key, "modifiers": modifiers.map(\.rawValue)]
        case let .drag(x, y, toX, toY, label):
            return ["kind": "drag", "x": x, "y": y, "to_x": toX, "to_y": toY, "label": label]
        }
    }
}

/// The approval card's words for a step, and the line the model gets back when it's done. The
/// card names the app the step would act in, as Benji found it when the card went up.
public enum ScreenStepCard {
    /// Said on the card: every step also sends a fresh picture of the screen to the model.
    public static let looksAgain = "then Benji looks at the screen again"

    /// The card's headline, a verb phrase ("click in Safari"), as for every approval. `endApp`: where
    /// a drag lets go, when that is known; a drag across two apps names both.
    public static func action(_ step: ScreenStep, app: String?, endApp: String? = nil) -> String {
        let place = app.map { " in \($0)" } ?? " on the screen"
        switch step {
        case let .click(_, _, button, count, _):
            return verb(button: button, count: count) + place
        case let .scroll(_, _, direction, _, _):
            return "scroll \(direction.rawValue)" + place
        case .typeText:
            return "type" + (app.map { " in \($0)" } ?? "")
        case .pressKey:
            return "press a key" + (app.map { " in \($0)" } ?? "")
        case .drag:
            return "drag" + (dragPlace(app: app, endApp: endApp) ?? place)
        }
    }

    /// " from Finder to Dock" when a drag crosses two apps; nil when one app (or none) is named.
    static func dragPlace(app: String?, endApp: String?) -> String? {
        guard let app, let endApp, app != endApp else { return nil }
        return " from \(app) to \(endApp)"
    }

    /// What Benji is doing, as the activity line says it while it acts unasked:
    /// "Scrolling down in Safari", "Clicking Settings", "Pressing ⌘L in Safari".
    public static func acting(_ step: ScreenStep, app: String?) -> String {
        let place = app.map { " in \($0)" } ?? ""
        switch step {
        case let .click(_, _, button, count, label):
            let v: String
            switch (button, count) {
            case (.left, 2): v = "Double-clicking"
            case (.right, _): v = "Right-clicking"
            default: v = "Clicking"
            }
            return "\(v) \(label.isEmpty ? "on the screen" : label)\(place)"
        case let .scroll(_, _, direction, _, _):
            return "Scrolling \(direction.rawValue)\(place)"
        case .typeText:
            return "Typing\(place)"
        case let .pressKey(key, modifiers):
            return "Pressing \(keys(key, modifiers))\(place)"
        case let .drag(_, _, _, _, label):
            return "Dragging \(label)\(place)"
        }
    }

    /// The card's detail with what the step is for and, when Benji's own look decided
    /// to ask, why: "Send button · to send your reply to Sara; then Benji looks at the screen
    /// again. Asked because it's in a dialog".
    public static func target(_ step: ScreenStep, intent: ScreenStepIntent?, why: String? = nil) -> String {
        guard let intent, !intent.intent.isEmpty else { return target(step) + asked(why) }
        let base = target(step)
        let what = base.hasSuffix("; \(looksAgain)") ? String(base.dropLast(looksAgain.count + 2)) : base
        return "\(what) · \(intent.intent); \(looksAgain)" + asked(why)
    }

    static func asked(_ why: String?) -> String {
        guard let why, !why.isEmpty else { return "" }
        return ". Asked because \(why)"
    }

    /// The card's detail: the target, then what follows.
    public static func target(_ step: ScreenStep) -> String {
        let what: String
        switch step {
        case let .click(_, _, _, _, label):
            what = label
        case let .scroll(_, _, _, amount, label):
            what = (label.isEmpty ? "" : "\(label), ") + scrollAmount(amount)
        case let .typeText(text):
            what = "“\(brief(text, 120))” into the field that has the keyboard"
        case let .pressKey(key, modifiers):
            what = keys(key, modifiers) + (step.mayCommit ? ". This may send, submit, delete or close something" : "")
        case let .drag(_, _, _, _, label):
            what = "\(label). This may move or delete something"
        }
        return "\(what); \(looksAgain)"
    }

    /// The tool result's first words when the step was done ("Clicked Save button in TextEdit.").
    public static func done(_ step: ScreenStep, app: String?, endApp: String? = nil) -> String {
        let place = app.map { " in \($0)" } ?? ""
        switch step {
        case let .click(_, _, button, count, label):
            let v: String
            switch (button, count) {
            case (.left, 2): v = "Double-clicked"
            case (.right, 2): v = "Right-clicked twice on"
            case (.right, _): v = "Right-clicked"
            default: v = "Clicked"
            }
            return "\(v) \(label)\(place)."
        case let .scroll(_, _, direction, amount, _):
            return "Scrolled \(direction.rawValue) \(scrollAmount(amount))\(place)."
        case let .typeText(text):
            return "Typed \(text.count) character\(text.count == 1 ? "" : "s")\(place)."
        case let .pressKey(key, modifiers):
            return "Pressed \(keys(key, modifiers))\(place)."
        case let .drag(_, _, _, _, label):
            return "Dragged \(label)\(dragPlace(app: app, endApp: endApp) ?? place)."
        }
    }

    static func verb(button: ScreenStep.MouseButton, count: Int) -> String {
        switch (button, count) {
        case (.left, 2): return "double-click"
        case (.right, 2): return "right-click twice"
        case (.right, _): return "right-click"
        default: return "click"
        }
    }

    static func scrollAmount(_ amount: Int) -> String {
        switch amount {
        case ...2: return "a few lines"
        case 3...4: return "about a third of a screen"
        case 5...7: return "about half a screen"
        default: return "about a screenful"
        }
    }

    /// "⌘⇧L", "Return", "⌘Page Down".
    public static func keys(_ key: String, _ modifiers: [ScreenStep.KeyModifier]) -> String {
        let marks: [ScreenStep.KeyModifier: String] = [.control: "⌃", .option: "⌥", .shift: "⇧", .cmd: "⌘"]
        let order: [ScreenStep.KeyModifier] = [.control, .option, .shift, .cmd]   // the order menus show
        let name = key.count == 1 ? key.uppercased()
            : key.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return order.filter(modifiers.contains).compactMap { marks[$0] }.joined() + name
    }

    static func brief(_ s: String, _ limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit - 1)) + "…"
    }
}

/// Virtual key codes (the Carbon kVK_ values) for the key names the engine sends, and the event
/// flags for modifiers.
public enum KeyCodes {
    static let table: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "equal": 24, "9": 25, "7": 26, "minus": 27, "8": 28, "0": 29, "right_bracket": 30, "o": 31, "u": 32,
        "left_bracket": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "quote": 39, "k": 40,
        "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44, "n": 45, "m": 46, "period": 47,
        "tab": 48, "space": 49, "grave": 50, "delete": 51, "escape": 53, "enter": 76,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
        "f10": 109, "f11": 103, "f12": 111, "home": 115, "page_up": 116, "forward_delete": 117,
        "end": 119, "page_down": 121, "left": 123, "right": 124, "down": 125, "up": 126,
    ]
    public static let escape: UInt16 = 53

    public static func code(for key: String) -> UInt16? { table[key] }

    /// CGEventFlags raw values: maskCommand, maskShift, maskAlternate, maskControl.
    public static func flags(_ modifiers: [ScreenStep.KeyModifier]) -> UInt64 {
        modifiers.reduce(0) { acc, m in
            switch m {
            case .cmd: return acc | 0x0010_0000
            case .shift: return acc | 0x0002_0000
            case .option: return acc | 0x0008_0000
            case .control: return acc | 0x0004_0000
            }
        }
    }
}

/// Where a step's point is on the display, and how far a scroll goes.
public enum ScreenActionGeometry {
    /// The point in AppKit coordinates (origin bottom-left), kept just inside the display so a
    /// point on the image's far edge doesn't land on the next display. Nil outside the image.
    public static func appKitPoint(x: Int, y: Int, pixelSize: CGSize, screenFrame: CGRect) -> CGPoint? {
        guard let p = PointMapping.screenPoint(x: x, y: y, pixelSize: pixelSize, screenFrame: screenFrame) else { return nil }
        return CGPoint(x: min(max(p.x, screenFrame.minX), screenFrame.maxX - 1),
                       y: min(max(p.y, screenFrame.minY + 1), screenFrame.maxY))
    }

    /// An AppKit point back to whole pixels of the screenshot (to ring the field that has the
    /// keyboard). Nil when it isn't on that display.
    public static func pixel(for p: CGPoint, pixelSize: CGSize, screenFrame: CGRect) -> (x: Int, y: Int)? {
        guard screenFrame.width > 0, screenFrame.height > 0, screenFrame.contains(p) else { return nil }
        let x = (p.x - screenFrame.minX) * pixelSize.width / screenFrame.width
        let y = (screenFrame.maxY - p.y) * pixelSize.height / screenFrame.height
        return (Int(x.rounded()), Int(y.rounded()))
    }

    /// The app whose window was in front at `p` (AppKit points) when the screenshot was taken,
    /// leaving out Benji's own windows (the panel may cover the point while the card is up).
    /// `hit` is the app Accessibility finds at the point now: the window list can't tell a
    /// click-through overlay (the system's Screenshot UI) from a window, so when only overlays
    /// (not normal windows, layer 0) were in front of `hit`'s window, the click goes to `hit`.
    public static func windowOwner(at p: CGPoint, windows: [WindowInfo], excludingPID: Int32, hit: Int32? = nil) -> Int32? {
        let stack = windows.filter { $0.ownerPID != excludingPID && $0.alpha > 0 && $0.frame.contains(p) }
        guard let hit, let at = stack.firstIndex(where: { $0.ownerPID == hit }),
              stack[..<at].allSatisfy({ $0.layer != 0 }) else { return stack.first?.ownerPID }
        return hit
    }

    /// The app in front when the screenshot was taken: the owner of the frontmost normal window,
    /// Benji's own left out (for a key or typing step taken unasked).
    public static func frontApp(windows: [WindowInfo], excludingPID: Int32) -> Int32? {
        windows.first { $0.ownerPID != excludingPID && $0.layer == 0 && $0.alpha > 0 }?.ownerPID
    }

    /// AppKit coordinates to the global display coordinates events and Accessibility use (origin
    /// at the primary display's top-left). `primaryMaxY` is the primary display's frame.maxY.
    public static func globalPoint(_ appKit: CGPoint, primaryMaxY: CGFloat) -> CGPoint {
        CGPoint(x: appKit.x, y: primaryMaxY - appKit.y)
    }

    /// One wheel event moves at most this many points; a scroll is a run of them.
    public static let scrollStep: Int32 = 40

    /// The wheel deltas (pixel units; vertical, horizontal) for a scroll of `amount` (1 to 10:
    /// 10 is about nine tenths of the display's height or width). Positive vertical is up, positive
    /// horizontal is left, as scroll-wheel events count them.
    public static func scrollDeltas(direction: ScreenStep.ScrollDirection, amount: Int,
                                    displaySize: CGSize) -> [(vertical: Int32, horizontal: Int32)] {
        let a = CGFloat(min(max(amount, 1), ScreenStep.maxScroll))
        let along = direction == .up || direction == .down ? displaySize.height : displaySize.width
        var left = Int32((along * 0.09 * a).rounded())
        var out: [(Int32, Int32)] = []
        while left > 0 {
            let d = min(left, scrollStep)
            left -= d
            switch direction {
            case .up: out.append((d, 0))
            case .down: out.append((-d, 0))
            case .left: out.append((0, d))
            case .right: out.append((0, -d))
            }
        }
        return out
    }
}

/// The events of one drag, in AppKit points: press, a short hold, the path, a short hold, let go.
/// The holds are what let apps see a drag start and a drop target light up; every event is `interval`
/// seconds after the one before. Pure, so the path is tested without posting anything.
public enum DragPath {
    public enum Event: Equatable, Sendable {
        case move(CGPoint), down(CGPoint), dragged(CGPoint), up(CGPoint)

        public var point: CGPoint {
            switch self {
            case let .move(p), let .down(p), let .dragged(p), let .up(p): return p
            }
        }
    }

    public static let interval: Double = 0.012
    /// Points between two events on the path.
    static let spacing: CGFloat = 10
    /// The longest path, in events (about 1.4 s).
    static let maxSegments = 120
    /// Events held still after the press and before the release (about 70 ms each).
    static let holdEvents = 6

    public static func events(from start: CGPoint, to end: CGPoint) -> [Event] {
        let segments = min(max(Int((hypot(end.x - start.x, end.y - start.y) / spacing).rounded(.up)), 2), maxSegments)
        let path = (1...segments).map { i -> Event in
            let t = CGFloat(i) / CGFloat(segments)
            return .dragged(i == segments ? end : CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
        return [Event.move(start), Event.down(start)]
            + Array(repeating: Event.dragged(start), count: holdEvents)
            + path
            + Array(repeating: Event.dragged(end), count: holdEvents)
            + [.up(end)]
    }

    /// Letting go when the user took over mid-drag: back to where the drag began and up there, so
    /// nothing is dropped on whatever the pointer was crossing, then the pointer back to the user.
    public static func letGo(start: CGPoint, pointer: CGPoint) -> [Event] {
        [.dragged(start), .up(start), .move(pointer)]
    }
}

/// What the app found where a step would act: the element under the point (click, scroll) or
/// the one with the keyboard (type, press a key), as Accessibility reports it.
public struct ScreenTarget: Equatable, Sendable {
    public let pid: Int32
    public let bundleID: String?
    public let appName: String?
    /// The element's role and subrole ("AXButton", "AXSecureTextField"), leaf first, then its
    /// parents (at most a few), for picking AXPress.
    public let roles: [String]
    public let subrole: String?
    /// Actions each of those elements offers, in the same order.
    public let actions: [[String]]
    /// The element is inside a web page (an AXWebArea above it).
    public let inWebArea: Bool
    /// The focused element's AXSelectedText can be set (typing inserts at the caret).
    public let canInsertText: Bool
    /// The control there, its names and whether a dialog is above it, for a step's class.
    public let element: ScreenElement?

    public init(pid: Int32, bundleID: String?, appName: String?, roles: [String] = [], subrole: String? = nil,
                actions: [[String]] = [], inWebArea: Bool = false, canInsertText: Bool = false,
                element: ScreenElement? = nil) {
        self.element = element
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.roles = roles
        self.subrole = subrole
        self.actions = actions
        self.inWebArea = inWebArea
        self.canInsertText = canInsertText
    }

    public var isSecureField: Bool {
        roles.first == "AXSecureTextField" || subrole == "AXSecureTextField"
    }
}

/// Why a step wasn't done; `text` goes to the model and the panel.
public enum ScreenRefusal: Equatable, Sendable {
    case noAccessibility, secureInput, benjiWindow, passwordManager, secureField
    case appChanged, nothingThere, outsideScreenshot, noScreenshot, notApproved, unreadable

    public var text: String {
        switch self {
        case .noAccessibility:
            return "Benji needs Accessibility permission to click and type (System Settings › Privacy & Security › Accessibility)."
        case .secureInput:
            return "A password field or secure input is active, so Benji won't act on the screen."
        case .benjiWindow:
            return "That point is on Benji's own window; Benji never acts on itself."
        case .passwordManager:
            return "That's a password manager; Benji never acts in one."
        case .secureField:
            return "That's a password field; Benji never clicks or types in one."
        case .appChanged:
            return "The app there changed after you approved, so nothing was done."
        case .nothingThere:
            return "Benji couldn't find anything to act on there."
        case .outsideScreenshot:
            return "That point is outside the screenshot."
        case .noScreenshot:
            return "There's no screenshot for this step to act on."
        case .notApproved:
            return "That step isn't the one you approved, so nothing was done."
        case .unreadable:
            return "Benji couldn't read that step."
        }
    }
}

public enum ScreenActionPolicy {
    /// The panel's line when the user takes the screen back.
    public static let tookOverLine = "Stopped: you took over"
    /// Added to that line when the user took over in the middle of a drag.
    public static let dragLetGo = ", so Benji let go where the drag began."
    /// A drag interrupted inside a drive: the step fails and the drive's own rules decide what follows.
    public static let dragInterrupted = "The drag was interrupted, so Benji let go where it began. Look at the screen before trying again."

    /// What refuses any step before Benji looks at the target (or rings it).
    public static func precheck(accessibility: Bool, secureInput: Bool) -> ScreenRefusal? {
        if !accessibility { return .noAccessibility }
        if secureInput { return .secureInput }
        return nil
    }

    /// The first reason not to do `step` against `target`, or nil to go ahead. `approvedPID` is
    /// the app named on the card (nil: none was found then). A drag has two ends and each must pass:
    /// `endTarget` is what is where it lets go, `approvedEndPID` the app the card named there
    /// (nil: the card named one app, so both ends must be in it).
    public static func refusal(for step: ScreenStep, target: ScreenTarget?, accessibility: Bool,
                               secureInput: Bool, ownPID: Int32, approvedPID: Int32?,
                               endTarget: ScreenTarget? = nil, approvedEndPID: Int32? = nil) -> ScreenRefusal? {
        if let why = precheck(accessibility: accessibility, secureInput: secureInput) { return why }
        if let why = refusal(at: target, ownPID: ownPID, approvedPID: approvedPID) { return why }
        guard step.endPoint != nil else { return nil }
        return refusal(at: endTarget, ownPID: ownPID, approvedPID: approvedEndPID ?? approvedPID)
    }

    private static func refusal(at target: ScreenTarget?, ownPID: Int32, approvedPID: Int32?) -> ScreenRefusal? {
        guard let target else { return .nothingThere }
        if target.pid == ownPID { return .benjiWindow }
        if let id = target.bundleID, CaptureExclusions.passwordManagers.contains(id) { return .passwordManager }
        if target.isSecureField { return .secureField }
        if let approvedPID, approvedPID != target.pid { return .appChanged }
        return nil
    }
}

/// How a click is done: Accessibility's AXPress on a control under the point (it needs no
/// pointer), or synthetic mouse events.
public enum ClickMethod: Equatable, Sendable {
    /// Press the element `level` steps up from the one under the point (0: that one).
    case press(level: Int)
    case events

    /// Roles AXPress means a plain click for.
    static let pressable: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuBarItem", "AXPopUpButton",
        "AXMenuButton", "AXLink", "AXDisclosureTriangle", "AXTab", "AXSwitch",
    ]

    /// Only a single left click on a control that offers AXPress (itself or a parent up to two
    /// steps up, e.g. the label inside a button) is pressed; anything else is clicked.
    public static func choose(for step: ScreenStep, target: ScreenTarget) -> ClickMethod {
        guard case let .click(_, _, button, count, _) = step, button == .left, count == 1 else { return .events }
        for level in 0..<min(3, target.roles.count) {
            let actions = level < target.actions.count ? target.actions[level] : []
            if pressable.contains(target.roles[level]), actions.contains("AXPress") { return .press(level: level) }
        }
        return .events
    }
}

/// How text is typed: inserted at the caret through Accessibility (AXSelectedText) in a native
/// text field, or as synthetic key events, which a web page sees as typing.
public enum TypingMethod: Equatable, Sendable {
    case insert, keys

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    public static func choose(target: ScreenTarget) -> TypingMethod {
        guard let role = target.roles.first, textRoles.contains(role), target.canInsertText, !target.inWebArea else {
            return .keys
        }
        return .insert
    }

    /// Key events carry at most this many UTF-16 units each.
    public static let chunk = 20

    /// The text in pieces for key events, never splitting a character.
    public static func chunks(_ text: String) -> [String] {
        var out: [String] = [], piece = ""
        for ch in text {
            if piece.utf16.count + ch.utf16.count > chunk, !piece.isEmpty {
                out.append(piece)
                piece = ""
            }
            piece.append(ch)
        }
        if !piece.isEmpty { out.append(piece) }
        return out
    }
}

/// One approval, one step: the app acts only on the step the user just approved, once.
public struct ScreenStepGate: Equatable, Sendable {
    public struct Approval: Equatable, Sendable {
        public let step: ScreenStep
        /// The app named on the card; nil when none was found then.
        public let appPID: Int32?
        /// The app the card named where a drag lets go; nil when it named no other.
        public let endAppPID: Int32?
    }
    private var approved: Approval?

    public init() {}

    public mutating func approve(_ step: ScreenStep, appPID: Int32?, endAppPID: Int32? = nil) {
        approved = Approval(step: step, appPID: appPID, endAppPID: endAppPID)
    }
    public mutating func clear() { approved = nil }

    /// The approval for exactly this step, used up; nil when it isn't the step approved.
    public mutating func take(_ step: ScreenStep) -> Approval? {
        defer { approved = nil }
        return approved?.step == step ? approved : nil
    }
}

/// Watches the user's own input while a step runs: a mouse move, click, scroll, key or modifier
/// is the user taking over, and the step stops. Benji's own events are told apart by the marker
/// they carry (`synthetic`) and, in case a monitor loses it, by what Benji is doing right then:
/// its own clicks land where it put the pointer, its own keys are the ones it is pressing.
public struct TakeOverWatch: Equatable, Sendable {
    /// A pointer this far (points) from where it should be has been moved by the user.
    public static let moveTolerance: CGFloat = 6
    /// During a drag: how far from a point Benji posted its own event can be reported.
    public static let trailTolerance: CGFloat = 1

    public enum Input: Equatable, Sendable {
        case pointerMoved(CGPoint)
        case mouseDown(CGPoint)
        case keyDown(UInt16)
        case modifiersChanged
        case scroll(CGPoint)
    }

    public private(set) var tookOver = false
    /// Where the pointer should be: where it was when the step began, then where Benji put it.
    private var expected: CGPoint
    /// While Benji acts: its own pointer position, and the keys it is pressing.
    private var acting = false
    private var ownKeys: Set<UInt16> = []
    private var ownModifiers = false
    /// A drag under way: the button is held and the pointer has left where it was pressed.
    private var dragging = false
    private var pressedAt: CGPoint?
    /// Every point Benji has dragged through.
    private var trail: [CGPoint] = []

    public init(pointer: CGPoint) { expected = pointer }

    /// Benji moved the pointer (to click or scroll there).
    public mutating func benjiMovedPointer(to p: CGPoint) { expected = p }

    /// Benji starts posting its own events: these keys (and modifiers) and clicks at the pointer.
    public mutating func benjiActs(keys: Set<UInt16> = [], modifiers: Bool = false) {
        acting = true
        ownKeys = keys
        ownModifiers = modifiers
    }

    /// Benji is about to post this event of a drag. Its next position replaces the user's every
    /// few milliseconds, so a move of the user's never adds up to `moveTolerance`: from here on an
    /// unmarked move is Benji's own only if it lands on the path Benji has posted.
    public mutating func benjiPosts(_ event: DragPath.Event) {
        expected = event.point
        switch event {
        case let .move(p), let .down(p):
            pressedAt = p
        case let .dragged(p):
            trail.append(p)
            if p != pressedAt { dragging = true }
        case .up:
            dragging = false
            pressedAt = nil
            trail = []
        }
    }

    public mutating func benjiDone() {
        acting = false
        ownKeys = []
        ownModifiers = false
        dragging = false
        pressedAt = nil
        trail = []
    }

    /// True once the user has taken over (it stays true).
    @discardableResult
    public mutating func observe(_ input: Input, synthetic: Bool = false) -> Bool {
        guard !tookOver, !synthetic else { return tookOver }
        switch input {
        case let .pointerMoved(p) where dragging:
            tookOver = !trail.contains { distance(p, $0) <= Self.trailTolerance }
        case let .pointerMoved(p):
            tookOver = distance(p, expected) > Self.moveTolerance
        case let .mouseDown(p):
            tookOver = dragging || !(acting && distance(p, expected) <= Self.moveTolerance)
        case let .keyDown(code):
            tookOver = code == KeyCodes.escape || !(acting && ownKeys.contains(code))
        case .modifiersChanged:
            tookOver = !(acting && ownModifiers)
        case let .scroll(p):
            tookOver = dragging || !(acting && distance(p, expected) <= Self.moveTolerance)
        }
        return tookOver
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

/// When the screen has settled after a step: small samples of the display taken a moment apart
/// that (almost) match, or the time is up.
public enum ScreenSettle {
    /// Before the first sample: the app reacts.
    public static let firstWait: Double = 0.3
    public static let interval: Double = 0.2
    /// The longest Benji waits before looking anyway.
    public static let longest: Double = 2.5
    /// The sample's width in pixels.
    public static let sampleWidth = 160

    /// Two samples (8-bit channels, same size) match when at most 0.5% of their values differ by
    /// more than 24: a caret's blink or a spinner passes, a page that is still loading doesn't.
    public static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var differ = 0
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > 24 { differ += 1 }
        return Double(differ) <= Double(a.count) * 0.005
    }

    /// Whether to take the fresh screenshot now, `elapsed` seconds after the step, given whether
    /// the last two samples matched.
    public static func ready(elapsed: Double, lastTwoSame: Bool) -> Bool {
        lastTwoSame || elapsed >= longest
    }
}

/// The settings switch (`defaults write com.emerssive.heybenji.app screenActions -bool NO` turns it off).
public enum ScreenActions {
    public static let defaultsKey = "screenActions"

    /// On unless set to false.
    public static func isOn(_ stored: Any?) -> Bool { (stored as? Bool) ?? true }
}

/// How a step ended, as the app tells the engine (`screen_result`).
public struct ScreenStepResult: Equatable, Sendable {
    /// `ask`: an unasked step that the app's own look says must be asked first; nothing was done.
    public enum Status: String, Sendable { case done, refused, stopped, failed, ask }
    public let status: Status
    public let text: String
    /// The fresh screenshot after a done step.
    public let imagePath: String?

    public init(status: Status, text: String, imagePath: String? = nil) {
        self.status = status
        self.text = text
        self.imagePath = imagePath
    }

    public static func refused(_ why: ScreenRefusal) -> ScreenStepResult { .init(status: .refused, text: why.text) }
    public static func ask(_ why: String) -> ScreenStepResult { .init(status: .ask, text: why) }
}
