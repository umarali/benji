import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import BenjiCore

/// What was captured and is about to be sent.
struct CapturedScreen {
    let url: URL            // temp JPEG handed to the engine; deleted after the reply
    let pixelSize: CGSize   // size actually sent (after downscaling)
    let thumbnail: NSImage  // kept in memory only, for the transcript
    let screenFrame: CGRect // the captured display in AppKit coordinates, for mapping pointers back
    var displayID: UInt32?  // to find that display again for the overlay (never by index)
    var windows: [WindowInfo] = []   // on-screen windows right after the capture, front to back
    var leftOut = 0                  // password-manager and private windows kept out of the picture
    var geometry: ScreenshotGeometry?   // size, notch and menu bar in the sent image's pixels, for the model
    var displayName: String?         // the display's name while more than one is connected, for the transcript
}

enum ScreenCaptureError: LocalizedError {
    case permissionNeeded
    case noDisplay
    /// The display the message started on was disconnected; no other display is captured instead.
    case displayGone(String?)
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .permissionNeeded:
            return "Benji doesn't have Screen Recording permission. Allow it in System Settings › "
                + "Privacy & Security › Screen & System Audio Recording, then quit and reopen Benji."
        case .noDisplay:
            return "Couldn't find the display to capture."
        case .displayGone(let name):
            return "\(name ?? "The display you were using") isn't connected any more, so no other display was captured."
        case .encodeFailed:
            return "Couldn't prepare the screenshot."
        }
    }
}

/// Which display a message's screenshot is taken of: the one latched when the message started
/// (`CompanionModel.captureTarget`), refused if it has been disconnected; with nothing latched, the
/// one under the pointer, then the panel's. The app and the tests route through this one function.
enum CaptureRouting {
    static func route(target: CaptureTarget?, displays: [DisplayDescriptor], pointer: CGPoint, fallback: UInt32?,
                      capture: (UInt32, @escaping (Result<CapturedScreen, Error>) -> Void) -> Void,
                      completion: @escaping (Result<CapturedScreen, Error>) -> Void) {
        switch CaptureDisplay.choose(requested: target, displays: displays, pointer: pointer, fallback: fallback) {
        case .display(let id): capture(id, completion)
        case .disconnected(let gone): completion(.failure(ScreenCaptureError.displayGone(gone.name)))
        case .none: completion(.failure(ScreenCaptureError.noDisplay))
        }
    }
}

/// Takes exactly one screenshot when asked. There is no stream and no timer: each
/// call is a single explicit capture of one display for a single message. Left out of the
/// picture itself (ScreenCaptureKit never draws them): Benji's own windows, password managers,
/// notification banners, and private browser windows whose titles say so (CaptureExclusions).
/// Nothing else is read: no clipboard, no URLs, no window titles are sent.
final class ScreenCapturer {
    /// Benji's own windows to keep in its screenshot: a picture up while drawings show in
    /// captures (chilly-whiteboard), so the model sees what it drew. Read on the main thread.
    static var keepIn: () -> Set<Int> = { [] }

