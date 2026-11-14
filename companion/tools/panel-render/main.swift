// Renders the notch panel offscreen in every state, driven through the real model from a fake
// backend: no engine, no microphone, no screen capture, no permission prompts. Each panel is
// drawn by an offscreen window (cacheDisplay), because ImageRenderer leaves AppKit-backed views
// (the transcript's ScrollView, the composer's TextField) blank; ImageRenderer lays out the
// contact sheets. The status-word swap is captured as frames while its animation runs.
// Build and run with tools/panel-render/render.sh <output dir>.
import AppKit
import BenjiCore
import SwiftUI

final class FakeBackend: CompanionBackend, JobBackend {
    var onEvent: ((_ run: Int, BackendEvent) -> Void)?
    var onFinished: ((_ run: Int, Int32) -> Void)?
    let approvalTimeout: TimeInterval = 60
    private var run = 0
    func start(run: Int, task: String, imagePath: String?, memory: ConversationMemory, allowPointing: Bool,
               spoken: Bool, screen: ScreenshotGeometry?) { self.run = run }
    /// The engine's side, for the run the model started last.
    func say(_ event: BackendEvent) { onEvent?(run, event) }
    func finish(_ code: Int32) { onFinished?(run, code) }
    func resolveApproval(_ approved: Bool) {}
    // Background jobs (D-130 step 1): the engine's side is `job`; nothing is asked of a fake engine.
    var onJob: ((JobSnapshot) -> Void)?
    var onEngineExit: (() -> Void)?
    func job(_ snapshot: JobSnapshot) { onJob?(snapshot) }
    func answerJob(_ job: String, request: String, approved: Bool) {}
    func stopJob(_ job: String) {}
    func steerJob(_ job: String, text: String) {}
    func dismissJob(_ job: String) {}
    func cancel() {}
    func reset() {}
    func shutdown() {}
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
// A throwaway defaults domain, so the renders never touch Benji's own settings.
let defaultsSuite = "benji-panel-render"
let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
let notch = CGRect(x: 661, y: 982 - 32, width: 190, height: 32)

/// A desktop behind the panel, light or dark, so the shadow and the edges read as on a Mac.
struct Backdrop: View {
    let dark: Bool
    var body: some View {
        LinearGradient(colors: dark ? [Color(white: 0.16), Color(red: 0.12, green: 0.14, blue: 0.22)]
                                    : [Color(red: 0.80, green: 0.86, blue: 0.95), Color(red: 0.95, green: 0.88, blue: 0.90)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct Scene {
    let name: String
    let caption: String
    var dark = false
    var reduceMotion = false
    var doneHolding = false
    var size: NotchSize = .open
    /// The hardware notch's width (the usual MacBook one unless a scene tries a wider one).
    var notchWidth: CGFloat = 190
    /// Saved conversations (title, hours ago), in a throwaway folder; none: no store at all.
    var saved: [(String, Double)] = []
    /// The panel at its expanded size with the sidebar (D-133).
    var expanded = false
    let setUp: (CompanionModel, FakeBackend) -> Void
}

/// A throwaway folder of saved conversations for the home and list scenes (D-121).
let savedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("benji-panel-render-\(UUID().uuidString)")

func savedHistory(_ saved: [(String, Double)]) -> ConversationHistory {
    guard !saved.isEmpty else { return ConversationHistory(store: nil, defaults: UserDefaults(suiteName: defaultsSuite)!) }
    let store = ConversationStore(directory: savedRoot.appendingPathComponent(UUID().uuidString))
    for (title, hours) in saved {
        let at = Date().addingTimeInterval(-hours * 3600)
        try! store.save(SavedConversation(id: ConversationStore.newID(), title: title, started: at, updated: at,
                                          lines: [SavedLine(role: .user, text: title, at: at), SavedLine(role: .assistant, text: "…", at: at)]))
    }
    let history = ConversationHistory(store: store, defaults: UserDefaults(suiteName: defaultsSuite)!)
    history.flush()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))   // the folder's list reaches the main thread
    return history
}

@MainActor
func makeModel(_ scene: Scene) -> (CompanionModel, NotchPresenter) {
    let defaults = UserDefaults(suiteName: defaultsSuite)!
    defaults.removePersistentDomain(forName: defaultsSuite)
    let backend = FakeBackend()
    let model = CompanionModel(backend: backend, screenMode: ScreenModeStore(defaults: defaults),
                               history: savedHistory(scene.saved))
    model.providerID = "claude"
    model.setScreenMode(.off)
    model.pttHint = "To talk: hold Right ⌥ and let go to send, or tap it and tap again to send."
    model.talkKeyName = "Right ⌥"
    model.captureScreen = { done in
        let thumb = NSImage(size: NSSize(width: 330, height: 216), flipped: false) { r in
            NSColor(red: 0.36, green: 0.52, blue: 0.74, alpha: 1).setFill(); r.fill()
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 40, dy: 30), xRadius: 8, yRadius: 8).fill()
            return true
        }
        done(.success(CapturedScreen(url: URL(fileURLWithPath: "/dev/null/never-written.jpg"),
                                     pixelSize: CGSize(width: 1330, height: 864), thumbnail: thumb,
                                     screenFrame: screen, displayID: nil)))
    }
    model.setPanelExpanded(scene.expanded, defaults: defaults)
    scene.setUp(model, backend)
    model.setExpanded(scene.size == .open)
    let sceneNotch = CGRect(x: screen.midX - scene.notchWidth / 2, y: notch.minY, width: scene.notchWidth, height: notch.height)
    let presenter = NotchPresenter(model: model, layout: NotchLayoutInfo(notch: sceneNotch, screenFrame: screen),
                                   accessibility: NotchAccessibility(reduceMotion: scene.reduceMotion))
    // The app's panel tells the presenter these (CompanionPanel); there is no panel here.
    presenter.setScreenOn(model.screenMode.mode == .on)
    presenter.setSettingsOn(model.settingsOpen)
    presenter.setExpandedOn(model.panelExpanded)
    presenter.showStill(scene.size, doneHolding: scene.doneHolding)
    return (model, presenter)
}

/// The panel at its open size on a desktop, cropped to the object and its shadow.
@MainActor
func panelView(_ model: CompanionModel, _ presenter: NotchPresenter, dark: Bool) -> some View {
    let open = presenter.layout.shape(.open).frame.size
    return ZStack(alignment: .top) {
        Backdrop(dark: dark)
        CompanionView(model: model, presenter: presenter, onOpen: {})
            .frame(width: open.width + 80, height: open.height + 60, alignment: .top)
    }
    .frame(width: open.width + 80, height: open.height + 60)
    .environment(\.colorScheme, dark ? .dark : .light)
}

/// Draws `view` in an offscreen window (never on a display) and returns that frame.
@MainActor
func snapshot<V: View>(_ view: V, size: CGSize, settle: Double = 0.25) -> CGImage {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(settle))
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    window.orderOut(nil)
    return rep.cgImage!
}

