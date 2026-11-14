import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Which display Benji is on, and which one a message's screenshot is for. Pure decisions in AppKit
// global coordinates (bottom-left origin, y up; a display left of or below the main one has a
// negative origin). The app reads the displays from NSScreen and draws what this decides.

/// One connected display.
public struct DisplayDescriptor: Equatable, Sendable {
    /// `NSScreenNumber`, the same id ScreenCaptureKit uses: a display is never found by index.
    public var id: UInt32
    public var frame: CGRect
    /// The hardware notch, nil on a display without one.
    public var notch: CGRect?
    /// What macOS calls it (`NSScreen.localizedName`).
    public var name: String

    public init(id: UInt32, frame: CGRect, notch: CGRect? = nil, name: String = "") {
        self.id = id
        self.frame = frame
        self.notch = notch
        self.name = name
    }
}

/// The display a message's screenshot is for, chosen when the user starts the message and kept
/// for that message only: through the Ask card, a slow capture and a refused one asked again.
public struct CaptureTarget: Equatable, Sendable {
    public var id: UInt32
    /// The display's name, set only while more than one display is connected (one display needs no name).
    public var name: String?

    public init(id: UInt32, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

public enum CaptureDisplay {
    public enum Choice: Equatable, Sendable {
        case display(UInt32)
        /// The message's display is no longer connected: nothing is captured, no other display stands in.
        case disconnected(CaptureTarget)
        case none
    }

    /// The display under `point`, as AppKit's `NSMouseInRect` counts it (a pointer on the shared
    /// edge belongs to the display whose top or left edge it is).
    public static func display(at point: CGPoint, in displays: [DisplayDescriptor]) -> DisplayDescriptor? {
        displays.first { f in
            point.x >= f.frame.minX && point.x < f.frame.maxX && point.y > f.frame.minY && point.y <= f.frame.maxY
        }
    }

    /// What to latch for a message started on `display`.
    public static func target(for display: DisplayDescriptor, among displays: [DisplayDescriptor]) -> CaptureTarget {
        CaptureTarget(id: display.id, name: displays.count > 1 && !display.name.isEmpty ? display.name : nil)
    }

    /// The target for the display with `id`, named among `displays`; nil when it isn't connected.
    public static func target(id: UInt32?, among displays: [DisplayDescriptor]) -> CaptureTarget? {
        displays.first { $0.id == id }.map { target(for: $0, among: displays) }
    }

    /// The display to capture. A latched display is used if it is still connected and refused if it
    /// is not; without one (nothing was latched), the display under the pointer, then `fallback`.
    public static func choose(requested: CaptureTarget?, displays: [DisplayDescriptor], pointer: CGPoint,
                              fallback: UInt32?) -> Choice {
        if let requested {
            return displays.contains { $0.id == requested.id } ? .display(requested.id) : .disconnected(requested)
        }
        if let under = display(at: pointer, in: displays) { return .display(under.id) }
        if let fallback, displays.contains(where: { $0.id == fallback }) { return .display(fallback) }
        return .none
    }
}

// MARK: - Reaching Benji from every display

/// The quiet bar at the top centre of a display without a hardware notch, where Benji isn't. Its
/// target is larger than what is drawn, so it can be found without precision.
public enum DisplayBar {
    /// What is drawn: 48 × 5 pt.
    public static let barSize = CGSize(width: 48, height: 5)
    /// The hover and click target: 96 × 24 pt, flush with the top of the display.
    public static let hitSize = CGSize(width: 96, height: 24)
    /// From the display's top edge to the bar.
    public static let barTop: CGFloat = 4
    public static let cornerRadius: CGFloat = 2.5

    /// The target, centred at the top of `screenFrame` and never wider or taller than it.
    public static func hitFrame(screenFrame: CGRect) -> CGRect {
        let w = min(hitSize.width, screenFrame.width), h = min(hitSize.height, screenFrame.height)
        return CGRect(x: screenFrame.midX - w / 2, y: screenFrame.maxY - h, width: w, height: h)
    }

    /// The bar inside a target of `hit` size, in the target's own coordinates (y up).
    public static func barFrame(inHit hit: CGSize) -> CGRect {
        let w = min(barSize.width, hit.width)
        return CGRect(x: (hit.width - w) / 2, y: max(0, hit.height - barTop - barSize.height),
                      width: w, height: barSize.height)
    }
}

/// Where a resting pointer brings Benji to another display.
public struct DisplayAnchor: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Home's own zone: its notch (or, without one, where the closed notch sits).
        case notch
        /// A drawn bar on a display without a hardware notch.
        case bar
    }

    public var display: UInt32
    public var kind: Kind
    /// AppKit global coordinates.
    public var zone: CGRect

    public init(display: UInt32, kind: Kind, zone: CGRect) {
        self.display = display
        self.kind = kind
        self.zone = zone
    }

    /// The rest detector uses CGRect's half-open bounds. Include the display's exact top edge
    /// there too; the actual hit zone and window remain their original size.
    public var restZone: CGRect {
        CGRect(x: zone.minX, y: zone.minY, width: zone.width, height: zone.height + 1)
    }
}

public enum DisplayAnchors {
    /// Benji's home: the display with the hardware notch, else the first one (the menu-bar display).
    public static func home(_ displays: [DisplayDescriptor]) -> DisplayDescriptor? {
        displays.first { $0.notch != nil } ?? displays.first
    }

    /// Other displays have an entry point. A flat host also has a bar while the panel is closed;
    /// only an actual hardware notch uses a notch zone, including on a single external display.
    public static func anchors(displays: [DisplayDescriptor], host: UInt32?, panelClosed: Bool = false) -> [DisplayAnchor] {
        return displays.compactMap { d in
            guard d.id != host || (panelClosed && d.notch == nil) else { return nil }
            if d.notch != nil {
                return DisplayAnchor(display: d.id, kind: .notch, zone: PanelGeometry.hotZone(notch: d.notch, screenFrame: d.frame))
            }
            return DisplayAnchor(display: d.id, kind: .bar, zone: DisplayBar.hitFrame(screenFrame: d.frame))
        }
    }

    /// The anchor under `point`, if any.
    public static func anchor(at point: CGPoint, in anchors: [DisplayAnchor]) -> DisplayAnchor? {
        anchors.first { a in
            point.x >= a.zone.minX && point.x < a.zone.maxX && point.y > a.zone.minY && point.y <= a.zone.maxY
        }
    }

    /// Whether the one panel may move to another display: only while it is closed or peeking, the
    /// user hasn't opened it and no card waits there for an answer. `explicit` (a click on a bar)
    /// may also move the open panel, but never away from a waiting card.
    public static func mayMove(target: NotchSize, userOpened: Bool, cardWaiting: Bool, explicit: Bool = false) -> Bool {
        guard !cardWaiting else { return false }
        if explicit { return true }
        return !userOpened && (target == .closed || target == .peek)
    }
}
