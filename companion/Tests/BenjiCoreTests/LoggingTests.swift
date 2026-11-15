import XCTest
@testable import BenjiCore

/// The logs Benji keeps: the app's side of events.jsonl, engine.log with its redaction, the
/// private-file rules every log shares, and the Copy diagnostics action's core. The Python side is
/// checked in selftest.py against the same two fixtures (audit-cases.json, redaction-cases.json).
final class LoggingTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("benji-logs-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    static func fixture(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(name)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func mode(_ url: URL) -> mode_t? { PrivateFile.mode(of: url).map { $0 & 0o777 } }

    // MARK: private files

    func testANewLogIsCreatedOnlyThisUserCanRead() throws {
        let url = folder.appendingPathComponent("a.log")
        try PrivateFile.append(Data("one\n".utf8), to: url)
        XCTAssertEqual(mode(url), 0o600)
        XCTAssertEqual(mode(folder), 0o700, "a folder the log made is private too")
        try PrivateFile.append(Data("two\n".utf8), to: url)
        XCTAssertEqual(try String(contentsOf: url), "one\ntwo\n")
    }

    func testAWiderExistingLogIsTightenedOnTheFirstWriteAndItsFolderIsLeftAlone() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let url = folder.appendingPathComponent("answers.jsonl")
        let old = folder.appendingPathComponent("answers.jsonl.1")
        for u in [url, old] { FileManager.default.createFile(atPath: u.path, contents: Data("x\n".utf8), attributes: [.posixPermissions: 0o644]) }
        try PrivateFile.append(Data("y\n".utf8), to: url, maxBytes: 1000, keep: 1)
        XCTAssertEqual(mode(url), 0o600)
        XCTAssertEqual(mode(old), 0o600, "the rotated copy too")
        XCTAssertEqual(mode(folder), 0o755, "the folder is never widened or narrowed")
    }

    func testRotationKeepsAFewPrivateGenerationsAndBoundsTheTotal() throws {
        let url = folder.appendingPathComponent("r.log")
        let line = Data(String(repeating: "x", count: 99).appending("\n").utf8)
        for _ in 0..<60 { try PrivateFile.append(line, to: url, maxBytes: 1000, keep: 2) }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["r.log", "r.log.1", "r.log.2"], "the oldest generation is dropped")
        for n in names {
            let u = folder.appendingPathComponent(n)
            XCTAssertEqual(mode(u), 0o600)
            XCTAssertLessThanOrEqual(try Data(contentsOf: u).count, 1000)
        }
    }

    func testASymlinkIsNotFollowed() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("target.txt")
        FileManager.default.createFile(atPath: target.path, contents: Data("t".utf8), attributes: [.posixPermissions: 0o644])
        let link = folder.appendingPathComponent("l.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try PrivateFile.append(Data("x".utf8), to: link))
        XCTAssertEqual(mode(target), 0o644, "the file behind the link is untouched")
        XCTAssertEqual(try String(contentsOf: target), "t")
    }

    // MARK: events.jsonl, the app's side

    private func event(_ spec: [String: Any]) throws -> AuditEvent {
        switch spec["case"] as? String {
        case "engineStart": return .engineStart
        case "engineExit": return .engineExit(code: Int32(spec["code"] as! Int), clean: spec["clean"] as! Bool)
        case "jobAction":
            let action = AuditEvent.JobAction(rawValue: spec["action"] as! String)!
            return .jobAction(action, job: spec["job"] as? String, approved: spec["approved"] as? Bool)
        case "browserSwitch": return .browserSwitch(enabled: spec["enabled"] as! Bool)
        case "diagnosticsCopied": return .diagnosticsCopied(ok: spec["ok"] as! Bool)
        case "error": return .error(AuditEvent.ErrorCode(rawValue: spec["code"] as! String)!)
        default: throw XCTSkip("unknown case")
        }
    }

    func testEveryAppEventHasTheFieldsTheEngineSchemaTakes() throws {
        let cases = try XCTUnwrap(Self.fixture("audit-cases.json")["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        let log = AuditLog(folder: folder, environment: [:])
        for c in cases {
            var fields = log.fields(try event(c["event"] as! [String: Any]))
            XCTAssertEqual(NSDictionary(dictionary: fields), NSDictionary(dictionary: c["fields"] as! [String: Any]), "\(c["event"]!)")
            fields["time"] = "x"
        }
    }

    func testALineIsOneJSONObjectWithATimeAndNoRoomForText() throws {
        let log = AuditLog(folder: folder, environment: [:], now: { Date(timeIntervalSince1970: 1_793_000_000) })
        let line = log.line(.jobAction(.steer, job: "3f2a9c1e-5b7d-4e8f-9a0b-1c2d3e4f5a6b", approved: nil))
        XCTAssertTrue(line.hasSuffix("\n") && line.filter { $0 == "\n" }.count == 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let time = try XCTUnwrap(object["time"] as? String)
        XCTAssertNotNil(time.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d{4}$"#, options: .regularExpression))
        XCTAssertEqual(Set(object.keys), ["time", "kind", "src", "action", "job"])
    }

    func testAppendWritesAPrivateFileAndAFailureIsQuietNotFatal() throws {
        let log = AuditLog(folder: folder, environment: [:])
        XCTAssertTrue(log.append(.browserSwitch(enabled: true)))
        XCTAssertTrue(log.append(.engineExit(code: -9, clean: false)))
        XCTAssertEqual(mode(log.url), 0o600)
        XCTAssertEqual(try String(contentsOf: log.url).split(separator: "\n").count, 2)
        // The folder is a file: the write fails, and the caller is told only "false".
        let blocked = folder.appendingPathComponent("blocked")
        FileManager.default.createFile(atPath: blocked.path, contents: nil)
        XCTAssertFalse(AuditLog(folder: blocked, environment: [:]).append(.engineStart))
    }

    func testAuditOffSwitchWritesNothing() {
        let log = AuditLog(folder: folder, environment: ["BENJI_AUDIT": "0"])
        XCTAssertFalse(log.append(.engineStart))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.url.path))
    }

    func testTheLogIsRotatedAndEveryGenerationStaysPrivate() throws {
        let log = AuditLog(folder: folder, environment: [:])
        let one = Data(log.line(.jobAction(.stop, job: nil, approved: nil)).utf8)
        let total = (AuditLog.maxBytes / one.count) * (AuditLog.keep + 2)
        for _ in 0..<total { try PrivateFile.append(one, to: log.url, maxBytes: AuditLog.maxBytes, keep: AuditLog.keep) }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["events.jsonl", "events.jsonl.1", "events.jsonl.2", "events.jsonl.3"])
        for n in names { XCTAssertEqual(mode(folder.appendingPathComponent(n)), 0o600) }
    }

    func testTheWorkingFolderFollowsTheEnginesRule() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(WorkingFolder.url(environment: [:], home: home).path, "/Users/someone/.benji")
        XCTAssertEqual(WorkingFolder.url(environment: ["BENJI_WORKDIR": "/tmp/w"], home: home).path, "/tmp/w")
        XCTAssertEqual(WorkingFolder.url(environment: ["BENJI_WORKDIR": ""], home: home).path, "/Users/someone/.benji")
        XCTAssertEqual(WorkingFolder.url(environment: ["BENJI_WORKDIR": "   "], home: home).path, "/Users/someone/.benji")
    }

    func testTheWorkingFolderIsOneRuleEverywhere() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(ProfileMemory.standardURL(home: home, environment: [:]).path, "/Users/someone/.benji/memory.jsonl")
        XCTAssertEqual(ProfileMemory.standardURL(home: home, environment: ["BENJI_WORKDIR": "/tmp/w"]).path, "/tmp/w/memory.jsonl")
        XCTAssertEqual(ConversationStore.standard(home: home, environment: [:]).directory.path, "/Users/someone/.benji/conversations")
        XCTAssertEqual(ConversationStore.standard(home: home, environment: ["BENJI_WORKDIR": "/tmp/w"]).directory.path, "/tmp/w/conversations")
        XCTAssertEqual(KokoroInstall.dataDir(environment: ["BENJI_WORKDIR": "/tmp/w"]), "/tmp/w")
        XCTAssertEqual(KokoroInstall(dataDir: KokoroInstall.dataDir(environment: [:])).voicesDir.hasSuffix("/.benji/voices"), true)
    }

    func testEnsureHomeMakesAPrivateFolderOnlyWhenNothingIsThere() throws {
        let root = folder.resolvingSymlinksInPath()
        let mode = { (url: URL) in ((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0) & 0o777 }
        let fresh = root.appendingPathComponent("fresh")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        WorkingFolder.ensureHome(environment: [:], home: fresh)
        XCTAssertEqual(try mode(fresh.appendingPathComponent(".benji")), 0o700)
        // An override means no ~/.benji is made; an existing folder keeps its mode.
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        WorkingFolder.ensureHome(environment: ["BENJI_WORKDIR": "/tmp/x"], home: other)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent(".benji").path))
        let kept = root.appendingPathComponent("kept")
        try FileManager.default.createDirectory(at: kept.appendingPathComponent(".benji"), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        WorkingFolder.ensureHome(environment: [:], home: kept)
        XCTAssertEqual(try mode(kept.appendingPathComponent(".benji")), 0o755)
        XCTAssertEqual(BenjiFolderCopy.button, "Show Benji's folder")
    }

    func testJobFolderMakesAPathOnlyFromARealJobID() {
        let jobs = URL(fileURLWithPath: "/Users/someone/.benji/jobs")
        let id = "3f2a9c1e-5b7d-4e8f-9a0b-1c2d3e4f5a6b"
        XCTAssertEqual(JobFolder.url(id: id, jobsFolder: jobs)?.path, "/Users/someone/.benji/jobs/\(id)")
        for bad in ["", "..", "../x", "a/b", "/etc", "not-a-uuid", id + "/.."] {
            XCTAssertNil(JobFolder.url(id: bad, jobsFolder: jobs), bad)
        }
        XCTAssertEqual(JobFolder.buttonTitle, "Show in Finder")
    }

    // MARK: engine.log

    func testRedactionAgreesWithThePythonSideOnEveryCase() throws {
        let cases = try XCTUnwrap(Self.fixture("redaction-cases.json")["cases"] as? [[String: String]])
        XCTAssertGreaterThanOrEqual(cases.count, 15)
        for c in cases { XCTAssertEqual(LogRedaction.redact(c["in"]!), c["out"], c["in"]!) }
    }

    func testEngineLogKeepsOnlyRedactedLinesPrivatelyAndSkipsBlankOnes() throws {
        let log = EngineLog(folder: folder, now: { Date(timeIntervalSince1970: 1_793_000_000) })
        XCTAssertFalse(log.append("   "))
        XCTAssertTrue(log.append("loaded ANTHROPIC_API_KEY=sk-ant-realkeyrealkeyrealkey from /Users/someone/.benji.env"))
        XCTAssertTrue(log.append("[Benji] approval a1 (yes): write_file/write_outside_folder"))
        let text = try String(contentsOf: log.url)
        XCTAssertFalse(text.contains("realkey") || text.contains("someone"))
        XCTAssertTrue(text.contains("ANTHROPIC_API_KEY=[redacted]") && text.contains("~/.benji.env"))
        XCTAssertEqual(text.split(separator: "\n").count, 2)
        XCTAssertEqual(mode(log.url), 0o600)
    }

    func testEngineLogIsRotatedAndBounded() throws {
        let log = EngineLog(folder: folder)
        for i in 0..<30_000 { log.append("line \(i) " + String(repeating: "yyyy ", count: 14)) }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["engine.log", "engine.log.1", "engine.log.2"])
        for n in names {
            let u = folder.appendingPathComponent(n)
            XCTAssertEqual(mode(u), 0o600)
            XCTAssertLessThanOrEqual(try Data(contentsOf: u).count, EngineLog.maxBytes)
        }
    }

    // MARK: Copy diagnostics

    func testCopyDiagnosticsPutsTheReportOnTheClipboardAndLogsOnlyThatItWasCopied() {
        var copied: [String] = [], audited: [AuditEvent] = []
        let status = DiagnosticsCopy.perform(run: { (Data("report line\nsecond\n".utf8), 0) },
                                             copy: { copied.append($0) }, audit: { audited.append($0) })
        XCTAssertEqual(status, .copied)
        XCTAssertEqual(copied, ["report line\nsecond"])
        XCTAssertEqual(audited, [.diagnosticsCopied(ok: true)])
        XCTAssertEqual(status.note, "Copied.")
    }

    func testCopyDiagnosticsFailsQuietlyWhenTheCommandFailsOrSaysNothing() {
        for result in [(Data("partial".utf8), Int32(1)), (nil, Int32(0)), (Data("  \n".utf8), Int32(0))] {
            var copied: [String] = [], audited: [AuditEvent] = []
            let status = DiagnosticsCopy.perform(run: { result }, copy: { copied.append($0) }, audit: { audited.append($0) })
            XCTAssertEqual(status, .failed)
            XCTAssertTrue(copied.isEmpty, "nothing half-made reaches the clipboard")
            XCTAssertEqual(audited, [.diagnosticsCopied(ok: false)])
        }
        XCTAssertEqual(DiagnosticsCopy.Status.failed.note, DiagnosticsCopy.failedNote)
        XCTAssertNil(DiagnosticsCopy.Status.working.note)
    }

    func testTheAppAsksTheEngineForTheLastDayOnly() {
        XCTAssertEqual(DiagnosticsCopy.command, "--diagnose --hours 24")
        XCTAssertTrue(DiagnosticsCopy.detail.contains("no message text"))
    }
}
