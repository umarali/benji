import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One on-screen window, as `CGWindowListCopyWindowInfo` describes it (no titles: those need
/// Screen Recording and aren't needed here).
public struct WindowInfo: Equatable, Sendable {
    public let id: UInt32
    public let ownerPID: Int32
    public let layer: Int
    public let alpha: Double
    /// AppKit global points (origin bottom-left of the primary display, y up).
    public let frame: CGRect

    public init(id: UInt32, ownerPID: Int32, layer: Int = 0, alpha: Double = 1, frame: CGRect) {
        self.id = id
        self.ownerPID = ownerPID
        self.layer = layer
        self.alpha = alpha
        self.frame = frame
    }
}

/// Notices when the window a mark sits on moves, resizes, closes or is covered (Overlay.md,
/// Lifetime and erase: the 4 Hz window-list poll, which needs no permission).
public enum WindowTracking {
    /// Frames this close count as unchanged (window lists report whole points).
    public static let tolerance: CGFloat = 1

    /// Window-list dictionaries (front to back) to windows. Keys are the `kCGWindow…` names.
    public static func windows(from list: [[String: Any]], primaryHeight: CGFloat) -> [WindowInfo] {
        list.compactMap { d in
            guard let id = (d["kCGWindowNumber"] as? NSNumber)?.uint32Value,
                  let pid = (d["kCGWindowOwnerPID"] as? NSNumber)?.int32Value,
                  let b = d["kCGWindowBounds"] as? [String: Any],
                  let x = (b["X"] as? NSNumber)?.doubleValue, let y = (b["Y"] as? NSNumber)?.doubleValue,
                  let w = (b["Width"] as? NSNumber)?.doubleValue, let h = (b["Height"] as? NSNumber)?.doubleValue
            else { return nil }
            return WindowInfo(id: id, ownerPID: pid,
                              layer: (d["kCGWindowLayer"] as? NSNumber)?.intValue ?? 0,
                              alpha: (d["kCGWindowAlpha"] as? NSNumber)?.doubleValue ?? 1,
                              frame: appKitFrame(cgBounds: CGRect(x: x, y: y, width: w, height: h),
                                                 primaryHeight: primaryHeight))
        }
    }

    /// Window-list bounds start at the primary display's top-left with y down; AppKit's start
    /// at its bottom-left with y up.
    public static func appKitFrame(cgBounds b: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: b.minX, y: primaryHeight - b.maxY, width: b.width, height: b.height)
    }

    /// What a mark watches: the topmost window under its target at capture time, and the
    /// windows already in front of it there (they didn't hide the target from the model, so
    /// they're see-through or out of the way, and don't count as covering it later).
    public struct Watch: Equatable, Sendable {
        public let window: WindowInfo
        public let area: CGRect
        public let alreadyInFront: Set<UInt32>
    }

    public enum Change: Equatable, Sendable { case none, moved, closed, covered }

    static func visible(_ w: WindowInfo, excluding pid: Int32) -> Bool {
        w.ownerPID != pid && w.alpha > 0 && w.frame.width > 1 && w.frame.height > 1
    }

    /// `area`: the target (a ring's circle, a region's box). Nil when no window is under it.
    public static func watch(area: CGRect, in windows: [WindowInfo], excludingPID pid: Int32) -> Watch? {
        let centre = CGPoint(x: area.midX, y: area.midY)
        guard let i = windows.firstIndex(where: { visible($0, excluding: pid) && $0.frame.contains(centre) })
        else { return nil }
        let front = windows[..<i].filter { visible($0, excluding: pid) && $0.frame.intersects(area) }
        return Watch(window: windows[i], area: area, alreadyInFront: Set(front.map(\.id)))
    }

    public static func change(for watch: Watch, now windows: [WindowInfo], excludingPID pid: Int32) -> Change {
        guard let i = windows.firstIndex(where: { $0.id == watch.window.id }) else { return .closed }
        let a = windows[i].frame, b = watch.window.frame
        if abs(a.minX - b.minX) > tolerance || abs(a.minY - b.minY) > tolerance
            || abs(a.width - b.width) > tolerance || abs(a.height - b.height) > tolerance { return .moved }
        let covering = windows[..<i].contains {
            visible($0, excluding: pid) && !watch.alreadyInFront.contains($0.id) && $0.frame.intersects(watch.area)
        }
        return covering ? .covered : .none
    }
}

extension WindowTracking {
    /// Every target of one plan against the windows it sits on (D-106): one entry per distinct
    /// window, with the targets on it. Built from the capture's window list, so it costs no
    /// window-list read; `watch(for:)` is exactly what `watch(area:in:excludingPID:)` returns.
    public struct PlanWatch: Equatable, Sendable {
        public struct Target: Equatable, Sendable {
            public let item: Int
            public let area: CGRect
            public let alreadyInFront: Set<UInt32>
        }

