import XCTest
@testable import BenjiCore

final class KokoroSupportTests: XCTestCase {
    func testEngineUsesKokoroOnlyWhenInstalled() {
        XCTAssertEqual(SpeechEngine.resolve(setting: nil, kokoroInstalled: true), .kokoro)
        XCTAssertEqual(SpeechEngine.resolve(setting: nil, kokoroInstalled: false), .system)
        XCTAssertEqual(SpeechEngine.resolve(setting: "kokoro", kokoroInstalled: false), .system)
        XCTAssertEqual(SpeechEngine.resolve(setting: "Kokoro", kokoroInstalled: true), .kokoro)
        XCTAssertEqual(SpeechEngine.resolve(setting: "system", kokoroInstalled: true), .system)
        XCTAssertEqual(SpeechEngine.resolve(setting: "apple", kokoroInstalled: true), .system)
    }

    func testInstallNeedsPythonVoicesAndAModel() {
        let install = KokoroInstall(dataDir: "/data")
        XCTAssertEqual(install.python, "/data/voice-venv/bin/python3")
        XCTAssertEqual(install.voicesDir, "/data/voices")
        let full: Set = ["/data/voice-venv/bin/python3", "/data/voices/voices-v1.0.bin",
                         "/data/voices/kokoro-v1.0.onnx"]
        XCTAssertTrue(install.isInstalled { full.contains($0) })
        let int8Only = full.subtracting(["/data/voices/kokoro-v1.0.onnx"]).union(["/data/voices/kokoro-v1.0.int8.onnx"])
        XCTAssertTrue(install.isInstalled { int8Only.contains($0) })
        XCTAssertFalse(install.isInstalled { full.subtracting(["/data/voice-venv/bin/python3"]).contains($0) })
        XCTAssertFalse(install.isInstalled { full.subtracting(["/data/voices/voices-v1.0.bin"]).contains($0) })
        XCTAssertFalse(install.isInstalled { full.subtracting(["/data/voices/kokoro-v1.0.onnx"]).contains($0) })
    }

    func testDataDirFollowsWorkdirSetting() {
        XCTAssertEqual(KokoroInstall.dataDir(environment: [:]), "~/.benji")
        XCTAssertEqual(KokoroInstall.dataDir(environment: ["BENJI_WORKDIR": "/x"]), "/x")
        XCTAssertFalse(KokoroInstall(dataDir: "~/.benji").python.hasPrefix("~"))
    }

    func testVoiceAndSpeedSettings() {
        XCTAssertEqual(KokoroSettings.voice(nil), "af_heart")
        XCTAssertEqual(KokoroSettings.voice(" BM_George "), "bm_george")
        XCTAssertEqual(KokoroSettings.voice("../../etc"), "af_heart")
        XCTAssertEqual(KokoroSettings.speed(nil), 1.0)
        XCTAssertEqual(KokoroSettings.speed(5), 2.0)
        XCTAssertEqual(KokoroSettings.speed(0.1), 0.5)
        XCTAssertEqual(KokoroSettings.speed(1.2), 1.2)
    }

    func testRequestLines() throws {
        let line = KokoroRequest.speak(id: "3", text: "Hi \"there\"", voice: "af_heart", speed: 1).line()
        XCTAssertEqual(line.last, 0x0A)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "speak")
        XCTAssertEqual(obj["id"] as? String, "3")
        XCTAssertEqual(obj["text"] as? String, "Hi \"there\"")
        XCTAssertEqual(String(decoding: KokoroRequest.stop.line(), as: UTF8.self), "{\"type\":\"stop\"}\n")
    }

    func testDecodesEvents() {
        XCTAssertEqual(KokoroEvent.decode(#"{"type":"ready","sample_rate":24000,"voices":["af_heart"],"model":"kokoro-v1.0.onnx","load_ms":900}"#),
                       .ready(sampleRate: 24000, voices: ["af_heart"], model: "kokoro-v1.0.onnx"))
        let pcm = Data([0x00, 0x00, 0xFF, 0x7F])
        XCTAssertEqual(KokoroEvent.decode(#"{"type":"audio","id":"2","seq":1,"pcm16":"\#(pcm.base64EncodedString())"}"#),
                       .audio(id: "2", seq: 1, text: "", pcm16: pcm))
        XCTAssertEqual(KokoroEvent.decode(#"{"type":"done","id":"2","stopped":true}"#), .done(id: "2", stopped: true))
        XCTAssertEqual(KokoroEvent.decode(#"{"type":"error","text":"no model"}"#), .error(id: nil, text: "no model"))
        XCTAssertEqual(KokoroEvent.decode(#"{"type":"audio","id":"2","pcm16":"%%%"}"#), .unknown)
        XCTAssertEqual(KokoroEvent.decode("not json"), .unknown)
    }

    func testPCM16ToFloats() {
        let floats = KokoroEvent.floats(fromPCM16: Data([0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80, 0x01]))
        XCTAssertEqual(floats.count, 3)   // a trailing odd byte is ignored
        XCTAssertEqual(floats[0], 0)
        XCTAssertEqual(floats[1], 32767.0 / 32768, accuracy: 1e-6)
        XCTAssertEqual(floats[2], -1)
    }

    func testPlaybackSpeaksUntilEverySentenceHasPlayed() {
        var p = KokoroPlayback()
        XCTAssertFalse(p.hasStarted)
        XCTAssertTrue(p.didSchedule())        // first sentence: speaking starts
        XCTAssertFalse(p.didSchedule())
        XCTAssertFalse(p.didPlay())           // one played, one still queued
        XCTAssertFalse(p.didFinishSynthesis())
        XCTAssertTrue(p.didPlay())            // last one played after synthesis ended
    }

    func testPlaybackEndsWhenSynthesisEndsAfterTheLastSentencePlayed() {
        var p = KokoroPlayback()
        _ = p.didSchedule()
        XCTAssertFalse(p.didPlay())           // played, but more may still come
        XCTAssertTrue(p.didFinishSynthesis())
    }
}