@MainActor
func render<V: View>(_ view: V, scale: CGFloat = 2) -> CGImage {
    let r = ImageRenderer(content: view)
    r.scale = scale
    return r.cgImage!
}

@MainActor
func writePNG(_ cg: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name + ".png"))
}

// MARK: the scenes

let recentSaved: [(String, Double)] = [
    ("Plan a weekend in Lisbon for two, mid-November…", 1.5), ("Why is my Mac's fan so loud", 5),
    ("Draft a note to the landlord about the leak", 26), ("Rename the holiday photos by date", 74),
    ("Compare two train times to Murree", 200), ("Summarise the PDF in Downloads", 900),
]

func say(_ model: CompanionModel, _ text: String) {
    model.voiceListeningStarted()
    model.voiceTranscribing()   // as VoiceController does: a transcript is taken only while transcribing
    model.voiceSubmit(text, quiet: true)
}

let scenes: [Scene] = [
    Scene(name: "01-idle", caption: "Idle: just opened, nothing said yet.") { _, _ in },
    Scene(name: "40-app-offer", caption: "An app offer on the notch card (D-187).", size: .card) { m, _ in
        m.showAppOffer(AppOfferCatalog.offer(for: "com.apple.iCal")!)
    },
    Scene(name: "41-app-offer-long", caption: "The app with the longest name and rows (D-187).", dark: true, size: .card) { m, _ in
        m.showAppOffer(AppOfferCatalog.offer(for: "com.github.GitHubClient")!)
    },
    Scene(name: "02-listening", caption: "Listening while open: live words as heard.") { m, _ in
        m.conversationChanged(on: true)
        m.voiceListeningStarted()
        m.voicePartial("What time is it in Tok")
        m.voiceLevel(0.6)
    },
    Scene(name: "03-working", caption: "Working: a request with a tool step.") { m, b in
        say(m, "Move the screenshots on my desktop into a folder")
        b.say(.tool(name: "list_dir", detail: "~/Desktop"))
    },
    Scene(name: "04-speaking", caption: "Speaking an answer.") { m, b in
        say(m, "What time is it in Tokyo?")
        b.say(.answer("It's **9:41 pm** in Tokyo, Saturday."))
        m.voiceSpeaking(true)
    },
    Scene(name: "19-streaming", caption: "A reply streaming in (D-118): the words so far, no figure block, the first sentence already spoken.") { m, b in
        say(m, "How does a plane stay up?")
        b.say(.accepted)
        for piece in ["Its wings ", "push air down, ", "so the air pushes ", "the plane up. That's ", "lift, and it grows ",
                      "with speed.\n\n```figure\n{\"title\": \"Plane\""] {
            b.say(.delta(piece))
        }
        m.voiceSpeaking(true)
    },
    Scene(name: "05-done", caption: "Done hold after a typed answer.", doneHolding: true) { m, b in
        m.composerText = "How many files are in Downloads?"
        m.submit()
        b.say(.answer("There are 214 files in Downloads. The biggest is a 2.1 GB disk image."))
        b.finish(0)
    },
    Scene(name: "06-error", caption: "An error.") { m, b in
        m.composerText = "Summarise my notes"
        m.submit()
        b.say(.error("That didn't work: the engine couldn't reach Anthropic. Check your connection."))
        b.finish(1)
    },
    Scene(name: "07-approval", caption: "An approval waits (listening paused).") { m, b in
        m.conversationChanged(on: true)
        say(m, "Delete the file called handsfree-test.txt")
        b.say(.approval(action: "Delete a file", target: "~/.benji/handsfree-test.txt"))
    },
    Scene(name: "08-screen-card", caption: "Screen is Ask: the send-time card.") { m, _ in
        m.setScreenMode(.ask)
        m.composerText = "What's wrong with this chart?"
        m.submit()
    },
    Scene(name: "09-screen-on-attached", caption: "Screen is On: a message sent with the screen, then the answer, then the conversation ended.") { m, b in
        m.setScreenMode(.on)
        m.conversationChanged(on: true)
        say(m, "Which button saves this?")
        b.say(.answer("The Save button, bottom right of the dialog."))
        b.finish(0)
        m.conversationChanged(on: false, reason: .stopPhrase)
    },
    Scene(name: "10-listening-dark", caption: "Listening, over a dark desktop.", dark: true) { m, b in
        m.composerText = "What's on my calendar?"
        m.submit()
        b.say(.answer("Two things: design review at 3, and a call with Sam at 5."))
        b.finish(0)
        m.conversationChanged(on: true)
        m.voiceListeningStarted()
        m.voiceLevel(0.3)
    },
    Scene(name: "12-stopped-after-quiet", caption: "Listening stopped after the quiet spell: a status note, not a row.") { m, b in
        m.conversationChanged(on: true)
        say(m, "What's the weather like tomorrow?")
        b.say(.answer("Mild and dry, 18° by the afternoon."))
        b.finish(0)
        m.conversationChanged(on: false, reason: .timeout)
    },
    Scene(name: "15-transcribing", caption: "Transcribing: the longest status word, in its own room.") { m, _ in
        m.conversationChanged(on: true)
        m.voiceListeningStarted()
        m.voicePartial("Open the downloads folder")
        m.voiceTranscribing()
    },
    Scene(name: "16-wide-notch-listening-screen-on", caption: "A 205 pt notch, Screen On, listening: the fullest left group.",
          notchWidth: 205) { m, _ in
        m.setScreenMode(.on)
        m.conversationChanged(on: true)
        m.voiceListeningStarted()
        m.voicePartial("What's on my screen")
        m.voiceLevel(0.6)
    },
    Scene(name: "17-working-stop", caption: "Working: the first band glyph is Stop while Benji is busy.") { m, b in
        say(m, "Tidy my downloads")
        b.say(.tool(name: "list_dir", detail: "~/Downloads"))
    },
    Scene(name: "18-settings", caption: "The settings page: the band's gear becomes Back to the conversation.") { m, _ in
        m.openSettings(.voice)
    },
    Scene(name: "13-peek-listening", caption: "The peek while listening (the notch's middle size).", size: .peek) { m, _ in
        m.conversationChanged(on: true)
        m.voiceListeningStarted()
        m.voicePartial("Open the downloads")
        m.voiceLevel(0.5)
    },
    Scene(name: "14-held-back", caption: "Listening again after words heard over another app's sound were held back.") { m, _ in
        m.conversationChanged(on: true)
        m.voiceListeningStarted()
        m.voiceTranscribing()
        m.voiceIgnored()
        m.voiceHeldBack(HandsFreeHoldReason.otherAppAudio.notice)
        m.voiceListeningStarted()
    },
    Scene(name: "20-home", caption: "Home (D-121): nothing said yet, the greeting, how to talk, and the recent saved conversations.",
          saved: recentSaved) { _, _ in },
    Scene(name: "21-home-from-a-conversation", caption: "Home asked for from a conversation: the open one is left out of the list, and the bottom-left glyph goes back to it.",
          saved: recentSaved) { m, b in
        say(m, "What time is it in Tokyo?")
        b.say(.answer("It's 9:41 pm in Tokyo, Saturday."))
        b.finish(0)
        m.showPage(.home)
    },
    Scene(name: "22-all-conversations", caption: "All conversations: newest first, each one to open or delete; Delete all asks first.",
          saved: recentSaved) { m, _ in m.showPage(.list) },
    Scene(name: "23-home-saving-off", caption: "Home with saving off and nothing saved: one quiet line says where to turn it on.") { m, _ in
        m.history.setSaving(false)
    },
    Scene(name: "24-typing", caption: "Typing (D-133): the talk capsule shrinks to a round mic; read aloud and Send sit inside the field.") { m, b in
        say(m, "Is there a newer version of that package?")
        b.say(.answer("Yes, 2.4.1 came out last week. It renames the parameter you just fixed, so read the migration note first."))
        b.finish(0)
        m.composerText = "What does the migration note say about defaults"
    },
    Scene(name: "25-date-lines", caption: "A conversation over three days (D-133): a date line between days.",
          saved: recentSaved) { m, b in
        m.openConversation(m.history.summaries.first { $0.title.hasPrefix("Compare") }!.id)
        say(m, "And today?")
        b.say(.answer("The 9:10 is still the quickest."))
        b.finish(0)
    },
    Scene(name: "26-expanded", caption: "Expanded (D-133): 720 × 560 with the conversation sidebar; New conversation and Settings are in the band, not the sidebar (D-136).",
          saved: recentSaved, expanded: true) { m, b in
        say(m, "What time is it in Tokyo?")
        b.say(.answer("It's 9:41 pm in Tokyo, Saturday."))
        b.finish(0)
    },
    Scene(name: "28-expanded-settings", caption: "Expanded with Settings open (D-136): the band's gear is the bubble back; the sidebar stays.",
          saved: recentSaved, expanded: true) { m, _ in
        m.openSettings(.voice)
    },
    Scene(name: "27-no-talk-key", caption: "Talk key off: the capsule says Click to talk.") { m, _ in
        m.talkKeyName = nil
    },
    Scene(name: "29-talk-key-needs-accessibility", caption: "Right ⌥ not ready (D-139): the capsule says why; the tooltip points to Finish Setup.") { m, _ in
        m.talkKeyName = nil
        m.talkKeyNeedsSetup = "Right ⌥"
    },
    Scene(name: "30-job-working", caption: "A background job working (D-130 step 1): one quiet row above the conversation, its title and what it is doing.") { m, b in
        say(m, "Compare noise-cancelling headphones under $200, in the background")
        b.say(.answer("I've started that; carry on."))
        b.finish(0)
        b.job(JobSnapshot(id: "5b0f3a52-2c61-4f0e-9d0a-0f5a1c1a7e11", title: "Compare headphones", state: .working,
                          line: "Reading a page", tainted: true))
    },
    Scene(name: "31-job-needs-you", caption: "The job parked on an approval: the card's words in the row, Yes and No by button only, no timer.") { m, b in
        say(m, "Compare noise-cancelling headphones under $200, in the background")
        b.say(.answer("I've started that; carry on."))
        b.finish(0)
        b.job(JobSnapshot(id: "5b0f3a52-2c61-4f0e-9d0a-0f5a1c1a7e11", title: "Compare headphones", state: .needsYou,
                          pending: JobPending(request: "a1",
                                              action: "write a file (Benji read a web page this turn)",
                                              target: "/Users/someone/.benji/jobs/5b0f3a52/output/pairs.md"), tainted: true))
    },
    Scene(name: "32-job-done-open", caption: "The job done, details open: the spoken line, the file it made, three next-step chips.") { m, b in
        say(m, "Compare noise-cancelling headphones under $200, in the background")
        b.say(.answer("I've started that; carry on."))
        b.finish(0)
        b.job(JobSnapshot(id: "5b0f3a52-2c61-4f0e-9d0a-0f5a1c1a7e11", title: "Compare headphones", state: .done,
                          spoken: "Two pairs fit under 200 dollars; I saved the comparison.",
                          files: [JobFile(name: "pairs.md", path: "/j/output/pairs.md")],
                          chips: ["Email it to me", "Add prices", "Check reviews"], tainted: true))
        m.jobExpanded = true
    },
    Scene(name: "34-settings-browser-off", caption: "Settings, Browser (D-143): off by default; the switch says what it lets a job do.") { m, _ in
        m.openSettings(.browser)
    },
    Scene(name: "35-settings-browser-on", caption: "Browser switched on, waiting for the extension; the extension folder button is the one step left.") { m, _ in
        m.settings.load = {
            var s = SettingsSnapshot()
            s.browserOn = true
            s.browserStatus = .waiting
            return s
        }
        m.openSettings(.browser)
    },
    Scene(name: "36-job-sites-open", caption: "A job that may read two sites in Chrome, parked on a card to add a third: the card's words, and the sites in the details.") { m, b in
        say(m, "Summarise my example.com inbox in the background")
        b.say(.answer("I've started that; carry on."))
        b.finish(0)
        b.job(JobSnapshot(id: "5b0f3a52-2c61-4f0e-9d0a-0f5a1c1a7e11", title: "Inbox summary", state: .needsYou,
                          pending: JobPending(request: "a1",
                                              action: "open a page in your signed-in Chrome and let this job use https://other.org from now on (Benji read a page in your browser this turn)",
                                              target: "https://other.org/auth"),
                          tainted: true, sites: ["https://example.com", "https://mail.example.com"]))
        m.jobExpanded = true
    },
    Scene(name: "33-job-peek", caption: "The peek for a job that needs you while the panel is closed.", size: .peek) { m, b in
        b.job(JobSnapshot(id: "5b0f3a52-2c61-4f0e-9d0a-0f5a1c1a7e11", title: "Compare headphones", state: .needsYou,
                          pending: JobPending(request: "a1", action: "write a file", target: "/j/output/pairs.md")))
    },
    Scene(name: "11-approval-dark-reduce-motion", caption: "Approval, dark desktop, Reduce Motion.", dark: true, reduceMotion: true) { m, b in
        m.composerText = "Empty the Downloads folder"
        m.submit()
        b.say(.approval(action: "Move 214 files to the Trash", target: "~/Downloads"))
    },
]

