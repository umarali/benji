import Foundation

/// Where the `benji` Python package lives, resolved without any machine-specific default.
///
/// Order: `$BENJI_DIR` when set (`$CHILLY_DIR` too, but only if that folder really holds `benji/`, since
/// an old value names the old code); otherwise the first folder, walking up from the app bundle
/// (`companion/Benji.app` sits two levels below the repository root), from the executable
/// (`companion/.build/<config>/BenjiApp` for `swift run`) and from the working directory, that
/// holds `benji/__main__.py`. If nothing matches, the folder two levels above the bundle is
/// returned so a failure message names a real place, not a stranger's home folder.
public enum AssistantLocator {
    public static func resolve(
        environment: [String: String],
        bundleURL: URL,
        executableURL: URL?,
        currentDirectory: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        if let set = environment["BENJI_DIR"], !set.isEmpty { return set }
        func isRepoRoot(_ dir: URL) -> Bool {
            fileExists(dir.appendingPathComponent("benji/__main__.py").path)
        }
        if let old = environment["CHILLY_DIR"], !old.isEmpty, isRepoRoot(URL(fileURLWithPath: old)) { return old }
        func firstRoot(from start: URL?, levels: Int) -> URL? {
            guard var dir = start?.standardizedFileURL else { return nil }
            for _ in 0...levels {
                if isRepoRoot(dir) { return dir }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
            return nil
        }
        let starts: [(URL?, Int)] = [
            (bundleURL.deletingLastPathComponent(), 4),
            (executableURL?.deletingLastPathComponent(), 6),
            (URL(fileURLWithPath: currentDirectory), 4),
        ]
        for (start, levels) in starts {
            if let root = firstRoot(from: start, levels: levels) { return root.path }
        }
        return bundleURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
    }
}
