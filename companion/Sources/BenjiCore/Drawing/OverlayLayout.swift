import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The display options that change how a mark looks or moves (Overlay.md, Variants), read from
/// `NSWorkspace` in the app and set by hand in tests and renders.
public struct OverlayAppearance: Equatable, Sendable {
    public var reduceMotion: Bool
    public var increaseContrast: Bool
    public var reduceTransparency: Bool
    /// No change to the mark: its meaning is its shape and the label's words, never its colour.
    public var differentiateWithoutColor: Bool

    public init(reduceMotion: Bool = false, increaseContrast: Bool = false,
                reduceTransparency: Bool = false, differentiateWithoutColor: Bool = false) {
        self.reduceMotion = reduceMotion
        self.increaseContrast = increaseContrast
        self.reduceTransparency = reduceTransparency
        self.differentiateWithoutColor = differentiateWithoutColor
    }

    public static let standard = OverlayAppearance()
}

public enum MarkKind: Equatable, Sendable { case ring, region }

extension PointingMark {
    public var kind: MarkKind {
        if case .region = self { return .region }
        return .ring
    }

    public var label: String {
        switch self {
        case let .ring(_, label), let .region(_, label): return label
        }
    }
}

/// One concentric layer of a mark, as distances from the target: the radius from the point for
/// a ring, the outset from the box for a region.
public struct MarkBand: Equatable, Sendable {
    public let inner: CGFloat
    public let outer: CGFloat

    public init(_ inner: CGFloat, _ outer: CGFloat) {
        self.inner = inner
        self.outer = outer
    }

    public var middle: CGFloat { (inner + outer) / 2 }
    public var width: CGFloat { outer - inner }
}

/// The layers of a mark from the inside out (Overlay.md, Anatomy and Variants).
public struct MarkLayers: Equatable, Sendable {
    public enum Keyline: Equatable, Sendable {
        case black60       // default
        case black         // Increase Contrast
        case notchRaised   // Reduce Transparency
    }
    public enum LabelBackground: Equatable, Sendable {
        case material         // dark HUD material, `notch-hairline` edge
        case opaqueBordered   // Increase Contrast: `notch-raised`, 1 pt `notch-label-secondary`
        case opaque           // Reduce Transparency: `notch-raised`, no blur
    }

    public let innerKeyline: MarkBand
    public let mint: MarkBand
    public let outerKeyline: MarkBand
    public let keyline: Keyline
    /// `shadow-pointer`, with the material band under it. None under Reduce Transparency,
    /// and so no pulse either: the pulse is a copy of the halo.
    public let halo: MarkBand?
    public let labelBackground: LabelBackground

    /// The outer halo edge, or the outer keyline without a halo: labels never touch it.
    public var keepOut: CGFloat { halo?.outer ?? outerKeyline.outer }

    /// The region's corner radius at a given outset: concentric layers, `radius-field` (10 pt)
    /// at the mint edge.
    public static func cornerRadius(atOutset outset: CGFloat) -> CGFloat { max(outset + 4, 0) }

    public static let haloWidth: CGFloat = 6

    public static func of(_ kind: MarkKind, _ a: OverlayAppearance) -> MarkLayers {
        // Ring: mint 10–13 pt from the point (`pointer-ring` 26 pt outside). Region: 4–6 pt
        // outside the box. Increase Contrast adds 1 pt, growing inward.
        let (mintIn, mintOut): (CGFloat, CGFloat) = kind == .ring ? (10, 13) : (4, 6)
        let mint = MarkBand(mintIn - (a.increaseContrast ? 1 : 0), mintOut)
        let k: CGFloat = a.reduceTransparency ? 2 : (a.increaseContrast ? 1.5 : 1)
        let outer = MarkBand(mint.outer, mint.outer + k)
        return MarkLayers(
            innerKeyline: MarkBand(mint.inner - k, mint.inner),
            mint: mint,
            outerKeyline: outer,
            keyline: a.increaseContrast ? .black : (a.reduceTransparency ? .notchRaised : .black60),
            halo: a.reduceTransparency ? nil : MarkBand(outer.outer, outer.outer + haloWidth),
            labelBackground: a.increaseContrast ? .opaqueBordered : (a.reduceTransparency ? .opaque : .material))
    }
}

/// How a mark arrives (Overlay.md, Reveal): drawn in place, or gliding from the ring before.
public enum MarkStep: Equatable, Sendable {
    case reveal
    case glide(from: CGPoint)
}

/// Where the overlay's marks and labels go (Overlay.md, Placement).
/// AppKit global points throughout (origin bottom-left, y up).
public enum OverlayLayout {
    /// `space-2`: gap between the halo and the label.
    public static let labelGap: CGFloat = 8
    /// `space-3`: inset of the safe area, and clearance from the notch and Benji's panels.
    public static let safeInset: CGFloat = 12
    public static let maxLabelWidth: CGFloat = 240
    /// How much further than `space-2` a label below or above may sit to reach the safe area.
    public static let maxAwayShift: CGFloat = 24