// MARK: the status word swap, as frames from a live animation

/// The band's status word changing Done → Speaking, captured from an offscreen window at fixed
/// moments while SwiftUI runs the transition (cacheDisplay draws the current frame).
@MainActor
func renderSwap(reduceMotion: Bool) -> [CGImage] {
    let (model, presenter) = makeModel(Scene(name: "swap", caption: "", reduceMotion: reduceMotion, doneHolding: true) { m, b in
        m.setExpanded(true)
        say(m, "What time is it in Tokyo?")
        b.say(.answer("It's 9:41 pm in Tokyo, Saturday."))
        b.finish(0)
    })
    let open = presenter.layout.shape(.open).frame.size
    let band = CGSize(width: open.width, height: 32)
    let host = NSHostingView(rootView: CompanionView(model: model, presenter: presenter, onOpen: {})
        .frame(width: open.width, height: open.height, alignment: .top))
    host.frame = CGRect(origin: .zero, size: open)
    let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: open.width, height: open.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFrontRegardless()
    func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    func frame() -> CGImage {
        host.layoutSubtreeIfNeeded()
        let rect = CGRect(x: 0, y: 0, width: band.width, height: band.height)
        let rep = host.bitmapImageRepForCachingDisplay(in: rect)!
        host.cacheDisplay(in: rect, to: rep)
        return rep.cgImage!
    }
    spin(0.3)
    var frames = [frame()]
    model.voiceSpeaking(true)   // Done → Speaking, as in the live screenshot
    let start = Date()
    for t in [0.03, 0.06, 0.09, 0.12, 0.18, 0.30] {
        RunLoop.main.run(until: start.addingTimeInterval(t))
        frames.append(frame())
    }
    window.orderOut(nil)
    return frames
}

