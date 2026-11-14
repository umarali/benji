import Foundation

/// The one-time move into Benji's hidden home, `~/.benji`, from the newest of `~/.chilly`, `~/chilly` and
/// `~/pal` that is really a store. Swift twin of `benji/home.py`: the app must not create `~/.benji` (a log
/// line, a conversation) before the move has happened, or the old store would be left behind with an empty
/// folder beside it. So the app runs this first thing (`main.swift`), before any object that writes exists.
/// Both sides are tested against `Tests/home-migration-cases.json`.
///
/// What it does, and only this:
///  - an old folder with something in it, `~/.benji` absent or empty: one atomic `rename(2)`, the new folder
///    made mode 700 (the folder itself), a marker `benji_migrated_from` with the kind, the source and the
///    date. If the rename fails nothing is copied here (the engine has the copy fallback for its own runs):
///    the app keeps using the old folder for this run (`WorkingFolder.useForThisRun`) and says so.
///  - both hold something: `~/.benji` is used, nothing is moved or merged, and one plain line says so, once per older store.
///  - an empty old folder, as an old build recreates it after the move: ignored, no conflict.
///  - another Benji or Chilly is running with this home: nothing moves, one plain line; nothing is killed.
///  - a working-folder override set, under any of its names: nothing at all.
/// It never opens a file but its own markers. Beyond the folder it touches one other name: `moveKeyFile` renames `~/.chilly.env`.
/// Settings › Benji's folder: one button that opens `~/.benji` in Finder (D-175).
public enum BenjiFolderCopy {
    public static let header = "Benji's folder"
    public static let title = "Where Benji keeps its files"
    public static let detail = "Jobs, logs, memory, conversations and answers live in one hidden folder, ~/.benji, that only you can read."
    public static let button = "Show Benji's folder"
    public static let help = "Opens ~/.benji in Finder. Nothing is changed."
    public static let footer = "Your API key is kept in the Keychain or in ~/.benji.env, and the browser link has its own private folder; neither is in ~/.benji."
}

public enum HomeMigration {
    public enum Kind: String, Sendable, Equatable {
        case none, renamed, leftOld = "left_old", failed, busy
    }

    public struct Outcome: Equatable, Sendable {
        public let kind: Kind
        /// The one plain line for the user, or nil when there is nothing to say.
        public let notice: String?
        public init(kind: Kind, notice: String? = nil) { self.kind = kind; self.notice = notice }
    }

    public static let markerName = "benji_migrated_from"
    public static let notedName = "old_folder_noted_benji"
    /// Every name this store has had, newest first.
    public static let oldNames = [WorkingFolder.legacyDirectoryName, "chilly", "pal"]
    private static let ignoredWhenEmpty: Set<String> = [".DS_Store"]
    /// What only Benji's own store holds; `~/chilly` and `~/pal` are ordinary names. (`benji.home.STORE_SIGNS`.)
    static let storeSigns = ["answers.jsonl", "policy.json", "events.jsonl", "engine.log", "memory.jsonl", "voice.log", "latency.jsonl",
                             "usage.jsonl"]
    static let notAStore = [".git", "__main__.py", "chilly/__main__.py", "benji/__main__.py", "pal/__main__.py"]

    public static func noticeMoved(_ old: String) -> String { "Benji moved its folder from ~/\(old) to ~/\(WorkingFolder.directoryName)." }
    public static func noticeLeftOld(_ old: String) -> String { "An older ~/\(old) folder still has files in it. Benji is using ~/\(WorkingFolder.directoryName); nothing was merged or changed." }
    public static func noticeBusy(_ old: String) -> String { "Chilly or Benji is already running, so Benji did not move ~/\(old) to ~/\(WorkingFolder.directoryName) yet; quit it and start Benji again." }
    public static func noticeFailed(_ old: String) -> String { "Benji could not move ~/\(old) to ~/\(WorkingFolder.directoryName), so it keeps using ~/\(old) for now." }

