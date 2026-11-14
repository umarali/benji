import XCTest
@testable import BenjiCore

/// D-175: the app's twin of benji/home.py. The cases are the same table the engine's selftest runs
/// (Tests/home-migration-cases.json); every one builds a throwaway home folder, so nothing here looks
/// at the real one.
final class HomeMigrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("benji-home-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        WorkingFolder.useForThisRun(nil)
    }

    private func build(_ spec: [String: Any], in home: URL) throws {
        let fm = FileManager.default
        for d in spec["dirs"] as? [String] ?? [] {
            try fm.createDirectory(at: home.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        for (rel, text) in spec["files"] as? [String: String] ?? [:] {
            let url = home.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        for (rel, target) in spec["links"] as? [String: String] ?? [:] {
            let url = home.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: url.path, withDestinationPath: home.appendingPathComponent(target).path)
        }
    }

    private func lexists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    func testTheSharedCasesBehaveAsTheEnginesDo() throws {
        let cases = try XCTUnwrap(try LoggingTests.fixture("home-migration-cases.json")["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        var ran = 0
        for c in cases where (c["python_only"] as? Bool) != true {
            let name = c["name"] as! String
            let home = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try build(c["before"] as? [String: Any] ?? [:], in: home)
            var env: [String: String] = [:]
            if let w = c["workdir_env"] as? String { env[c["workdir_name"] as? String ?? "BENJI_WORKDIR"] = root.appendingPathComponent(w).path }
            var kinds: [HomeMigration.Kind] = [], notices: [Bool] = []
            for n in 0..<(c["runs"] as? Int ?? 1) {
                let fake = (c["others"] as? [Int])?.map { Int32($0) } ?? []
                let out = HomeMigration.run(environment: env, home: home, today: "2026-11-08", others: { _ in fake })
                kinds.append(out.kind)
                notices.append(out.notice != nil)
                if n == 0, let after = c["afterFirstRun"] as? [String: Any] { try build(after, in: home) }
            }
            XCTAssertEqual(kinds[0].rawValue, c["kind"] as? String, name)
            XCTAssertEqual(notices[0], c["notice"] as? Bool, name)
            if kinds.count > 1 {
                XCTAssertEqual(kinds[1].rawValue, c["secondKind"] as? String, name)
                XCTAssertEqual(notices[1], c["secondNotice"] as? Bool ?? false, name)
            }
            if kinds.count > 2 { XCTAssertEqual(kinds[2].rawValue, c["thirdKind"] as? String, name) }
            for p in c["exist"] as? [String] ?? [] { XCTAssertTrue(lexists(home.appendingPathComponent(p)), "\(name): \(p) should exist") }
            for p in c["absent"] as? [String] ?? [] { XCTAssertFalse(lexists(home.appendingPathComponent(p)), "\(name): \(p) should be gone") }
            for (p, text) in c["content"] as? [String: String] ?? [:] {
                XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(p), encoding: .utf8), text, "\(name): \(p)")
            }
            if let kind = c["marker"] as? String {
                let data = try Data(contentsOf: home.appendingPathComponent(".benji/benji_migrated_from"))
                let marker = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: String])
                XCTAssertEqual(marker["kind"], kind, name)
                XCTAssertEqual(Set(marker.keys), ["kind", "from", "date"], "\(name): the marker holds the kind, the source and the date only")
                if let from = c["markerFrom"] as? String { XCTAssertEqual(marker["from"], from, name) }
            }
            if c["mode700"] as? Bool == true {
                let mode = (try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".benji").path)[.posixPermissions] as? Int) ?? 0
                XCTAssertEqual(mode & 0o777, 0o700, name)
            }
            ran += 1
        }
        XCTAssertGreaterThanOrEqual(ran, 10)
    }

    private struct Entry: Equatable { var kind: String; var mode: Int; var content: Data?; var target: String? }

    private func snapshot(_ root: URL) throws -> [String: Entry] {
        let fm = FileManager.default
        var out: [String: Entry] = [:]
        for rel in try fm.subpathsOfDirectory(atPath: root.path) {
            let path = root.appendingPathComponent(rel).path
            let attrs = try fm.attributesOfItem(atPath: path)
            let type = attrs[.type] as? FileAttributeType
            let mode = (attrs[.posixPermissions] as? Int ?? 0) & 0o777
            if type == .typeSymbolicLink {
                out[rel] = Entry(kind: "l", mode: 0, content: nil, target: try fm.destinationOfSymbolicLink(atPath: path))
            } else if type == .typeDirectory {
                out[rel] = Entry(kind: "d", mode: mode, content: nil, target: nil)
            } else {
                out[rel] = Entry(kind: "f", mode: mode, content: try Data(contentsOf: URL(fileURLWithPath: path)), target: nil)
            }
        }
        return out
    }

    func testAPopulatedFolderMovesWholeWithTheSameModesAndNoCopy() throws {
        let fm = FileManager.default
        let home = root.appendingPathComponent("populated")
        let old = home.appendingPathComponent(".chilly")
        let jid = "3f2a9c1e-5b7d-4e8f-9a0b-1c2d3e4f5a6b"
        let files: [(String, Int, String)] = [
            ("answers.jsonl", 0o600, "a"), ("policy.json", 0o644, "{}"), ("events.jsonl", 0o600, "e"), ("engine.log", 0o600, "l"),
            ("voice.log", 0o600, "v"), ("latency.jsonl", 0o600, "t"), ("memory.jsonl", 0o600, "m"), (".hidden", 0o644, "h"),
            ("jobs/\(jid)/job.json", 0o600, "{}"), ("jobs/\(jid)/report.md", 0o644, "r"), ("jobs/\(jid)/output/a/b/deep.txt", 0o600, "d"),
            ("jobs/\(jid).schedule.json", 0o600, "{}"), ("skills/mine/SKILL.md", 0o644, "s"), ("notes/n.md", 0o600, "n"),
            ("conversations/c.json", 0o600, "{}"), ("output/old.txt", 0o644, "o"), ("tmp/x", 0o644, "x"),
            ("voices/kokoro-v1.0.onnx", 0o644, "MODEL"), ("voice-venv/bin/python3.12", 0o755, "PY"),
        ]
        for (rel, mode, text) in files {
            let url = old.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: old.appendingPathComponent("notes").path)
        try fm.createSymbolicLink(atPath: old.appendingPathComponent("link").path, withDestinationPath: "answers.jsonl")
        try fm.createSymbolicLink(atPath: old.appendingPathComponent("voice-venv/bin/python3").path, withDestinationPath: "python3.12")
        try fm.createSymbolicLink(atPath: old.appendingPathComponent("dangling").path, withDestinationPath: home.appendingPathComponent("nowhere").path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: old.path)
        let before = try snapshot(old)
        var st = stat(); XCTAssertEqual(stat(old.appendingPathComponent("answers.jsonl").path, &st), 0)
        let inode = st.st_ino
        let out = HomeMigration.run(environment: [:], home: home, today: "2026-11-08", others: { _ in [] })
        XCTAssertEqual(out.kind, .renamed)
        XCTAssertFalse(lexists(old), "~/benji no longer exists")
        var after = try snapshot(home.appendingPathComponent(".benji"))
        XCTAssertNotNil(after.removeValue(forKey: HomeMigration.markerName))
        XCTAssertEqual(Set(after.keys), Set(before.keys), "nothing missing, nothing extra")
        for (k, v) in before { XCTAssertEqual(after[k], v, k) }
        var st2 = stat(); XCTAssertEqual(stat(home.appendingPathComponent(".benji/answers.jsonl").path, &st2), 0)
        XCTAssertEqual(st2.st_ino, inode, "a rename, not a copy")
        let top = (try fm.attributesOfItem(atPath: home.appendingPathComponent(".benji").path)[.posixPermissions] as? Int ?? 0) & 0o777
        XCTAssertEqual(top, 0o700)
        // the voice paths follow the one function
        let install = KokoroInstall(dataDir: WorkingFolder.url(environment: [:], home: home).path)
        XCTAssertEqual(install.python, home.appendingPathComponent(".benji/voice-venv/bin/python3").path)
        XCTAssertEqual(install.voicesDir, home.appendingPathComponent(".benji/voices").path)
        XCTAssertTrue(install.isInstalled(fileExists: { fm.fileExists(atPath: $0) }) == false)   // no voices-v1.0.bin in the fixture: not "installed"
        XCTAssertTrue(fm.fileExists(atPath: install.python))
    }

    func testAnotherRunningBenjiStopsTheMoveWithOnePlainLine() throws {
        let home = root.appendingPathComponent("busy")
        try build(["files": [".chilly/answers.jsonl": "A"]], in: home)
        let out = HomeMigration.run(environment: [:], home: home, today: "2026-11-08", others: { _ in [4242] })
        XCTAssertEqual(out.kind, .busy)
        XCTAssertEqual(out.notice, HomeMigration.noticeBusy(".chilly"))
        XCTAssertFalse(HomeMigration.noticeBusy(".chilly").contains("\n"))
        XCTAssertEqual(WorkingFolder.url(environment: [:], home: home).lastPathComponent, ".chilly")
        XCTAssertTrue(lexists(home.appendingPathComponent(".chilly/answers.jsonl")))
        XCTAssertFalse(lexists(home.appendingPathComponent(".benji")))
    }

    func testTheRealProcessCheckSeesOnlyBenjiProcessesOfThisHome() throws {
        // ps shows the environment of an ordinary program, not of a system one (/usr/bin, /bin): so the
        // stand-in engine is a python3 from outside the system folders, and the test skips where there is none.
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        guard let python = dirs.map({ URL(fileURLWithPath: $0).appendingPathComponent("python3").resolvingSymlinksInPath().path })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) && !$0.hasPrefix("/usr/bin") && !$0.hasPrefix("/bin")
                && !$0.hasPrefix("/Library/Developer") && !$0.hasPrefix("/Applications/Xcode")
                // A version-manager shim (pyenv, asdf) runs through helper scripts whose environment `ps -E`
                // can't show for a moment, and the check rightly counts those as "maybe this home".
                && !$0.contains("/shims/") }) else {
            throw XCTSkip("no python3 outside the system folders to stand in for an engine")
        }
        let mine = Process(), other = Process()
        for (p, home) in [(mine, root.path), (other, root.path + "-elsewhere")] {
            p.executableURL = URL(fileURLWithPath: python)
            p.arguments = ["-c", "import time; time.sleep(60)", "-m", "benji", "--serve"]
            p.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
            try p.run()
        }
        defer { mine.terminate(); other.terminate() }
        var seen: [Int32] = []
        for _ in 0..<50 {       // the processes need a moment to start, longer on a busy machine
            Thread.sleep(forTimeInterval: 0.2)
            seen = HomeMigration.otherProcesses(home: root)
            if seen.contains(mine.processIdentifier) { break }
        }
        Thread.sleep(forTimeInterval: 0.3)
        seen = HomeMigration.otherProcesses(home: root)
        XCTAssertTrue(seen.contains(mine.processIdentifier))
        XCTAssertFalse(seen.contains(other.processIdentifier))
    }

    func testAFailedRenameKeepsTheOldFolderForThisRunAndMovesNothing() throws {
        // ~/.chilly cannot be renamed when its parent cannot be written: a read-only home.
        let home = root.appendingPathComponent("home")
        try build(["files": [".chilly/answers.jsonl": "A"]], in: home)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path) }
        guard access(home.path, W_OK) != 0 else { throw XCTSkip("running with rights that ignore a read-only folder") }
        let out = HomeMigration.run(environment: [:], home: home, today: "2026-11-08", others: { _ in [] })
        XCTAssertEqual(out.kind, .failed)
        XCTAssertEqual(out.notice, HomeMigration.noticeFailed(".chilly"))
        XCTAssertEqual(WorkingFolder.url(environment: [:], home: home).lastPathComponent, ".chilly")
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".chilly/answers.jsonl"), encoding: .utf8), "A")
        XCTAssertFalse(lexists(home.appendingPathComponent(".benji")))
    }

    func testEnsureHomeMakesAPrivateFolderOnlyWhenNothingIsThere() throws {
        let home = root.appendingPathComponent("fresh")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        HomeMigration.ensureHome(environment: [:], home: home)
        let mode = (try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".benji").path)[.posixPermissions] as? Int) ?? 0
        XCTAssertEqual(mode & 0o777, 0o700)
        // An override means no ~/.benji is made; an existing folder keeps its mode.
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        HomeMigration.ensureHome(environment: ["BENJI_WORKDIR": "/tmp/x"], home: other)
        XCTAssertFalse(lexists(other.appendingPathComponent(".benji")))
        let kept = root.appendingPathComponent("kept")
        try FileManager.default.createDirectory(at: kept.appendingPathComponent(".benji"), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        HomeMigration.ensureHome(environment: [:], home: kept)
        let keptMode = (try FileManager.default.attributesOfItem(atPath: kept.appendingPathComponent(".benji").path)[.posixPermissions] as? Int) ?? 0
        XCTAssertEqual(keptMode & 0o777, 0o755)
    }

    func testTheWorkingFolderIsOneRuleEverywhere() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(WorkingFolder.url(environment: [:], home: home).path, "/Users/someone/.benji")
        XCTAssertEqual(WorkingFolder.url(environment: ["BENJI_WORKDIR": "/tmp/w"], home: home).path, "/tmp/w")
        XCTAssertEqual(ProfileMemory.standardURL(home: home, environment: [:]).path, "/Users/someone/.benji/memory.jsonl")
        XCTAssertEqual(ProfileMemory.standardURL(home: home, environment: ["BENJI_WORKDIR": "/tmp/w"]).path, "/tmp/w/memory.jsonl")
        XCTAssertEqual(ConversationStore.standard(home: home, environment: [:]).directory.path, "/Users/someone/.benji/conversations")
        XCTAssertEqual(ConversationStore.standard(home: home, environment: ["BENJI_WORKDIR": "/tmp/w"]).directory.path, "/tmp/w/conversations")
        XCTAssertEqual(KokoroInstall.dataDir(environment: ["BENJI_WORKDIR": "/tmp/w"]), "/tmp/w")
        XCTAssertEqual(KokoroInstall(dataDir: KokoroInstall.dataDir(environment: [:])).voicesDir.hasSuffix("/.benji/voices"), true)
    }

    func testNoSourceFileInTheAppBuildsALooseBenjiPath() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var offenders: [String] = []
        let it = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        for case let url as URL in it ?? FileManager.default.enumerator(atPath: "/dev/null")! {
            guard url.pathExtension == "swift", url.lastPathComponent != "HomeMigration.swift" else { continue }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("~/.chilly") || line.contains("~/chilly") || line.contains("appendingPathComponent(\".chilly\")") {
                offenders.append("\(url.lastPathComponent):\(n + 1)")
            }
        }
        XCTAssertEqual(offenders, [], "only HomeMigration names the old folder")
    }

    func testTheNoticesAreOnePlainLineEach() {
        for line in [HomeMigration.noticeMoved(".chilly"), HomeMigration.noticeLeftOld(".chilly"), HomeMigration.noticeFailed(".chilly")] {
            XCTAssertFalse(line.contains("\n"))
            XCTAssertLessThan(line.count, 125)
        }
        XCTAssertEqual(HomeMigration.noticeLeftOld(".chilly"), "An older ~/.chilly folder still has files in it. Benji is using ~/.benji; nothing was merged or changed.")
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
}
