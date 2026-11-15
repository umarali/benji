import AppKit
import Combine
import BenjiCore

/// Notices which app is in front and raises an app offer. Reads only the frontmost app's
/// bundle id, needs no permission, and keeps only what `AppOfferRecord` holds. With the switch off
/// every path ends at the first line: no timer runs and nothing is read or stored.
final class AppOfferWatcher {
    private let model: CompanionModel
    private let defaults: UserDefaults
    private let pointerOnNotch: () -> Bool
    private var observer: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []
    private var dwell: DispatchWorkItem?
    private var timeout: DispatchWorkItem?

    init(model: CompanionModel, defaults: UserDefaults = .standard, pointerOnNotch: @escaping () -> Bool) {
        self.model = model
        self.defaults = defaults
        self.pointerOnNotch = pointerOnNotch
    }

    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }

    private var isOn: Bool { AppOfferSettings.isOn(defaults.object(forKey: AppOfferSettings.defaultsKey)) }

    private var record: AppOfferRecord {
        get { AppOfferRecord.decode(defaults.object(forKey: AppOfferRecord.defaultsKey)) }
        set { defaults.set(newValue.encoded(), forKey: AppOfferRecord.defaultsKey) }
    }

    func start() {
        model.onAppOfferAnswered = { [weak self] offer, answer in self?.answered(offer, answer) }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontChanged(app?.bundleIdentifier)
        }
        Publishers.Merge3(model.$state.map { _ in () }, model.$expanded.map { _ in () }, model.$job.map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.model.withdrawAppOfferIfBusy() } }
            .store(in: &cancellables)
        frontChanged(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// The Settings switch moved.
    func switchChanged() {
        if isOn {
            frontChanged(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        } else {
            dwell?.cancel()
            model.answerAppOffer(.notNow)
        }
    }

    func resetAnswers() { record = AppOfferRules.reset(record) }

    private func frontChanged(_ bundleID: String?) {
        dwell?.cancel()
        if let shown = model.appOffer, shown.bundleID != bundleID { model.answerAppOffer(.notNow) }
        guard isOn, let bundleID, AppOfferRules.offer(for: bundleID, record: record, now: Date()) != nil else { return }
        scheduleDwell(bundleID)
    }

    private func scheduleDwell(_ bundleID: String) {
        let work = DispatchWorkItem { [weak self] in self?.dwellEnded(bundleID) }
        dwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AppOfferRules.dwell, execute: work)
    }

    private func dwellEnded(_ bundleID: String) {
        guard isOn, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID,
              let offer = AppOfferRules.offer(for: bundleID, record: record, now: Date()) else { return }
        // Benji is busy just now: look again while the user stays in this app.
        guard model.appOfferMomentIsFree, model.appOffer == nil else { scheduleDwell(bundleID); return }
        // Away from the Mac: a card nobody sees would use up the day's offer.
        let anyInput = CGEventType(rawValue: ~0)!
        guard CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
                < AppOfferRules.activeWithin else { return }
        guard QuietGate().verdict(switchOn: true, signals: QuietSignalsReader.read) == .allowed else { return }
        record = AppOfferRules.recordingShown(offer, in: record, now: Date())
        model.showAppOffer(offer)
        scheduleTimeout(AppOfferRules.timeout)
    }

    private func scheduleTimeout(_ delay: TimeInterval) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.appOffer != nil else { return }
            if self.pointerOnNotch() {
                self.scheduleTimeout(AppOfferRules.timeoutRecheck)
            } else {
                self.model.answerAppOffer(.notNow)
            }
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func answered(_ offer: AppOffer, _ answer: AppOfferAnswer) {
        timeout?.cancel()
        record = AppOfferRules.applying(answer, to: offer, in: record, now: Date())
    }
}