    @discardableResult
    public static func run(environment: [String: String] = ProcessInfo.processInfo.environment,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           today: String = HomeMigration.todayString(),
                           others: (URL) -> [Int32] = HomeMigration.otherProcesses) -> Outcome {
        if LegacyEnvironment.workingFolderOverride(environment) != nil { return Outcome(kind: .none) }
        let newPath = home.appendingPathComponent(WorkingFolder.directoryName).path
        MigrationGuard.enforce(paths: [newPath] + oldNames.map { home.appendingPathComponent($0).path })
        let stores = oldNames.filter { isStore(home.appendingPathComponent($0).path, name: $0) }
        guard let label = stores.first else { return Outcome(kind: .none) }   // no old store, or only an empty folder an old build made again
        let old = home.appendingPathComponent(label).path
        func keepOld(_ kind: Kind, _ notice: String) -> Outcome {
            WorkingFolder.useForThisRun(URL(fileURLWithPath: old))
            return Outcome(kind: kind, notice: notice)
        }

        var newIsEmpty = false
        if exists(newPath) {
            guard isFolder(newPath) else { return keepOld(.failed, noticeFailed(label)) }
            if holdsSomething(newPath) {
                for other in stores where !exists(newPath + "/" + notedName + "-" + other) {     // each older store, once
                    create(newPath + "/" + notedName + "-" + other, text: today + "\n")
                    if !exists(newPath + "/" + markerName) { writeMarker(in: newPath, kind: .leftOld, source: other, today: today) }
                    return Outcome(kind: .leftOld, notice: noticeLeftOld(other))
                }
                return Outcome(kind: .none)
            }
            newIsEmpty = true
        }
        if !others(home).isEmpty {
            // Another Benji or Chilly engine or app holds the folder: a move under it could lose a write.
            return keepOld(.busy, noticeBusy(label))
        }
        if newIsEmpty, !clearEmpty(newPath) { return keepOld(.failed, noticeFailed(label)) }
        guard rename(old, newPath) == 0 else {
            if !exists(old) && exists(newPath) { return Outcome(kind: .none) }   // another process finished this move
            return keepOld(.failed, noticeFailed(label))
        }
        if !isLink(newPath) { chmod(newPath, 0o700) }       // the folder itself only; a link's target is left alone
        writeMarker(in: newPath, kind: .renamed, source: label, today: today)
        return Outcome(kind: .renamed, notice: noticeMoved(label))
    }

    public enum KeyFileMove: Equatable, Sendable { case none, renamed, busy, failed }

    /// Renames `~/.chilly.env` to `~/.benji.env` once, losing nothing. Twin of `benji.home.migrate_key_file`:
    /// link then unlink (a rename could replace a new file), so the same file, its contents and its private mode
    /// are kept and no second copy of a key is made. If `~/.benji.env` exists both stay. Any failure leaves the
    /// old file, which is still read.
    @discardableResult
    public static func moveKeyFile(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   others: (URL) -> [Int32] = HomeMigration.otherProcesses) -> KeyFileMove {
        if LegacyEnvironment.workingFolderOverride(environment) != nil { return .none }     // the same rule as the data
        let old = home.appendingPathComponent(".chilly.env").path, new = home.appendingPathComponent(".benji.env").path
        MigrationGuard.enforce(paths: [old, new])
        var st = stat()
        guard lstat(old, &st) == 0 else { return .none }
        let type = st.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFLNK else { return .none }
        var other = stat()
        let halfDone = lstat(new, &other) == 0                  // a run stopped between link and unlink: two names for one file
        if halfDone, other.st_dev != st.st_dev || other.st_ino != st.st_ino { return .none }
        guard others(home).isEmpty else { return .busy }
        if !halfDone, linkat(AT_FDCWD, old, AT_FDCWD, new, 0) != 0 { return .failed }
        return unlink(old) == 0 ? .renamed : .failed
    }

    /// Answer when the process check itself could not run: a move that can't prove it is alone doesn't happen.
    public static let processCheckFailed: Int32 = -1

    /// Process ids of other Benji or Chilly engines (`... -m benji ...`, `-m chilly`) or apps of this user
    /// that run with this home folder (`ps -E` shows each process's HOME; one from another home, such as
    /// a test's, does not count).
    public static func otherProcesses(home: URL) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-E", "-ww", "-U", String(getuid()), "-o", "pid=,command="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [processCheckFailed] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [processCheckFailed] }
        let me = ProcessInfo.processInfo.processIdentifier, parent = getppid()
        let engine = try? NSRegularExpression(pattern: "(^|\\s)-m\\s+(benji|chilly|pal)(\\s|$)")
        let app = try? NSRegularExpression(pattern: "/(Benji|Chilly|PalCompanion|PalBar)\\.app/Contents/MacOS/|/\\.build/\\S*/(BenjiApp|ChillyApp|PalCompanion)(\\s|$)")
        var found: [Int32] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]), pid != me, pid != parent else { continue }
            let command = String(trimmed[trimmed.index(after: space)...])
            let range = NSRange(command.startIndex..., in: command)
            guard engine?.firstMatch(in: command, range: range) != nil || app?.firstMatch(in: command, range: range) != nil else { continue }
            if (command + " ").contains(" HOME=\(home.path) ") || !command.contains(" HOME=") { found.append(pid) }
        }
        return found
    }

    /// Makes `~/.benji` mode 700 if nothing is there (and no override is set), so the engine, which is
    /// told this folder through BENJI_WORKDIR, finds it already private. A folder that exists is left as it
    /// is. Not while this run is using an old folder: that would make an empty profile beside the real one.
    public static func ensureHome(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        if LegacyEnvironment.workingFolderOverride(environment) != nil || WorkingFolder.runFolderURL != nil { return }
        let new = home.appendingPathComponent(WorkingFolder.directoryName).path
        if !exists(new) { _ = mkdir(new, 0o700) }
    }

    public static func todayString(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: small file helpers (lstat/stat)

    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    private static func isFolder(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isLink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// Whether this old name really is Benji's: `benji.home._is_store`.
    private static func isStore(_ path: String, name: String) -> Bool {
        guard isFolder(path), holdsSomething(path) else { return false }
        if name == oldNames[0] { return true }
        return !notAStore.contains { exists(path + "/" + $0) } && storeSigns.contains { exists(path + "/" + $0) }
    }

    /// A folder with anything in it but Finder's own note. Unreadable counts as holding something.
    private static func holdsSomething(_ path: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return true }
        return !Set(names).subtracting(ignoredWhenEmpty).isEmpty
    }

    /// Takes away a `~/.benji` that holds nothing, so a real store can move in.
    private static func clearEmpty(_ path: String) -> Bool {
        guard !isLink(path) else { return false }
        for name in ignoredWhenEmpty where exists(path + "/" + name) { unlink(path + "/" + name) }
        return rmdir(path) == 0
    }

    /// A new file, mode 600, only if it is not there already; never follows a link.
    private static func create(_ path: String, text: String) {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }

    private static func writeMarker(in folder: String, kind: Kind, source: String, today: String) {
        create(folder + "/" + markerName, text: "{\"kind\": \"\(kind.rawValue)\", \"from\": \"\(source)\", \"date\": \"\(today)\"}\n")
    }
}