        /// The distinct windows under the plan's targets, in the order first used.
        public let windows: [WindowInfo]
        /// `targets[k]`: the targets on `windows[k]`.
        public let targets: [[Target]]
        private let place: [Int: (window: Int, target: Int)]

        public static func == (a: PlanWatch, b: PlanWatch) -> Bool { a.windows == b.windows && a.targets == b.targets }

        /// `areas[i]`: item i's target (a ring's circle, a pen mark's hit area).
        public init(areas: [CGRect], in captured: [WindowInfo], excludingPID pid: Int32) {
            var windows: [WindowInfo] = [], targets: [[Target]] = [], place: [Int: (window: Int, target: Int)] = [:]
            for (item, area) in areas.enumerated() {
                guard let w = WindowTracking.watch(area: area, in: captured, excludingPID: pid) else { continue }
                let k = windows.firstIndex(of: w.window) ?? { windows.append(w.window); targets.append([]); return windows.count - 1 }()
                place[item] = (k, targets[k].count)
                targets[k].append(Target(item: item, area: w.area, alreadyInFront: w.alreadyInFront))
            }
            self.windows = windows
            self.targets = targets
            self.place = place
        }

        public var isEmpty: Bool { windows.isEmpty }

        /// Item i's watch; nil when no window was under it.
        public func watch(for item: Int) -> Watch? {
            guard let p = place[item] else { return nil }
            let t = targets[p.window][p.target]
            return Watch(window: windows[p.window], area: t.area, alreadyInFront: t.alreadyInFront)
        }

        /// The items whose window has moved, closed or been covered over them, by `windows`
        /// (front to back). Each window is looked up once; the same answers as
        /// `change(for:now:excludingPID:)` item by item.
        public func changes(now list: [WindowInfo], excludingPID pid: Int32) -> [Int: Change] {
            var out: [Int: Change] = [:]
            for (k, window) in windows.enumerated() {
                guard let i = list.firstIndex(where: { $0.id == window.id }) else {
                    for t in targets[k] { out[t.item] = .closed }
                    continue
                }
                let a = list[i].frame, b = window.frame
                if abs(a.minX - b.minX) > tolerance || abs(a.minY - b.minY) > tolerance
                    || abs(a.width - b.width) > tolerance || abs(a.height - b.height) > tolerance {
                    for t in targets[k] { out[t.item] = .moved }
                    continue
                }
                let front = list[..<i].filter { visible($0, excluding: pid) }
                for t in targets[k] where front.contains(where: { !t.alreadyInFront.contains($0.id) && $0.frame.intersects(t.area) }) {
                    out[t.item] = .covered
                }
            }
            return out
        }
    }
}

/// Reads the window list for one plan at a time, off the main thread (D-106). `begin` reads it
/// once, on the caller's queue, before the plan's first reveal; after that each `poll` reads it
/// on `work` and hands back only a change in which targets have changed, on `deliver`. A
/// result that comes back after the plan was replaced or ended is dropped (the generation).
/// Everything but the read itself runs on `deliver`, the queue `begin`, `poll` and `end` are
/// called on (the main queue in the app).
public final class WindowPoller: @unchecked Sendable {
    public typealias Source = @Sendable () -> [WindowInfo]

    private let source: Source
    private let work: DispatchQueue
    private let deliver: DispatchQueue
    private let pid: Int32

    public private(set) var generation = 0
    public private(set) var plan: WindowTracking.PlanWatch?
    /// The plan's items whose window has changed, as of the latest read.
    public private(set) var changed: [Int: WindowTracking.Change] = [:]
    private var reading = false
    /// Called on `deliver` when the changed items differ from the last read's.
    public var onChange: (([Int: WindowTracking.Change]) -> Void)?

    public init(source: @escaping Source, work: DispatchQueue, deliver: DispatchQueue, excludingPID pid: Int32) {
        self.source = source
        self.work = work
        self.deliver = deliver
        self.pid = pid
    }

    /// A new plan: one read now, unless no target has a window under it.
    public func begin(_ plan: WindowTracking.PlanWatch) {
        generation += 1
        reading = false
        self.plan = plan
        changed = plan.isEmpty ? [:] : plan.changes(now: source(), excludingPID: pid)
    }

    public func end() {
        generation += 1
        reading = false
        plan = nil
        changed = [:]
    }

    public func change(for item: Int) -> WindowTracking.Change { changed[item] ?? .none }

    /// One read on `work`, unless one is still out or nothing is watched.
    public func poll() {
        guard let plan, !plan.isEmpty, !reading else { return }
        reading = true
        let generation = generation, source = source, pid = pid
        work.async { [weak self] in
            let found = plan.changes(now: source(), excludingPID: pid)
            self?.deliver.async { [weak self] in
                guard let self, generation == self.generation else { return }
                self.reading = false
                guard found != self.changed else { return }
                self.changed = found
                self.onChange?(found)
            }
        }
    }
}