/// The band's glyphs side by side in their slots on black: the real views, drawn at 4x by the
/// renderer, with the 22 pt slot and the centre lines faint behind them (D-135).
struct GlyphRow: View {
    let a = NotchAccessibility(reduceMotion: true)
    let symbols = ["house", "square.and.pencil", "stop.fill", "gearshape",
                   "chevron.backward", "sidebar.left", "chevron.up"]
    var body: some View {
        HStack(spacing: BandLayout.spacing) {
            ForEach(symbols, id: \.self) { symbol in
                ZStack {
                    Rectangle().stroke(Color.white.opacity(0.18), lineWidth: 0.25)
                    Rectangle().fill(Color.white.opacity(0.10)).frame(width: BandLayout.slot, height: 0.25)
                    Rectangle().fill(Color.white.opacity(0.10)).frame(width: 0.25, height: BandLayout.slot)
                    Image(systemName: symbol)
                        .font(BandGlyph.font(for: symbol))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(NotchPalette.secondary(a))
                        .compositingGroup()
                }
                .frame(width: BandLayout.slot, height: BandLayout.slot)
            }
        }
        .padding(8)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}

struct Strip: View {
    let title: String
    let frames: [CGImage]
    let labels = ["before", "30 ms", "60 ms", "90 ms", "120 ms", "180 ms", "300 ms"]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(.system(size: 12, weight: .semibold))
            ForEach(frames.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    Text(verbatim: labels[min(i, labels.count - 1)]).font(.system(size: 10, design: .monospaced))
                        .frame(width: 50, alignment: .trailing)
                    Image(decorative: frames[i], scale: 1)
                        .resizable().aspectRatio(contentMode: .fit).frame(width: 460)
                }
            }
        }
        .padding(12)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}

