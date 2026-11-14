import Foundation

// Benji's own five cues (D-173, step 7 of D-130; designed in the sound notes of the design work, D-61, D-65).
//
// Short, soft tones synthesised from sine partials by tools/make_cues.py: no recordings, no samples,
// nothing copied. Off by default, one switch in Settings. Three of them are heard for a job's outcome
// (done, needs you, error); the listening pair is bundled with the others but not played yet. No drawing
// sounds. A cue never plays for the user's own key press or typed message: it is an unasked surface,
// so it goes through the quiet check first (QuietCheck.swift).

public enum CueID: String, CaseIterable, Equatable, Sendable {
    case listeningOn = "listening-on"
    case listeningOff = "listening-off"
    case done
    case approval
    case error
}

public enum CueCatalog {
    /// How many variants each cue has. They differ in pitch by a little and in nothing else, and play in
    /// a shuffle-bag order so the twentieth hearing isn't a machine gun.
    public static let variants: [CueID: Int] = [.listeningOn: 2, .listeningOff: 2, .done: 3, .approval: 2, .error: 2]

    public static func fileName(_ id: CueID, variant: Int) -> String { "benji-\(id.rawValue)-\(variant).wav" }

    /// Every file the catalog names; the folder `Resources/Cues` holds exactly these and a manifest.
    public static var allFiles: [String] {
        CueID.allCases.flatMap { id in (1...(variants[id] ?? 1)).map { fileName(id, variant: $0) } }
    }

    /// The bundle folder the files are copied into by companion/build.sh.
    public static let folderName = "Cues"

    /// A job's change of state → the cue it is heard as.
    public static func cue(for job: JobCue) -> CueID {
        switch job {
        case .done: return .done
        case .needsApproval: return .approval
        case .error: return .error
        }
    }
}

public enum CueSettings {
    /// Off unless switched on (the key that Jobs.swift already reads: `JobCues.defaultsKey`).
    public static let defaultsKey = JobCues.defaultsKey
    public static let volumeKey = "cueVolume"
    public static let defaultVolume = 0.7

    public static func isOn(_ stored: Any?) -> Bool { JobCues.isOn(stored) }

    public static func volume(_ stored: Any?) -> Double {
        guard let v = stored as? Double, v.isFinite else { return defaultVolume }
        return min(1, max(0, v))
    }

    /// The player's gain: the slider squared (an audio taper; 70% is about -6 dB). Cues peak at -18 dBFS
    /// already, so this only ever turns them down.
    public static func gain(volume: Double) -> Float {
        let v = min(1, max(0, volume))
        return Float(v * v)
    }
}

/// A shuffle bag: every variant once, in random order, then a refill that never starts with the one
/// just played. The generator is injected so a test can fix the order.
public struct ShuffleBag: Sendable {
    private var remaining: [Int] = []
    private var last: Int?
    public let count: Int

    public init(count: Int) { self.count = max(1, count) }

    /// The next variant, 1...count. `pick(n)` chooses an index in 0..<n.
    public mutating func next(using pick: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Int {
        var candidates = remaining
        if remaining.isEmpty {
            candidates = Array(1...count)
            remaining = candidates
            if count > 1, let last { candidates.removeAll { $0 == last } }   // not the one just played
        }
        let value = candidates[min(max(0, pick(candidates.count)), candidates.count - 1)]
        remaining.removeAll { $0 == value }
        last = value
        return value
    }
}

public enum CuePlan {
    public enum Skip: Equatable, Sendable {
        case off
        case benjiSpeaking
        case quiet(QuietReason)
    }

    public enum Result: Equatable, Sendable {
        case play(CueID)
        case skipped(Skip)
    }

    /// Whether to play the cue for a job's change of state now. The switch comes first (off costs
    /// nothing: the signals are not even read), then Benji's own voice (a cue never plays over speech),
    /// then the quiet check.
    public static func plan(_ cue: JobCue, switchOn: Bool, benjiSpeaking: Bool,
                            signals: () -> QuietSignals) -> Result {
        guard switchOn else { return .skipped(.off) }
        guard !benjiSpeaking else { return .skipped(.benjiSpeaking) }
        switch QuietGate().verdict(switchOn: true, signals: signals) {
        case .allowed: return .play(CueCatalog.cue(for: cue))
        case .switchedOff: return .skipped(.off)
        case let .quiet(reason): return .skipped(.quiet(reason))
        }
    }
}


/// The words on the Settings page for keys and cues.
public enum KeyCopy {
    public static let footer = "Benji's helper reads the key from the Keychain when it starts. Once you move it, Benji never reads a key from ~/.benji.env again, and if the Keychain can't be read it says so instead of falling back. In a terminal, set the key in the environment."
}

public enum CueCopy {
    public static let detail = "A soft sound when a background job finishes, needs your go-ahead or fails. Off until you turn it on."
    public static let footer = "Benji stays quiet while you're on a call (a meeting window, or a call app using the microphone), and never plays over its own voice. It can't see Focus or screen sharing, so those are not checked."
}