/// Stops dead if a test is about to migrate something inside the owner's real home. Active when
/// `BENJI_MIGRATION_GUARD=abort` is set (the test harness sets it) or XCTest is loaded; a real run moves the
/// real folder, which is the point. The real home comes from the account record, which `HOME` can't change.
public enum MigrationGuard {
    public static let variable = "BENJI_MIGRATION_GUARD"
    public static let exitCode: Int32 = 96

    public static var accountHome: String {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return "/nonexistent-account-home" }
        return String(cString: dir)
    }

    public static var isActive: Bool {
        ProcessInfo.processInfo.environment[variable] == "abort" || NSClassFromString("XCTestCase") != nil
    }

    /// The first path that resolves to, or inside, the real home; nil when none does.
    public static func violation(paths: [String], realHome: String) -> String? {
        let real = resolved(realHome)
        return paths.map(resolved).first { $0 == real || $0.hasPrefix(real + "/") }
    }

    /// Links resolved as far as the path exists; the rest is added back, so a folder that isn't there yet
    /// behind a link into the real home still counts as being in it.
    private static func resolved(_ path: String) -> String {
        var existing = path
        var rest: [String] = []
        while true {
            if let real = realpath(existing, nil) {
                defer { free(real) }
                return ([String(cString: real)] + rest).joined(separator: "/")
            }
            let parent = (existing as NSString).deletingLastPathComponent
            if parent == existing || parent.isEmpty { return path }
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = parent
        }
    }

    public static func enforce(paths: [String]) {
        guard isActive, let path = violation(paths: paths, realHome: accountHome) else { return }
        FileHandle.standardError.write(Data("BenjiCore: refusing to migrate under the real home: \(path)\n".utf8))
        exit(exitCode)
    }
}

/// The names Benji's settings have had: BENJI_* now, CHILLY_* and PAL_* from before the renames. Twin of
/// `benji/aliases.py`. `apply()` runs first in `main.swift`, so everything later reads only BENJI_* and the
/// engine inherits them.
public enum LegacyEnvironment {
    public static let prefixes = ["CHILLY_", "PAL_"]        // the order they win in
    /// `BENJI_DIR` names where the code is, and an old value names the old code: see `AssistantLocator`.
    static let notAdopted: Set<String> = ["CHILLY_DIR", "PAL_DIR"]

    /// The variables to add: each older name's BENJI_* twin, unless that is already set.
    public static func additions(_ environment: [String: String]) -> [String: String] {
        var added: [String: String] = [:]
        for prefix in prefixes {
            for (key, value) in environment where key.hasPrefix(prefix) && !notAdopted.contains(key) {
                let name = "BENJI_" + key.dropFirst(prefix.count)
                if environment[name] == nil && added[name] == nil { added[name] = value }
            }
        }
        return added
    }

    public static func apply() {
        for (name, value) in additions(ProcessInfo.processInfo.environment) { setenv(name, value, 0) }
    }

    /// The explicit working folder, newest name first; nil for none. (`benji.home.workdir_override`.)
    public static func workingFolderOverride(_ environment: [String: String]) -> String? {
        for name in ["BENJI_WORKDIR", "CHILLY_WORKDIR", "PAL_WORKDIR"] {
            if let value = environment[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty { return value }
        }
        return nil
    }
}
