import Foundation

/// Notes in `~/.benji/voice.log` whenever the main thread stops answering for longer than
/// `threshold` (a frozen panel, a late send), with how long it was stuck. A background timer asks
/// the main queue to answer ten times a second; durations only, nothing about what was on screen.
final class MainThreadWatch {
    static let shared = MainThreadWatch()

    static let threshold: TimeInterval = 0.25
    private let queue = DispatchQueue(label: "benji.main-thread-watch", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// When the unanswered ping was sent; nil while the main thread is answering.
    private var waitingSince: TimeInterval?

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 0.1, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.ping() }
        timer = t
        t.resume()
    }

    private func ping() {
        guard waitingSince == nil else { return }   // the last ping is still waiting
        let sent = ProcessInfo.processInfo.systemUptime
        waitingSince = sent
        DispatchQueue.main.async { [weak self] in
            let stuck = ProcessInfo.processInfo.systemUptime - sent
            self?.queue.async { self?.waitingSince = nil }
            if stuck > Self.threshold {
                VoiceLogFile.shared.append("[main] blocked \(Int((stuck * 1000).rounded())) ms")
            }
        }
    }
}
