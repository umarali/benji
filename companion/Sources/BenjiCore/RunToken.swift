import Foundation

/// One foreground engine run at a time, named by a number that is never reused. The backend tags
/// every event and finish with the run it came from; only the live run's are admitted. Cancelling
/// (or finishing) ends the run, so whatever it still says arrives as stale and is dropped: a late
/// answer, error or approval can't revive a cancelled turn or land in the next one.
public struct RunToken: Equatable, Sendable {
    public private(set) var live: Int?
    private var last = 0

    public init() {}

    /// A new run replaces any live one.
    public mutating func begin() -> Int {
        last += 1
        live = last
        return last
    }

    public mutating func end() { live = nil }

    public var isLive: Bool { live != nil }

    public func admits(_ run: Int) -> Bool { run == live }
}