    func capture(screen: NSScreen, completion: @escaping (Result<CapturedScreen, Error>) -> Void) {
        let keep = Self.keepIn()
        guard Permissions.isGranted(.screenRecording) else {
            Permissions.request(.screenRecording)   // system prompt once, then Settings
            completion(.failure(ScreenCaptureError.permissionNeeded))
            return
        }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let scale = screen.backingScaleFactor
        let screenFrame = screen.frame
        // The notch never shows in a capture, so the model is told where it is (ScreenshotGeometry).
        let notch = PanelGeometry.hardwareNotch(screenFrame: screenFrame, leftArea: screen.auxiliaryTopLeftArea,
                                                rightArea: screen.auxiliaryTopRightArea,
                                                safeAreaTop: screen.safeAreaInsets.top)
        let menuBar = screenFrame.maxY - screen.visibleFrame.maxY
        let builtIn = displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
        let displays = NSScreen.screens.count
        let displayName = displays > 1 ? screen.localizedName : nil

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                // Only the display whose frame the pointers will be mapped onto.
                guard let display = content.displays.first(where: { $0.displayID == displayID })
                        ?? (displayID == nil ? content.displays.first : nil) else {
                    throw ScreenCaptureError.noDisplay
                }
                // Leave out every window Benji owns (the panel, the overlay, any alert), and
                // what must never be sent. Titles are read here only to spot private windows.
                let ownPID = ProcessInfo.processInfo.processIdentifier
                var leftOut = 0
                let excluded = content.windows.filter { w in
                    if keep.contains(Int(w.windowID)) { return false }
                    let app = w.owningApplication
                    guard let reason = CaptureExclusions.reason(bundleID: app?.bundleIdentifier,
                                                                pid: app?.processID ?? 0, ownPID: ownPID,
                                                                title: w.title) else { return false }
                    // Counted for the transcript: password managers and private windows. Notification
                    // Center also owns the desktop widgets, so counting it would always say "1".
                    if (reason == .passwordManager || reason == .privateBrowsing) && w.frame.intersects(display.frame) {
                        leftOut += 1
                    }
                    return true
                }
                let filter = SCContentFilter(display: display, excludingWindows: excluded)

                let config = SCStreamConfiguration()
                config.width = Int(CGFloat(display.width) * scale)
                config.height = Int(CGFloat(display.height) * scale)
                config.showsCursor = false

                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                var shot = try Self.encode(image, screenFrame: screenFrame)
                shot.displayID = displayID
                shot.displayName = displayName
                shot.windows = WindowList.current()
                shot.leftOut = leftOut
                shot.geometry = ScreenshotGeometry.make(pixelSize: shot.pixelSize, screenFrame: screenFrame,
                                                        notch: notch, menuBarHeight: menuBar,
                                                        builtIn: builtIn, displayCount: displays)
                DispatchQueue.main.async { completion(.success(shot)) }
            } catch {
                // A remembered grant that no longer works: stop trusting it and say why.
                let denied = (error as NSError).domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
                    && (error as NSError).code == -3801
                DispatchQueue.main.async {
                    if denied { Permissions.forgetScreenRecordingGrant() }
                    completion(.failure(denied ? ScreenCaptureError.permissionNeeded : error))
                }
            }
        }
    }

    /// A small grey sample of one display, to tell when the screen has settled after a screen step
    /// (ScreenSettle). Kept in memory for one comparison: never stored or sent. Benji's own
    /// windows are left out, so the target's ring fading doesn't count as a change.
    func sample(displayID: UInt32?, completion: @escaping ([UInt8]?) -> Void) {
        Task {
            let pixels: [UInt8]? = await {
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                      let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let own = content.windows.filter { $0.owningApplication?.processID == ownPID }
                let config = SCStreamConfiguration()
                config.width = ScreenSettle.sampleWidth
                config.height = max(1, ScreenSettle.sampleWidth * display.height / max(1, display.width))
                config.showsCursor = false
                guard let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: own), configuration: config)
                else { return nil }
                let w = config.width, h = config.height
                var gray = [UInt8](repeating: 0, count: w * h)
                let drawn = gray.withUnsafeMutableBytes { buf -> Bool in
                    guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                              space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                    return true
                }
                return drawn ? gray : nil
            }()
            DispatchQueue.main.async { completion(pixels) }
        }
    }

    /// Downscale per ScreenCapturePolicy and write a JPEG to a temp file.
    static func encode(_ image: CGImage, screenFrame: CGRect) throws -> CapturedScreen {
        let target = ScreenCapturePolicy.targetSize(for: CGSize(width: image.width, height: image.height))
        let w = Int(target.width), h = Int(target.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ScreenCaptureError.encodeFailed
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { throw ScreenCaptureError.encodeFailed }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("benji-screen-\(UUID().uuidString).jpg")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ScreenCaptureError.encodeFailed }
        CGImageDestinationAddImage(dest, scaled,
                                   [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ScreenCaptureError.encodeFailed }

        let thumb = NSImage(cgImage: scaled, size: NSSize(width: CGFloat(w) / 4, height: CGFloat(h) / 4))
        return CapturedScreen(url: url, pixelSize: target, thumbnail: thumb, screenFrame: screenFrame)
    }

    /// Remove screenshots, voice recordings and conversation-history files left behind
    /// (e.g. if the engine quit mid-turn).
    static func removeLeftovers() {
        let tmp = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        let prefixes = ["benji-screen-", "benji-history-", "benji-ptt-", "chilly-screen-", "chilly-history-", "chilly-ptt-"]  // older builds' leftovers too
        for f in files where prefixes.contains(where: f.lastPathComponent.hasPrefix) {
            try? FileManager.default.removeItem(at: f)
        }
    }
}