struct ContactSheet: View {
    let tiles: [(Scene, CGImage)]
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: title).font(.system(size: 14, weight: .semibold))
            LazyVGrid(columns: [GridItem(.fixed(340)), GridItem(.fixed(340)), GridItem(.fixed(340)), GridItem(.fixed(340))],
                      alignment: .leading, spacing: 14) {
                ForEach(tiles.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 4) {
                        Image(decorative: tiles[i].1, scale: 1).resizable().aspectRatio(contentMode: .fit).frame(width: 340)
                        Text(verbatim: tiles[i].0.name).font(.system(size: 11, weight: .semibold, design: .monospaced))
                        Text(verbatim: tiles[i].0.caption).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    var tiles: [(Scene, CGImage)] = []
    for scene in scenes {
        let (model, presenter) = makeModel(scene)
        let open = presenter.layout.shape(.open).frame.size
        let cg = snapshot(panelView(model, presenter, dark: scene.dark),
                          size: CGSize(width: open.width + 80, height: open.height + 60))
        writePNG(cg, scene.name)
        tiles.append((scene, cg))
    }
    writePNG(render(ContactSheet(tiles: tiles, title: "Benji open panel: offscreen renders, fake backend."), scale: 1.5),
             "contact-sheet")
    writePNG(render(GlyphRow(), scale: 4), "band-glyphs-4x")
    let swap = renderSwap(reduceMotion: false)
    writePNG(render(Strip(title: "Status word Done → Speaking, frames from a live offscreen window", frames: swap), scale: 2),
             "status-swap")
    let reduced = renderSwap(reduceMotion: true)
    writePNG(render(Strip(title: "The same swap under Reduce Motion", frames: reduced), scale: 2),
             "status-swap-reduce-motion")
    UserDefaults(suiteName: defaultsSuite)!.removePersistentDomain(forName: defaultsSuite)
    try? FileManager.default.removeItem(at: savedRoot)
    print("wrote \(tiles.count) panel renders and the status swap strip to \(out.path)")
}