    /// The part of the screen a mark covers, label excluded: its outer halo edge (the outer
    /// keyline under Reduce Transparency).
    public static func keepOut(for mark: PointingMark, appearance: OverlayAppearance = .standard) -> CGRect {
        let d = MarkLayers.of(mark.kind, appearance).keepOut
        switch mark {
        case let .ring(center, _):
            return CGRect(x: center.x - d, y: center.y - d, width: 2 * d, height: 2 * d)
        case let .region(rect, _):
            return rect.insetBy(dx: -d, dy: -d)
        }
    }

    public static func target(of mark: PointingMark) -> CGPoint {
        switch mark {
        case let .ring(center, _): return center
        case let .region(rect, _): return CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    /// What a click must land in to dismiss the mark: the target plus its outset (to the mint edge).
    public static func hitArea(for mark: PointingMark) -> CGRect {
        let d = MarkLayers.of(mark.kind, .standard).mint.outer
        switch mark {
        case let .ring(center, _):
            return CGRect(x: center.x - d, y: center.y - d, width: 2 * d, height: 2 * d)
        case let .region(rect, _):
            return rect.insetBy(dx: -d, dy: -d)
        }
    }

    /// The label's frame: below the mark, else above, else trailing, else leading; nil when no
    /// side fits (the words are in the answer). A side fits inside `visibleFrame` inset by
    /// `space-3`, clear of the mark's keep-out and of every rect in `avoid` (the notch object,
    /// Benji's panels) by `space-3`. Below and above may slide sideways, trailing and leading
    /// up and down, only while the label still spans the target's centre.
    public static func labelFrame(size: CGSize, for mark: PointingMark, visibleFrame: CGRect,
                                  avoid: [CGRect] = [], appearance: OverlayAppearance = .standard) -> CGRect? {
        let safe = visibleFrame.insetBy(dx: safeInset, dy: safeInset)
        let k = keepOut(for: mark, appearance: appearance)
        let c = target(of: mark)
        let w = min(size.width, maxLabelWidth), h = size.height

        func fits(_ r: CGRect) -> Bool {
            safe.contains(r) && !r.intersects(k)
                && !avoid.contains { $0.insetBy(dx: -safeInset, dy: -safeInset).intersects(r) }
        }
        /// Slides `start` (the centred position) along one axis into [lo, hi], keeping `c` covered.
        func slide(_ start: CGFloat, length: CGFloat, lo: CGFloat, hi: CGFloat, centre: CGFloat) -> CGFloat? {
            let clamped = min(max(start, lo), hi - length)
            guard clamped >= lo, clamped + length <= hi, clamped <= centre, centre <= clamped + length else { return nil }
            return clamped
        }

        var candidates: [CGRect] = []
        if let x = slide(c.x - w / 2, length: w, lo: safe.minX, hi: safe.maxX, centre: c.x) {
            // A target in the menu bar or the Dock sits outside the safe area: its label may move
            // a little further away (never closer) to land inside it.
            let belowTop = min(k.minY - labelGap, max(safe.maxY, k.minY - labelGap - maxAwayShift))
            let aboveBottom = max(k.maxY + labelGap, min(safe.minY, k.maxY + labelGap + maxAwayShift))
            candidates.append(CGRect(x: x, y: belowTop - h, width: w, height: h))       // below
            candidates.append(CGRect(x: x, y: aboveBottom, width: w, height: h))        // above
        }
        if let y = slide(c.y - h / 2, length: h, lo: safe.minY, hi: safe.maxY, centre: c.y) {
            candidates.append(CGRect(x: k.maxX + labelGap, y: y, width: w, height: h))       // trailing
            candidates.append(CGRect(x: k.minX - labelGap - w, y: y, width: w, height: h))   // leading
        }
        return candidates.first(where: fits)
    }

    /// The next mark glides from the one before when both are rings no more than
    /// `followMaxHop` (220 pt) apart; otherwise the old one fades and the new one is drawn.
    /// Under Reduce Motion nothing glides: the two crossfade.
    public static func step(from previous: PointingMark?, to next: PointingMark, reduceMotion: Bool) -> MarkStep {
        guard !reduceMotion, case let .ring(from, _)? = previous, case let .ring(to, _) = next else { return .reveal }
        let hop = hypot(to.x - from.x, to.y - from.y)
        return hop <= CGFloat(MotionTiming.followMaxHop) ? .glide(from: from) : .reveal
    }

    /// Puts a mark on the display's backing pixel grid (`scale` pixels per point), so 1 pt
    /// keylines stay crisp: a ring's centre on a pixel corner, a region's edges on pixel edges.
    public static func snapped(_ mark: PointingMark, scale: CGFloat) -> PointingMark {
        guard scale > 0 else { return mark }
        func s(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        switch mark {
        case let .ring(c, label):
            return .ring(center: CGPoint(x: s(c.x), y: s(c.y)), label: label)
        case let .region(r, label):
            let x = s(r.minX), y = s(r.minY)
            return .region(rect: CGRect(x: x, y: y, width: s(r.maxX) - x, height: s(r.maxY) - y), label: label)
        }
    }

    /// The hardware notch on a display, from the menu-bar areas either side of it
    /// (`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`); nil without a notch.
    public static func notchRect(screenFrame: CGRect, topLeftArea: CGRect?, topRightArea: CGRect?) -> CGRect? {
        guard let l = topLeftArea, let r = topRightArea, r.minX > l.maxX else { return nil }
        let h = max(l.height, r.height)
        return CGRect(x: l.maxX, y: screenFrame.maxY - h, width: r.minX - l.maxX, height: h)
    }
}

/// What VoiceOver hears when a mark is revealed (Overlay.md, Accessibility). Nothing on erase.
public enum PointingAnnouncement {
    public static func text(label: String, step: Int, of count: Int) -> String {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence: (String) -> String = { s in
            guard let last = s.last, !".!?".contains(last) else { return s }
            return s + "."
        }
        if count > 1 {
            return sentence("Step \(step) of \(count): \(name.isEmpty ? "something on screen" : name)")
        }
        return sentence(name.isEmpty ? "Pointing at something on screen" : "Pointing at \(name)")
    }
}

/// When each target of an answer is revealed, estimated from the words (Overlay.md, Reveal):
/// at the first word of its label, at 4.5 syllables per second, a comma counting as one
/// syllable and a sentence end as two. A label whose words aren't in the text is revealed at
/// the end of the first sentence (the first target) or `minimumStep` after the one before.
public enum RevealTiming {
    public static let syllablesPerSecond = MotionTiming.syllablesPerSecond
    /// Each mark stays at least this long before the next replaces it.
    public static let minimumStep = 1.2

    /// Leading words of a label that don't name anything, skipped when finding its anchor word.
    static let articles: Set<String> = ["the", "a", "an"]

    public static func anchors(labels: [String], in text: String) -> [Double] {
        cues(labels: labels, in: text).map(\.seconds)
    }

    /// One cue per label: where its anchor word starts in `text` (UTF-16 offset, which is what
    /// the speech synthesizer reports) and its estimated time from the start of speech.
    public static func cues(labels: [String], in text: String) -> [RevealCue] {
        let tokens = tokenize(text)
        var cues: [RevealCue] = []
        var searchFrom = 0
        for label in labels {
            let earliest = (cues.last?.seconds ?? -minimumStep) + minimumStep
            let words = tokenize(label).compactMap(\.word)
            let first = words.first(where: { !articles.contains($0) }) ?? words.first
            var t: Double
            var offset: Int?
            if let first, let i = tokens[searchFrom...].firstIndex(where: { $0.word == first }) {
                t = seconds(before: i, in: tokens)
                offset = tokens[i].offset
                searchFrom = i + 1
            } else if cues.isEmpty, let end = tokens.firstIndex(where: { $0.sentenceEnd }) {
                t = seconds(before: end + 1, in: tokens)
                offset = tokens[end].offset
            } else {
                t = earliest
            }
            cues.append(RevealCue(offset: offset, seconds: max(t, earliest, 0)))
        }
        return cues
    }

    /// Syllables in a word: groups of vowels (y counts), a silent final e dropped, at least one.
    public static func syllables(_ word: String) -> Int {
        let w = word.lowercased().filter(\.isLetter)
        guard !w.isEmpty else { return 0 }
        var count = 0, inVowel = false
        for ch in w {
            let v = "aeiouy".contains(ch)
            if v && !inVowel { count += 1 }
            inVowel = v
        }
        if w.hasSuffix("e") && !w.hasSuffix("le") && count > 1 { count -= 1 }
        return max(count, 1)
    }

    struct Token { var word: String?; var comma = false; var sentenceEnd = false; var offset = 0 }

    static func tokenize(_ text: String) -> [Token] {
        var out: [Token] = []
        var current = "", start = 0, offset = 0
        func flush() {
            if !current.isEmpty { out.append(Token(word: current.lowercased(), offset: start)) }
            current = ""
        }
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" {
                if current.isEmpty { start = offset }
                current.append(ch)
            } else {
                flush()
                if ch == "," || ch == ";" || ch == ":" { out.append(Token(word: nil, comma: true, offset: offset)) }
                if ch == "." || ch == "!" || ch == "?" { out.append(Token(word: nil, sentenceEnd: true, offset: offset)) }
            }
            offset += ch.utf16.count
        }
        flush()
        return out
    }

    static func seconds(before index: Int, in tokens: [Token]) -> Double {
        let syl = tokens[..<index].reduce(0.0) { sum, t in
            sum + Double(t.word.map(syllables) ?? 0)
                + (t.comma ? MotionTiming.commaSyllables : 0)
                + (t.sentenceEnd ? MotionTiming.sentenceEndSyllables : 0)
        }
        return syl / syllablesPerSecond
    }
}

/// Where and when one target is revealed.
public struct RevealCue: Equatable, Sendable {
    /// UTF-16 offset of the anchor word in the text; nil when there is none to wait for.
    public let offset: Int?
    /// Estimated seconds from the start of speech (or of reading).
    public let seconds: Double

    public init(offset: Int?, seconds: Double) {
        self.offset = offset
        self.seconds = seconds
    }
}
