import Foundation

// What Benji remembers about the user: `~/.benji/memory.jsonl`, one fact per line
// ({"ts": …, "text": "…", "tags": […]}), written by the engine's `remember` tool
// (benji/memory.py) and shown to the model as background. Settings › Memory lists the facts and
// lets the user change or forget each one. Edits rewrite the file with every other line as it
// was; a line is changed only while it still says what the user saw.

/// One remembered fact, as the settings page lists it.
public struct ProfileFact: Equatable, Identifiable, Sendable {
    /// Its line in the file (0-based), which the engine never reorders: it only appends.
    public let line: Int
    public let text: String
    public var id: Int { line }

    public init(line: Int, text: String) {
        self.line = line
        self.text = text
    }
}

public enum ProfileMemory {
    /// The facts in the file's text, oldest first; blank, broken or text-less lines are skipped.
    public static func facts(in contents: String) -> [ProfileFact] {
        lines(contents).enumerated().compactMap { i, line in
            text(of: line).map { ProfileFact(line: i, text: $0) }
        }
    }

    /// The file without `fact`, or nil when that line no longer holds it (changed underneath).
    public static func removing(_ fact: ProfileFact, from contents: String) -> String? {
        var all = lines(contents)
        guard all.indices.contains(fact.line), text(of: all[fact.line]) == fact.text else { return nil }
        all.remove(at: fact.line)
        return joined(all)
    }

    /// The file with `fact` saying `newText` instead (its other fields kept), or nil when that
    /// line no longer holds it. Empty text forgets the fact.
    public static func replacing(_ fact: ProfileFact, with newText: String, in contents: String) -> String? {
        let t = newText.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return removing(fact, from: contents) }
        var all = lines(contents)
        guard all.indices.contains(fact.line), text(of: all[fact.line]) == fact.text,
              var object = (try? JSONSerialization.jsonObject(with: Data(all[fact.line].utf8))) as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: { object["text"] = t; return object }(),
                                                     options: [.sortedKeys, .withoutEscapingSlashes]),
              let line = String(data: data, encoding: .utf8) else { return nil }
        all[fact.line] = line
        return joined(all)
    }

    // MARK: the file

    /// `~/.benji/memory.jsonl` (under `BENJI_WORKDIR` when that is set).
    public static func standardURL(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        WorkingFolder.url(environment: environment, home: home).appendingPathComponent("memory.jsonl")
    }

    public static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Replaces the file in one step, readable by this user only. Empty contents remove it.
    public static func write(_ contents: String, to url: URL) throws {
        let fm = FileManager.default
        if contents.isEmpty {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            return
        }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".memory.\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: Data(contents.utf8), attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        if rename(temp.path, url.path) != 0 {
            try? fm.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    // MARK: lines

    private static func lines(_ contents: String) -> [String] {
        var all = contents.components(separatedBy: "\n")
        if all.last == "" { all.removeLast() }
        return all
    }

    private static func joined(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private static func text(of line: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}
