import XCTest
@testable import BenjiCore

final class CuesTests: XCTestCase {
    private var cuesFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Cues")
    }

    // MARK: the files

    func testEveryCueIdResolvesToAFileAndEveryAudioFileIsReferenced() throws {
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: cuesFolder.path).filter { $0.hasSuffix(".wav") }.sorted()
        XCTAssertEqual(CueCatalog.allFiles.sorted(), onDisk, "the catalog names exactly the files in Resources/Cues")
        for id in CueID.allCases {
            let count = CueCatalog.variants[id] ?? 0
            XCTAssertGreaterThan(count, 0, "\(id) has a variant")
            for v in 1...count {
                XCTAssertTrue(FileManager.default.fileExists(atPath: cuesFolder.appendingPathComponent(CueCatalog.fileName(id, variant: v)).path), "\(id) \(v)")
            }
        }
        XCTAssertEqual(CueID.allCases.count, 5, "five cues")
    }

    func testTheManifestAgreesWithTheCatalog() throws {
        let data = try Data(contentsOf: cuesFolder.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cues = try XCTUnwrap(manifest["cues"] as? [[String: Any]])
        XCTAssertEqual(cues.compactMap { $0["id"] as? String }, CueID.allCases.map(\.rawValue))
        for cue in cues {
            let id = try XCTUnwrap(CueID(rawValue: cue["id"] as! String))
            XCTAssertEqual(cue["files"] as? [String], (1...CueCatalog.variants[id]!).map { CueCatalog.fileName(id, variant: $0) })
        }
    }

    /// Reads a 16-bit mono PCM WAV; fails the test on anything else.
    private func samples(_ url: URL) throws -> (rate: Int, samples: [Int16]) {
        let d = try Data(contentsOf: url)
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        XCTAssertEqual(String(decoding: d[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: d[8..<12], as: UTF8.self), "WAVE")
        var offset = 12
        var rate = 0, channels = 0, bits = 0
        while offset + 8 <= d.count {
            let tag = String(decoding: d[offset..<offset + 4], as: UTF8.self), size = u32(offset + 4)
            if tag == "fmt " { XCTAssertEqual(u16(offset + 8), 1, "PCM"); channels = u16(offset + 10); rate = u32(offset + 12); bits = u16(offset + 22) }
            if tag == "data" {
                XCTAssertEqual(channels, 1); XCTAssertEqual(bits, 16)
                let body = d[offset + 8..<offset + 8 + size]
                let s = stride(from: body.startIndex, to: body.endIndex, by: 2).map { Int16(bitPattern: UInt16(body[$0]) | UInt16(body[$0 + 1]) << 8) }
                return (rate, s)
            }
            offset += 8 + size + (size & 1)
        }
        XCTFail("no data chunk")
        return (0, [])
    }

    func testEveryBundledCueIsMeasured() throws {
        for name in CueCatalog.allFiles {
            let (rate, s) = try samples(cuesFolder.appendingPathComponent(name))
            XCTAssertEqual(rate, 48_000, name)
            let seconds = Double(s.count) / Double(rate)
            XCTAssertTrue((0.1...0.6).contains(seconds), "\(name): \(seconds) s")
            let peak = Double(s.map { abs(Int($0)) }.max() ?? 0) / 32768
            XCTAssertLessThanOrEqual(peak, pow(10, -18.0 / 20), "\(name) peaks at or under -18 dBFS (far from clipping)")
            XCTAssertGreaterThan(peak, pow(10, -30.0 / 20), "\(name) is not silent")
            let mean = Double(s.reduce(0) { $0 + Int($1) }) / Double(s.count) / 32768
            XCTAssertLessThan(abs(mean), 0.0005, "\(name): no DC offset")
            XCTAssertEqual(s.first, 0, "\(name) starts on zero")
            XCTAssertEqual(s.last, 0, "\(name) ends on zero")
        }
    }

    // MARK: mapping, switch, gain, order

    func testJobOutcomesMapToCues() {
        XCTAssertEqual(CueCatalog.cue(for: .done), .done)
        XCTAssertEqual(CueCatalog.cue(for: .needsApproval), .approval)
        XCTAssertEqual(CueCatalog.cue(for: .error), .error)
        // And a change of a job's state maps through the existing rule.
        XCTAssertEqual(JobCues.cue(from: .working, to: .done).map(CueCatalog.cue(for:)), .done)
        XCTAssertEqual(JobCues.cue(from: .working, to: .needsYou).map(CueCatalog.cue(for:)), .approval)
        XCTAssertEqual(JobCues.cue(from: .working, to: .failed).map(CueCatalog.cue(for:)), .error)
        XCTAssertNil(JobCues.cue(from: .queued, to: .working))
    }

    func testCuesAreOffByDefaultAndTheVolumeIsAnAudioTaper() {
        XCTAssertFalse(CueSettings.isOn(nil))
        XCTAssertFalse(CueSettings.isOn("yes"))
        XCTAssertTrue(CueSettings.isOn(true))
        XCTAssertEqual(CueSettings.defaultsKey, "jobCues")
        XCTAssertEqual(CueSettings.volume(nil), 0.7)
        XCTAssertEqual(CueSettings.volume(5.0), 1)
        XCTAssertEqual(CueSettings.volume(-1.0), 0)
        XCTAssertEqual(CueSettings.gain(volume: 0.7), 0.49, accuracy: 0.001)
        XCTAssertEqual(CueSettings.gain(volume: 1), 1)
        XCTAssertEqual(CueSettings.gain(volume: 0), 0)
    }

    func testTheShuffleBagPlaysEachVariantOnceAndNeverRepeatsAcrossARefill() {
        var bag = ShuffleBag(count: 3)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let round = (0..<3).map { _ in bag.next(using: { Int.random(in: 0..<$0, using: &rng) }) }
            XCTAssertEqual(Set(round), [1, 2, 3], "each once per round")
        }
        // Across a refill the first of the next round is never the last of the one before.
        var b2 = ShuffleBag(count: 3)
        var previous = 0
        for i in 0..<60 {
            let v = b2.next(using: { _ in 0 })
            if i % 3 == 0 && i > 0 { XCTAssertNotEqual(v, previous) }
            previous = v
        }
        var one = ShuffleBag(count: 1)
        XCTAssertEqual(one.next(), 1)
        XCTAssertEqual(one.next(), 1)
    }

    func testThePlanChecksTheSwitchThenOurOwnVoiceThenTheQuietCheck() {
        var read = 0
        let calm = { () -> QuietSignals in read += 1; return QuietSignals() }
        XCTAssertEqual(CuePlan.plan(.done, switchOn: false, benjiSpeaking: false, signals: calm), .skipped(.off))
        XCTAssertEqual(read, 0, "an off switch reads nothing")
        XCTAssertEqual(CuePlan.plan(.done, switchOn: true, benjiSpeaking: true, signals: calm), .skipped(.benjiSpeaking))
        XCTAssertEqual(read, 0)
        XCTAssertEqual(CuePlan.plan(.done, switchOn: true, benjiSpeaking: false, signals: calm), .play(.done))
        XCTAssertEqual(CuePlan.plan(.needsApproval, switchOn: true, benjiSpeaking: false, signals: calm), .play(.approval))
        XCTAssertEqual(CuePlan.plan(.error, switchOn: true, benjiSpeaking: false, signals: calm), .play(.error))
        let onCall = { QuietSignals(microphoneUsers: ["us.zoom.xos"]) }
        XCTAssertEqual(CuePlan.plan(.done, switchOn: true, benjiSpeaking: false, signals: onCall), .skipped(.quiet(.microphoneInCall)))
        let recording = { QuietSignals(microphoneUsers: ["com.apple.garageband10"]) }
        XCTAssertEqual(CuePlan.plan(.done, switchOn: true, benjiSpeaking: false, signals: recording), .play(.done), "recording is not a call")
    }

    func testNoDrawingSounds() {
        // Five cues, none for drawing, pointing or working.
        XCTAssertEqual(Set(CueID.allCases.map(\.rawValue)), ["listening-on", "listening-off", "done", "approval", "error"])
    }
}
