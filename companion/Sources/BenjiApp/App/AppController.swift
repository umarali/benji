import AppKit
import SwiftUI
import Combine
import BenjiCore

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = CompanionModel(backend: FigureStageBackend.wrap(ExplainCardBackend.wrap(
                                           ServeBackend(assistantDir: AppConfig.assistantDir))),
                                       history: ConversationHistory(store: .standard()))
    /// What Benji remembers about the user (the engine's `remember` writes it).
    private let profileURL = ProfileMemory.standardURL()
    private var statusItem: NSStatusItem!
    /// The menu-bar glyphs, by state; the item swaps between them while Benji is busy.
    private var statusGlyphs: [StatusGlyph: NSImage] = [:]
    private var statusGlyphSub: AnyCancellable?
    private var panel: CompanionPanel!
    private var appOffers: AppOfferWatcher?
    private let talkKey = ModifierTalkKey()
    private let pointerCompanion = PointerCompanionWindow()
    private var talkKeyReady = false
    private var voice: VoiceController!
    private let capturer = ScreenCapturer()
    private let pointer = PointerOverlay()
    /// The mint arrowhead beside the system pointer while Benji is active.
    private let actuator = ScreenActuator()
    private let driveMonitor = DriveMonitor()
    private let permissionSetup = PermissionSetupWindowController()
    /// The `BENJI_MODEL` this app put in its environment for the engine (Settings › General ›
    /// Model); nil when it set nothing. It only ever clears its own value.
    private var modelSetByApp: String?
    /// The model changed after the environment was already set: restart a kept engine.
    private var engineRestartPending = false
    /// The latest picture waiting for its busy map (a newer answer's wins).
    private var pointGeneration = 0
    /// What the engine says it uses (`--print-provider`): its provider and model.
    private var engineProvider: String?
    private var engineModelInUse: String?
    private var engineDestination = ""
    /// Why the last Settings › Voice preview didn't play (shown under the voices); nil when it did.
    private var voicePreviewNote: String?
    private let handsFreeWatcher = HandsFreeWatcher()
    /// The link to the browser extension, as the engine last said; off when it isn't running.
    private var browserStatus: BrowserStatus = .off
    /// Why turning the browser switch on failed, shown under it; nil when it didn't.
    private var browserError: String?
    /// How the last Settings › Copy diagnostics went.
    private var diagnosticsStatus: DiagnosticsCopy.Status = .idle
    /// Whether the system refused the last "Open at login" change, and how the last "Move to the Keychain" went.
    private var loginItemFailed = false
    private var keyMoveNote: String?

    /// `~/.benji/jobs` (or under `BENJI_WORKDIR`): where the engine keeps jobs and their schedules.
    static var jobsFolder: URL { WorkingFolder.url().appendingPathComponent("jobs") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ScreenCapturer.removeLeftovers()
        model.onApprovalNeeded = { [weak self] _ in self?.panel.presentApproval() }
        // The display the user is working on, never all of them: the one the message was started on,
        // latched when it was sent (CompanionModel.send); a disconnected one is refused, never swapped.
        model.captureScreen = { [weak self] completion in
            guard let self else { return completion(.failure(ScreenCaptureError.noDisplay)) }
            CaptureRouting.route(target: self.model.captureTarget, displays: DisplayInventory.current(),
                                 pointer: NSEvent.mouseLocation, fallback: self.panel.hostDisplayID,
                                 capture: { id, done in
                guard let screen = DisplayInventory.screen(id) else { return done(.failure(ScreenCaptureError.noDisplay)) }
                self.capturer.capture(screen: screen, completion: done)
            }, completion: completion)
        }
        model.onPoint = { [weak self] plan in self?.point(plan) }
        // What Benji has on the screen goes with each message, and while a
        // picture is up Benji's own screenshot keeps it in.
        ServeBackend.canvasNow = { [weak self] in self?.canvasSnapshot() }
        // What this app can carry out is said in `hello`; the keys come from the Keychain once the
        // user has moved them (and the engine is not started if it can't be read); cues, the muted-output
        // check and the quiet check are asked at the moment they matter, never at launch.
        let quiet = QuietServices.shared
        ServeBackend.capabilities = {
            AppCapabilities.list(screenActions: true,
                                 drive: DriveCopy.isOn(UserDefaults.standard.object(forKey: DriveCopy.defaultsKey)))
        }
        ServeBackend.keyEnvironment = { quiet.keyEnvironment() }
        permissionSetup.configureModel(store: quiet.keyStore, defaults: .standard,
            backend: ModelSetupEngine(assistantDir: AppConfig.assistantDir, environment: { quiet.keyEnvironment() })) { [weak self] in
                self?.engineRestartPending = true
                self?.keyMoveNote = nil
                self?.model.settings.refresh()
                self?.fetchProvider()
            }
        pointerCompanion.attach(to: model)
        quiet.benjiSpeaking = { [weak self] in self?.model.state.phase == .speaking }
        model.onJobCue = { cue in quiet.jobCue(cue) }
        model.quietNow = { quiet.quietReason() }
        model.outputState = { SystemAudio.outputState() }
        if let line = quiet.grantChangeLine() { model.showNote(line) }
        ScreenCapturer.keepIn = { [weak self] in
            (self?.pointer.windowsInCaptures ?? []).union(FigureStage.isOn ? FigureStage.shared.windowsInCaptures : [])
        }
        pointer.avoid = { [weak self] in self.map { [$0.panel.frame] } ?? [] }
        pointer.onReveal = { [weak self] keepOut in
            // The screenshot left the panel out, so the user must see what the model saw.
            guard let self, self.panel.isVisible, self.panel.frame.intersects(keepOut) else { return }
            self.model.setExpanded(false, byBenji: true)   // listening carries on in the peek
        }
        model.onHidePointer = { [weak self] in self?.pointer.hide() }
        prepareScreenActions()
        if FigureStage.isOn { prepareFigureStage() }   // 3D figures, on by default
        if ExplainCardStage.isOn { prepareExplainCards() }   // explanation cards, on by default
        // Before each message: "Draw things in 3D" wraps or unwraps the backend, and a new model
        // choice restarts a kept engine so it starts with the new BENJI_MODEL.
        model.backendForNextRun = { [weak self] backend in
            let next = FigureStageBackend.matching(backend)
            guard let self else { return next }
            if self.applyModelChoice() || self.engineRestartPending {
                self.engineRestartPending = false
                next.restartEngine()
            }
            return next
        }
        _ = applyModelChoice()   // before the engine first starts, and before --print-provider
        ServeBackend.browserStatus = { [weak self] status in
            self?.browserStatus = status
            self?.model.settings.refresh()
        }
        ServeBackend.browserAlwaysKept = { [weak self] kept in
            // The engine is the judge of what is a site: keep what it kept, so the list shows what is in force.
            let defaults = UserDefaults.standard
            let mine = BrowserAlways.decode(defaults.object(forKey: BrowserAlways.defaultsKey))
            let now = mine.filter { kept.contains($0) }
            if now != mine { defaults.set(now, forKey: BrowserAlways.defaultsKey) }
            self?.model.settings.refresh()
        }
        model.settings.load = { [weak self] in self?.settingsSnapshot() ?? SettingsSnapshot() }
        model.settings.apply = { [weak self] in self?.applySetting($0) }
        fetchProvider()
        // A repeating job runs only while Benji is open: if a schedule exists, the engine is
        // brought up now, so a due run can happen while the app sits idle. With no schedule the
        // engine waits for the first message.
        let launchDefaults = UserDefaults.standard
        if JobsSetting.isOn(launchDefaults.object(forKey: JobsSetting.defaultsKey)),
           JobSchedulesSetting.isOn(launchDefaults.object(forKey: JobSchedulesSetting.defaultsKey)),
           JobSchedulesSetting.existsOnDisk(jobsFolder: Self.jobsFolder) {
            DispatchQueue.main.async { [weak self] in self?.model.startEngineForSchedules() }
        }

        let kind = TranscriberKind.from(setting: UserDefaults.standard.string(forKey: "pttTranscriber"))
        voice = VoiceController(model: model, assistantDir: AppConfig.assistantDir, transcriber: kind)
        model.onSpeak = { [weak self] text in self?.voice.speak(text) }
        // A streamed answer is spoken sentence by sentence as it arrives.
        model.onSpeakSentence = { [weak self] sentence in self?.voice.speakSentence(sentence) }
        model.onSpeakStreamEnd = { [weak self] rest in self?.voice.endSpeechStream(rest) }
        model.onLatency = { LatencyLog.record($0) }
        model.onStep = { VoiceLogFile.shared.append($0) }
        // Logs main-thread stalls over 250 ms to voice.log; a developer's tool, so only with BENJI_DEBUG=1.
        if ProcessInfo.processInfo.environment["BENJI_DEBUG"] == "1" { MainThreadWatch.shared.start() }
        voice.onSpeechProgress = { [weak self] progress in
            self?.pointer.speech(progress)
            if case .ended = progress, ExplainCardStage.isOn { ExplainCardStage.shared.speechEnded() }
        }
        // The clock for the explanation card's parts and for the overlay's marks between sentences:
        // when each word is heard.
        voice.onSpokenWords = { [weak self] spoken, marks in
            if ExplainCardStage.isOn { ExplainCardStage.shared.heard(spoken: spoken, marks: marks) }
            self?.pointer.heard(spoken: spoken, marks: marks)
        }
        model.onCancel = { [weak self] in self?.voice.cancelAll() }
        model.onStopSpeaking = { [weak self] in self?.voice.stopSpeaking() }

        model.onMicToggle = { [weak self] in self?.voice.toggle() }
        model.onDropHeardWords = { [weak self] in self?.voice.dropHeardWords() }
        model.onConversationToggle = { [weak self] in
            self?.model.voiceStartedInPanel()
            self?.voice.toggleHandsFree()
        }
        model.onTypedWhileListening = { [weak self] in self?.voice.typedMessageWhileListening() }
        model.onExpandedChange = { [weak self] open, byBenji in
            self?.voice.panelOpenChanged(open, keepListening: byBenji)
        }
        model.listenWhileOpenChanged(voice.listenWhileOpen)
        model.onListenWhileOpenChange = { [weak self] on in self?.setListenWhileOpen(on) }
        handsFreeWatcher.onEnd = { [weak self] reason in self?.voice.endHandsFree(reason) }
        handsFreeWatcher.escapeBelongsToCard = { [weak self] in
            guard let self else { return false }
            return self.model.state.pendingApproval != nil || self.model.pendingScreenSend != nil
        }
        voice.onHandsFreeChange = { [weak self] on in
            if on { self?.handsFreeWatcher.start() } else { self?.handsFreeWatcher.stop() }
        }
        if ProcessInfo.processInfo.environment["BENJI_DEBUG"] == "1" {
            FileHandle.standardError.write(Data(
                "[ptt] transcriber=\(kind.rawValue)\n".utf8))
            FileHandle.standardError.write(Data(
                "[screen] recordingPermission=\(CGPreflightScreenCaptureAccess())\n".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                FileHandle.standardError.write(Data(
                    "[screen] provider=\(self?.model.providerID ?? "nil") mode=\(self?.model.screenMode.mode.rawValue ?? "")\n".utf8))
            }
        }
        if ModifierTalkKey.isEnabled {
            talkKey.onTap = { [weak self] in self?.talkKeyTapped() }
            talkKey.onHoldBegan = { [weak self] in self?.talkPressed() }
            talkKey.onHoldEnded = { [weak self] in self?.talkReleased() }
            talkKey.start { [weak self] ready in
                guard let self else { return }
                self.talkKeyReady = ready
                self.updateTalkHint()
                self.model.settings.refresh()
                if ProcessInfo.processInfo.environment["BENJI_DEBUG"] == "1" {
                    FileHandle.standardError.write(Data("[talkKey] ready=\(ready)\n".utf8))
                }
            }
        }
        updateTalkHint()

        panel = CompanionPanel(model: model)
        // What is typed is about the display the panel is on.
        panel.onHostChanged = { [weak self] display in
            self?.model.panelDisplay = CaptureDisplay.target(id: display, among: DisplayInventory.current())
        }
        model.panelDisplay = CaptureDisplay.target(id: panel.hostDisplayID, among: DisplayInventory.current())
        model.onOpenForTyping = { [weak self] in self?.panel.openForTyping() }
        appOffers = AppOfferWatcher(model: model, pointerOnNotch: { [weak self] in self?.panel.presenter.isPointerOver ?? false })
        appOffers?.start()

        buildStatusItem()
        showPanel()   // closed: it is the notch until hovered or a real event
        permissionSetup.openOnLaunchIfNeeded()
    }

    /// The talk key went down over this display: what is said now is about it.
    private func engagePointerDisplay() {
        let displays = DisplayInventory.current()
        model.voiceEngaged(on: CaptureDisplay.target(id: CaptureDisplay.display(at: NSEvent.mouseLocation, in: displays)?.id,
                                                     among: displays))
    }

    /// Right ⌥ held: listen until let go (`VoiceController.pressed`).
    private func talkPressed() {
        engagePointerDisplay()
        pointer.hide()
        if !panel.isVisible { showPanel() }
        model.latencyKeyDown()
        model.prewarm()     // start the engine if it isn't up, and warm its provider connection
        voice.pressed()
    }

    /// Right ⌥ let go after a hold: a hold sends; a short one counts as a tap.
    private func talkReleased() {
        model.latencyKeyUp()
        voice.released()
        // A tap started a conversation: it lives in the open panel.
        if voice.isHandsFreeOn && !model.expanded { model.setExpanded(true, preservingVoiceDisplay: true) }
    }

    /// Right ⌥ tapped: interrupt speech, or open the panel and listen, or (open) what the mic does.
    private func talkKeyTapped() {
        engagePointerDisplay()
        pointer.hide()
        if !panel.isVisible { showPanel() }
        model.prewarm()
        let speaking = model.state.phase == .speaking
        if speaking || voice.isHandsFreeOn || model.expanded {
            voice.toggle()
            return
        }
        model.setExpanded(true, preservingVoiceDisplay: true)   // the talk-key display also applies to automatic listening
        if !voice.isHandsFreeOn { voice.toggle() }
    }

    private func setListenWhileOpen(_ on: Bool) {
        if on { model.voiceStartedInPanel() }
        voice.setListenWhileOpen(on)
        model.listenWhileOpenChanged(on)
        model.settings.refresh()
    }

    private func updateTalkHint() {
        // Right ⌥ is the only talk key. Ready: the capsule and the hint name it. Not ready
        // (no Accessibility): they say why and point to Finish Setup, never to another key.
        model.talkKeyName = talkKeyReady ? talkKey.displayString : nil   // the composer's talk capsule names it
        model.talkKeyNeedsSetup = !talkKeyReady && ModifierTalkKey.isEnabled ? talkKey.displayString : nil
        let startsOnTap = voice.handsFreeAvailable && voice.handsFreeSettings.startsOnTap
        model.talkStartsOnTap = startsOnTap
        model.pttHint = ComposerTalk.hint(key: talkKey.displayString, ready: talkKeyReady,
                                          enabled: ModifierTalkKey.isEnabled, startsOnTap: startsOnTap)
    }

    // MARK: menu-bar command

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // The two elbows, and the halves closed while Benji is busy, copied into the
            // bundle by build.sh. A bare `swift run` has no bundle resources, so fall back to an
            // SF Symbol there.
            for glyph in [StatusGlyph.idle, .working] {
                let image = Bundle.main.url(forResource: glyph.resourceName, withExtension: "svg")
                    .flatMap { NSImage(contentsOf: $0) }
                    ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
                guard let img = image else { continue }
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = true
                img.accessibilityDescription = "Benji"
                statusGlyphs[glyph] = img
            }
            if let img = statusGlyphs[.idle] {
                button.image = img
            } else {
                button.title = "Benji"
            }
            // A plain image swap on a real phase change: no animation, still template images.
            statusGlyphSub = model.$state
                .map { StatusGlyph.glyph(for: $0.phase) }
                .removeDuplicates()
                .sink { [weak self] glyph in
                    guard let self, let img = self.statusGlyphs[glyph] else { return }
                    self.statusItem.button?.image = img
                }
        }
        buildMenu()
    }

    /// The menu-bar item's menu: a few commands; every switch and choice is on the settings page.
    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        fillMenu(menu)
        statusItem.menu = menu
    }

    /// "Finish Setup…" comes and goes with the permissions, so the items are made each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) { fillMenu(menu) }

    private func fillMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let setupComplete = CompanionPermission.allCases.allSatisfy { Permissions.isGranted($0) }
        for item in StatusMenuItem.menu(setupComplete: setupComplete) {
            if item == .separator { menu.addItem(.separator()); continue }
            let action: Selector
            switch item {
            case .showHide: action = #selector(togglePanel)
            case .settings: action = #selector(showSettings)
            case .finishSetup: action = #selector(showPermissionSetup)
            case .quit: action = #selector(NSApplication.terminate(_:))
            case .separator: continue
            }
            let menuItem = NSMenuItem(title: item.title, action: action, keyEquivalent: item.keyEquivalent)
            if item != .quit { menuItem.target = self }
            menu.addItem(menuItem)
        }
    }

    @objc private func showPermissionSetup() { permissionSetup.show() }

    /// Opens the panel on its settings page.
    @objc private func showSettings() {
        pointer.hide()
        if !panel.isVisible { showPanel() }
        model.openSettings()
    }

    @objc private func togglePanel() {
        // Closing it ends the conversation unless "keep listening when the panel closes" is on.
        if panel.presenter.size == .open, voice.endsConversationOnMenuClose { voice.endHandsFree(.panelClosed) }
        // Opened from a display's own menu bar: Benji opens on that display.
        panel.toggleOpen(onDisplay: statusItem.button?.window?.screen.flatMap(DisplayInventory.id(of:)))
    }

    // MARK: settings page

    private func settingsSnapshot() -> SettingsSnapshot {
        let defaults = UserDefaults.standard
        var s = SettingsSnapshot()
        s.figures = FigureSetting.isOn(from: defaults.object(forKey: FigureSetting.defaultsKey))
        s.drawingsInScreenshots = DrawingCapture.shown(from: defaults.object(forKey: DrawingCapture.defaultsKey))
        s.pointerCompanion = PointerCompanion.isOn(from: defaults.object(forKey: PointerCompanion.defaultsKey))
        s.readAloud = model.readAloud
        s.handsFreeAvailable = voice.handsFreeAvailable
        s.listenWhileOpen = voice.listenWhileOpen
        s.keepListeningWhenClosed = voice.keepListeningWhenClosed
        s.holdBack = OtherAppAudioGuard.isOn(from: defaults.object(forKey: OtherAppAudioGuard.defaultsKey))
        s.bargeIn = BargeInMode.from(defaults.object(forKey: BargeInMode.defaultsKey))
        let echoKey = EchoVerdicts.key(route: SystemAudio.bargeInRoute(), input: SystemAudio.defaultInputName())
        s.echoUnavailable = SystemAudio.bargeInRoute() != .headphones
            && EchoVerdicts(stored: defaults.object(forKey: EchoVerdicts.defaultsKey))
                .isKnownBad(echoKey, now: Date().timeIntervalSince1970)
        s.model = ModelChoice.from(defaults.object(forKey: ModelChoice.defaultsKey))
        s.modelApplies = ModelChoice.applies(provider: engineProvider)
        s.modelInUse = engineModelInUse ?? ""
        s.modelDestination = engineDestination
        s.screenUnavailable = model.visionUnavailable
        s.idleTimeout = voice.handsFreeSettings.idleTimeout
        s.idleTimeoutChoices = HandsFreeSettings.idleTimeoutChoices
        s.transcription = voice.transcriberDescription
        s.voice = voice.voiceDescription
        s.voiceStatus = voice.voicePickerStatus
        s.voiceChoices = voice.kokoroVoiceChoices
        s.voiceChosen = voice.kokoroVoiceChosen
        s.voiceSpeed = KokoroSpeed.nearest(defaults.object(forKey: "kokoroSpeed") as? Double)
        s.voiceNote = voicePreviewNote
        s.screenSimpleSteps = ScreenAutonomy.actsOnSimpleSteps(defaults.object(forKey: ScreenAutonomy.defaultsKey))
        s.schedulesOn = JobSchedulesSetting.isOn(defaults.object(forKey: JobSchedulesSetting.defaultsKey))
        s.browserOn = BrowserSetting.isOn(defaults.object(forKey: BrowserSetting.defaultsKey))
        s.browserStatus = s.browserOn ? browserStatus : .off
        s.browserError = browserError
        let home = FileManager.default.homeDirectoryForCurrentUser
        let on = Set(BrowserHostRegistration.registered(home: home, assistantDir: AppConfig.assistantDir).map(\.id))
        s.browsers = ChromiumBrowser.installed(home: home).map { BrowserRow(browser: $0, registered: on.contains($0.id)) }
        s.browserAlways = BrowserAlways.decode(defaults.object(forKey: BrowserAlways.defaultsKey))
        s.diagnostics = diagnosticsStatus
        let quiet = QuietServices.shared
        s.openAtLogin = OpenAtLogin.isOn(quiet.loginItem.status)
        s.openAtLoginCaption = OpenAtLogin.caption(quiet.loginItem.status, failed: loginItemFailed)
        s.keyStorage = quiet.keyStatus()
        s.keyMoveNote = keyMoveNote
        s.cuesOn = CueSettings.isOn(defaults.object(forKey: CueSettings.defaultsKey))
        s.appOffersOn = AppOfferSettings.isOn(defaults.object(forKey: AppOfferSettings.defaultsKey))
        s.appOffersDeclined = AppOfferRecord.decode(defaults.object(forKey: AppOfferRecord.defaultsKey)).declinedNames
        for mode in ScreenMode.allCases {
            s.screenCaptions[mode] = ScreenCapturePolicy.modeCaption(mode, provider: model.providerID)
        }
        s.screenMode = model.screenModeInForce
        s.talkKey = ModifierTalkKey.isEnabled
            ? (talkKeyReady ? talkKey.displayString : "\(talkKey.displayString) (needs Accessibility)") : nil
        s.permissions = CompanionPermission.allCases.map { .init(permission: $0, granted: Permissions.isGranted($0)) }
        let info = Bundle.main.infoDictionary
        if let version = info?["CFBundleShortVersionString"] as? String {
            s.version = "Benji \(version)" + ((info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? "")
        }
        s.saveConversations = model.history.saving
        s.savedConversations = model.history.summaries.count
        s.facts = ProfileMemory.facts(in: ProfileMemory.read(profileURL))
        return s
    }

    /// Applies one change from the settings page, and says when it takes effect.
    private func applySetting(_ change: SettingsChange) {
        let defaults = UserDefaults.standard
        switch change {
        case .figures(let on):
            // Applies from the next message: the model asks `FigureStageBackend.matching` for its backend.
            defaults.set(on, forKey: FigureSetting.defaultsKey)
            if on { prepareFigureStage() } else { FigureStage.shared.dismiss() }
            model.showNote(FigureSetting.notice(on: on))
        case .pointerCompanion(let on):
            defaults.set(on, forKey: PointerCompanion.defaultsKey)
            pointerCompanion.refresh()
        case .drawingsInScreenshots(let on):
            defaults.set(on, forKey: DrawingCapture.defaultsKey)   // applies from the next drawing
            if FigureStage.isOn { FigureStage.shared.refreshCaptureSharing() }   // and to a figure card that is up
        case .readAloud(let on):
            model.setReadAloud(on)
        case .listenWhileOpen(let on):
            setListenWhileOpen(on)
        case .holdBack(let on):
            defaults.set(on, forKey: OtherAppAudioGuard.defaultsKey)
        case .model(let choice):
            defaults.set(choice.rawValue, forKey: ModelChoice.defaultsKey)
            if applyModelChoice() { engineRestartPending = true }   // a kept engine restarts at the next message
            model.showNote(choice.notice)
            fetchProvider()   // the model in use, as the engine now resolves it
        case .bargeIn(let mode):
            defaults.set(mode.rawValue, forKey: BargeInMode.defaultsKey)   // read at each answer and tick
            // Choosing Always is asking to try it again: forget where echo cancelling failed.
            if mode == .always { defaults.removeObject(forKey: EchoVerdicts.defaultsKey) }
        case .idleTimeout(let seconds):
            voice.setIdleTimeout(seconds)
        case .screenSimpleSteps(let on):
            // Read at each message (the engine) and each step (the app), so it applies at once.
            defaults.set(!on, forKey: ScreenAutonomy.defaultsKey)
        case .browser(let on):
            setBrowser(on)
        case .browserUse(let id, let on):
            setBrowserUse(id, on)
        case .browserAlwaysAdd(let text):
            let list = BrowserAlways.decode(defaults.object(forKey: BrowserAlways.defaultsKey))
            if let next = BrowserAlways.adding(text, to: list) {
                defaults.set(next, forKey: BrowserAlways.defaultsKey)
                model.setBrowserAlways(next)
            }
        case .browserAlwaysRemove(let origin):
            let next = BrowserAlways.decode(defaults.object(forKey: BrowserAlways.defaultsKey)).filter { $0 != origin }
            defaults.set(next, forKey: BrowserAlways.defaultsKey)
            model.setBrowserAlways(next)
        case .schedules(let on):
            defaults.set(on, forKey: JobSchedulesSetting.defaultsKey)
            model.setSchedules(on)          // a running engine hears it now; a later one in `ready`
        case .copyDiagnostics:
            copyDiagnostics()
        case .showBenjiFolder:
            NSWorkspace.shared.open(WorkingFolder.url())      // the folder itself: it is hidden, so it is opened, not selected
        case .openAtLogin(let on):
            // The only place that registers or removes the login item: never at launch.
            loginItemFailed = OpenAtLogin.set(on, service: QuietServices.shared.loginItem).failed
            model.settings.refresh()
        case .moveKeysToKeychain:
            // An explicit Settings press: the same move to the Keychain as the setup window's Save.
            let outcome = QuietServices.shared.moveKeysToKeychain()
            keyMoveNote = outcome.words
            if case .moved = outcome { engineRestartPending = true }   // the helper restarts with the keys from the Keychain
            model.settings.refresh()
        case .cues(let on):
            defaults.set(on, forKey: CueSettings.defaultsKey)   // read when each job changes state
        case .appOffers(let on):
            defaults.set(on, forKey: AppOfferSettings.defaultsKey)
            appOffers?.switchChanged()
        case .resetAppOffers:
            appOffers?.resetAnswers()
            model.settings.refresh()
        case .showBrowserExtension:
            let folder = URL(fileURLWithPath: AppConfig.assistantDir).appendingPathComponent(BrowserExtension.folderName)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        case .screenMode(let mode):
            model.setScreenMode(mode)
        case .downloadVoices:
            openSpokenContentSettings()
        case .kokoroVoice(let id):
            // Read when each answer starts: the next answer speaks in it, one playing now finishes as it began.
            defaults.set(KokoroSettings.voice(id), forKey: "kokoroVoice")
            voicePreviewNote = nil
        case .kokoroSpeed(let speed):
            defaults.set(KokoroSettings.speed(speed), forKey: "kokoroSpeed")   // likewise from the next answer
        case .previewVoice(let id):
            voicePreviewNote = voice.previewVoice(id)?.note
        case .requestPermission(let permission):
            Permissions.request(permission) { [weak self] in self?.model.settings.refresh() }
        case .openPermissionSetup:
            permissionSetup.show()
        case .keepListeningWhenClosed(let on):
            voice.setKeepListeningWhenClosed(on)
        case .saveConversations(let on):
            model.history.setSaving(on)
        case .deleteAllConversations:
            model.deleteAllConversations()
        case .forgetFact(let fact):
            rewriteProfile { ProfileMemory.removing(fact, from: $0) }
        case .editFact(let fact, let text):
            rewriteProfile { ProfileMemory.replacing(fact, with: text, in: $0) }
        case .forgetAllFacts:
            rewriteProfile { _ in "" }
        }
    }

    /// Changes the remembered facts as the page asked, read fresh so a line the engine added a
    /// moment ago is kept; a fact that changed underneath is left as it is. Applies from the next
    /// message (the engine reads the file each turn).
    private func rewriteProfile(_ change: (String) -> String?) {
        guard let updated = change(ProfileMemory.read(profileURL)) else {
            model.showNote("That memory changed meanwhile; nothing was edited.")
            return
        }
        do { try ProfileMemory.write(updated, to: profileURL) } catch {
            model.showNote("Couldn't change what Benji remembers: \(error.localizedDescription)")
        }
    }

    /// Sets or clears `BENJI_MODEL` in this app's environment (which every engine process
    /// inherits) for the stored choice. True when it changed. Never touches `~/.benji.env`.
    @discardableResult
    private func applyModelChoice() -> Bool {
        let stored = ModelChoice.from(UserDefaults.standard.object(forKey: ModelChoice.defaultsKey))
        let choice = ModelChoice.applies(provider: engineProvider) ? stored : .haiku
        let current = ProcessInfo.processInfo.environment[ModelChoice.engineVariable]
        switch choice.environmentChange(current: current, setByApp: modelSetByApp) {
        case .set(let name):
            setenv(ModelChoice.engineVariable, name, 1)
            modelSetByApp = name
            return true
        case .clear:
            unsetenv(ModelChoice.engineVariable)
            modelSetByApp = nil
            return true
        case nil:
            return false
        }
    }

    /// Settings › Browser. The master switch opens the engine's link and writes nothing
    /// into any browser; turning it off removes every browser's manifest and the launcher. Each browser is
    /// its own opt-in (`setBrowserUse`), the only thing that writes a native-messaging manifest.
    private func setBrowser(_ on: Bool) {
        let defaults = UserDefaults.standard
        browserError = nil
        if !on {
            BrowserHostRegistration.unregisterAll(home: FileManager.default.homeDirectoryForCurrentUser,
                                                  assistantDir: AppConfig.assistantDir)
            browserStatus = .off
        }
        defaults.set(on, forKey: BrowserSetting.defaultsKey)
        AuditFile.shared.record(.browserSwitch(enabled: on))
        model.setBrowser(on)
        if on { model.setBrowserAlways(BrowserAlways.decode(defaults.object(forKey: BrowserAlways.defaultsKey))) }
        model.settings.refresh()
    }

    /// One browser's switch: writes or removes that browser's manifest (and the shared launcher), only
    /// while the master switch is on. A failure leaves that browser off with the reason shown.
    private func setBrowserUse(_ id: String, _ on: Bool) {
        guard let browser = ChromiumBrowser.named(id),
              BrowserSetting.isOn(UserDefaults.standard.object(forKey: BrowserSetting.defaultsKey)) else { return }
        let registration = BrowserHostRegistration(home: FileManager.default.homeDirectoryForCurrentUser,
                                                   assistantDir: AppConfig.assistantDir, browser: browser)
        browserError = nil
        if on {
            do {
                try registration.register()
            } catch {
                registration.unregister()
                browserError = "Benji couldn't set up \(browser.name)'s connection. Nothing was changed."
            }
        } else {
            registration.unregister()
        }
        model.settings.refresh()
    }

    /// Settings › Diagnostics: run `benji --diagnose` off the main thread, put its report
    /// on the clipboard, and say how it went. The report holds no message text; the audit log only
    /// records that it was copied.
    private func copyDiagnostics() {
        guard diagnosticsStatus != .working else { return }
        diagnosticsStatus = .working
        model.settings.refresh()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = DiagnosticsCopy.perform(run: Self.runDiagnose, copy: { text in
                DispatchQueue.main.sync {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }, audit: { AuditFile.shared.record($0) })
            DispatchQueue.main.async {
                self?.diagnosticsStatus = status
                self?.model.settings.refresh()
            }
        }
    }

    private static func runDiagnose() -> (output: Data?, exitCode: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "cd \"$BENJI_DIR\" && exec python3 -m benji \(DiagnosticsCopy.command)"]
        var env = ProcessInfo.processInfo.environment
        env["BENJI_DIR"] = AppConfig.assistantDir
        env["BENJI_WORKDIR"] = WorkingFolder.url().path
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return (nil, -1) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (data, p.terminationStatus)
    }

    /// Clicking, scrolling and typing on the screen: the actuator rings the target with
    /// the pointer overlay, takes fresh screenshots with the same capturer, and moves the panel
    /// out of the way when it covers the target or holds the keyboard.
    private func prepareScreenActions() {
        actuator.showTarget = { [weak self] plan in self?.pointer.show(plan) }
        actuator.hideTarget = { [weak self] in self?.pointer.dismiss() }
        actuator.makeWay = { [weak self] in
            guard let self else { return }
            self.pointer.dismiss()
            self.model.setExpanded(false, byBenji: true)
            self.panel.giveBackKeyboard()
        }
        actuator.benjiHasKeyboard = { [weak self] in self?.panel.isKeyWindow == true }
        actuator.capture = { [weak self] screen, done in self?.capturer.capture(screen: screen, completion: done) }
        actuator.sample = { [weak self] id, done in
            guard let self else { return done(nil) }
            self.capturer.sample(displayID: id, completion: done)
        }
        model.describeScreenStep = { [weak self] step, shot in self?.actuator.describe(step, on: shot) }
        model.describeScreenStepEnd = { [weak self] step, shot in self?.actuator.describeEnd(step, on: shot) }
        model.performScreenStep = { [weak self] step, shot, pid, endPID, done in
            self?.actuator.perform(step, on: shot, approvedPID: pid, approvedEndPID: endPID, done: done)
        }
        model.cancelScreenStep = { [weak self] in self?.actuator.cancel() }
        // Simple steps without a card: the same actuator, with the step's class.
        model.performSimpleScreenStep = { [weak self] step, shot, mode, done in
            self?.actuator.perform(step, on: shot, approvedPID: nil, mode: mode, done: done)
        }
        // Drive mode: the same actuator under the drive's rules, held while the user's mouse
        // moves; one monitor watches the user's own input and tells the model.
        actuator.driveHold = { [weak self] in self?.model.drivePaused == true }
        model.performDriveStep = { [weak self] step, shot, pid, endPID, cls, done in
            self?.actuator.performDrive(step, on: shot, approvedPID: pid, approvedEndPID: endPID, cls: cls, done: done)
        }
        model.handBackDriveStep = { [weak self] in self?.actuator.handBack() }
        driveMonitor.onInput = { [weak self] input, now in self?.model.driveInput(input, at: now) }
        model.watchDrive = { [weak self] on in self?.driveMonitor.watch(on) }
        model.watchScreenTurn = { [weak self] on in
            self?.actuator.watchTurn(on) { [weak self] in self?.model.screenTurnEscape() }
        }
        // Esc during a background job's beat cancels it before it starts.
        model.watchJobBeat = { [weak self] on in
            self?.actuator.watchJobBeat(on) { [weak self] in self?.model.jobEscape() }
        }
    }

    private func prepareExplainCards() {
        let stage = ExplainCardStage.shared
        stage.screen = { [weak self] in self?.panel.screen ?? NSScreen.main }
        // Benji's panel first: the card's preferred spot is just under it.
        stage.avoid = { [weak self] in
            guard let self else { return [] }
            return [self.panel.frame] + (FigureStage.isOn ? [FigureStage.shared.frame].compactMap { $0 } : [])
        }
        stage.onChip = { [weak self] text in self?.model.ask(text) }
        // Each part is drawn on its sentence: the voice's word marks are the card's clock.
        model.onTurnStarts = { speaks in stage.turnStarts(speaks: speaks) }
    }

    /// A picture is placed once the turn's screenshot is measured for busy space (off the main
    /// thread): on busy content it goes on a board. Anything else shows at once.
    private func point(_ plan: PointingPlan) {
        guard plan.isDrawing, !plan.extendsDrawing, let url = model.currentScreenshotURL,
              let data = try? Data(contentsOf: url),
              let screen = NSScreen.screens.first(where: { $0.frame == plan.screenFrame }) else { return pointer.show(plan) }
        pointGeneration += 1
        let generation = pointGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let busy = ExplainBusyScreen.measure(data: data, screen: screen)
            DispatchQueue.main.async {
                guard let self, generation == self.pointGeneration else { return }
                self.pointer.show(plan, busy: busy)
            }
        }
    }

    /// What Benji has on the screen now, in the pixels of the screenshot going with this message.
    private func canvasSnapshot() -> CanvasSnapshot? {
        var c = CanvasSnapshot()
        let shot = model.currentScreenshotGeometry
        let drawn = pointer.canvas(screenFrame: shot?.screenFrame, pixelSize: shot?.pixelSize)
        c.parts = drawn.parts
        c.board = drawn.board
        if let figure = FigureStage.shared.shownFigure {
            c.figureTitle = figure.title
            c.figureParts = figure.parts.map(\.name).filter { !$0.isEmpty }
            c.figureLabels = figure.labels.map(\.text)
        }
        if ExplainCardStage.isOn, let card = ExplainCardStage.shared.shownCard {
            c.cardTitle = card.title
            c.cardItems = card.items
        }
        return c.isEmpty ? nil : c
    }

    private func prepareFigureStage() {
        FigureStage.shared.screen = { [weak self] in self?.panel.screen ?? NSScreen.main }
        FigureStage.shared.avoid = { [weak self] in self.map { [$0.panel.frame] } ?? [] }
    }

    /// Accessibility › Spoken Content, where System Voice › Manage Voices downloads
    /// Enhanced/Premium voices. Benji picks the best installed one automatically.
    private func openSpokenContentSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpeakableItems") {
            NSWorkspace.shared.open(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        voice.endHandsFree(.panelClosed)
        model.shutdown()
        model.history.flush()   // the last answer's save lands before the app goes
        ScreenCapturer.removeLeftovers()
    }

    /// Ask the engine which provider it's configured for (no API call), so the screen
    /// disclosure names the real destination instead of guessing.
    private func fetchProvider() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "cd \"$BENJI_DIR\" && exec python3 -m benji --print-provider"]
        var env = ProcessInfo.processInfo.environment
        env["BENJI_DIR"] = AppConfig.assistantDir
        switch QuietServices.shared.keyEnvironment() {
        case let .success(keys): env.merge(keys) { _, new in new }
        case .failure: return
        }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.terminationHandler = { [weak self] _ in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            // "destination": the company, or a custom server's host.
            let id = obj?["destination"] as? String
            let provider = obj?["provider"] as? String, inUse = obj?["model"] as? String
            // Who receives data, with the host, and whether the model can read images.
            let host = obj?["host"] as? String
            let noVision = (obj?["images"] as? Bool) == false ? (inUse ?? "this model") : nil
            DispatchQueue.main.async {
                self?.model.providerID = id
                self?.model.visionUnavailable = noVision
                self?.engineDestination = [id, host.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
                self?.engineProvider = provider
                self?.engineModelInUse = inUse
                self?.model.settings.refresh()
            }
        }
        try? p.run()
    }

    private func showPanel() {
        panel.show()   // visible but not key: no focus steal while idle
        if ProcessInfo.processInfo.environment["BENJI_DEBUG_EXPANDED"] == "1" {
            model.setExpanded(true)
        }
    }
}
