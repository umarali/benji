import AppKit
import SwiftUI
import BenjiCore

// The settings page as the open notch draws it, from a made-up snapshot: one PNG per section,
// then the Voice section in full (it scrolls in the app) with Kokoro's voice picker, and without
// Kokoro.

func sample(_ mode: ScreenMode = .ask) -> SettingsSnapshot {
    var s = SettingsSnapshot()
    s.figures = true
    s.model = .haiku
    s.modelInUse = "claude-haiku-5-5"
    s.readAloud = false
    s.drawingsInScreenshots = false
    s.handsFreeAvailable = true
    s.listenWhileOpen = true
    s.keepListeningWhenClosed = true
    s.holdBack = false
    s.bargeIn = .headphones
    s.idleTimeout = 300
    s.idleTimeoutChoices = HandsFreeSettings.idleTimeoutChoices
    s.transcription = "On this Mac (Apple speech)"
    s.voice = "Zoe (Premium)"
    s.screenMode = mode
    for m in ScreenMode.allCases { s.screenCaptions[m] = ScreenCapturePolicy.modeCaption(m, provider: "anthropic") }
    s.talkKey = "Right ⌥"
    s.permissions = [.init(permission: .microphone, granted: true), .init(permission: .speechRecognition, granted: true),
                     .init(permission: .accessibility, granted: true), .init(permission: .screenRecording, granted: false)]
    s.version = "Benji 0.4 (12)"
    return s
}

/// Kokoro installed and running: the six voices, Bella chosen, a little faster.
func kokoroSample() -> SettingsSnapshot {
    var s = sample()
    s.voiceStatus = .kokoro
    s.voiceChoices = KokoroVoices.offered
    s.voiceChosen = "af_bella"
    s.voice = "Bella, Kokoro on this Mac"
    s.voiceSpeed = 1.15
    return s
}

struct Frame: View {
    let model: SettingsModel
    /// Taller than the panel to show a whole section that scrolls in the app.
    var height = PanelGeometry.settingsSize.height
    var body: some View {
        let size = CGSize(width: PanelGeometry.settingsSize.width, height: height)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: BandLayout.spacing) {   // the band's right group: back to the conversation, collapse
                ForEach(["", "bubble.left", "chevron.up"], id: \.self) { symbol in
                    if symbol.isEmpty {
                        Spacer()
                    } else {
                        Image(systemName: symbol).font(.system(size: BandLayout.symbolSize, weight: .semibold))
                            .foregroundStyle(NotchPalette.secondary(NotchAccessibility()))
                            .frame(width: BandLayout.slot, height: BandLayout.slot)
                    }
                }
            }
            .frame(height: 32)
            SettingsPage(model: model, a: NotchAccessibility(), scrolls: false) {}
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26, style: .continuous)
            .fill(Color.black))
        .padding(24)
        .background(Color(red: 0.36, green: 0.55, blue: 0.70))
        .environment(\.colorScheme, .dark)
    }
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])

@MainActor func render(_ frame: Frame, _ name: String) {
    let renderer = ImageRenderer(content: frame)
    renderer.scale = 2
    guard let cg = renderer.cgImage else { fatalError("no image for \(name)") }
    let rep = NSBitmapImageRep(cgImage: cg)
    let url = out.appendingPathComponent(name + ".png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print(url.lastPathComponent)
}

MainActor.assumeIsolated {
    for (i, section) in SettingsSection.allCases.enumerated() {
        let model = SettingsModel(load: { sample() })
        model.section = section
        render(Frame(model: model), String(format: "%02d-%@", i, section.rawValue))
    }
    let picker = SettingsModel(load: { kokoroSample() })
    picker.section = .voice
    render(Frame(model: picker, height: 1210), "10-voice-kokoro")
    let noKokoro = SettingsModel(load: { sample() })
    noKokoro.section = .voice
    render(Frame(model: noKokoro, height: 760), "11-voice-no-kokoro")
    // Settings › Memory: saved conversations and what Benji remembers.
    var memory = sample()
    memory.savedConversations = 12
    memory.facts = ["the user's name is Umar", "prefers short answers, no bullet lists",
                    "works on Benji, a notch assistant for the Mac", "has a design review every Tuesday at 10"]
        .enumerated().map { ProfileFact(line: $0.offset, text: $0.element) }
    let model = SettingsModel(load: { memory })
    model.select(.memory)
    let renderer = ImageRenderer(content: Frame(model: model))
    renderer.scale = 2
    let rep = NSBitmapImageRep(cgImage: renderer.cgImage!)
    let url = out.appendingPathComponent(String(format: "%02d-memory.png", SettingsSection.allCases.count))
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print(url.lastPathComponent)
}
