import Foundation
import CryptoKit
import Darwin

/// One process description for all engine entry points. Distribution identity is compiled in.
public struct EngineLaunch {
    public enum Entry: String { case engine, remote, modelSetup = "model-setup", nativeHost = "native-host", tts }
    public static var isDistribution: Bool {
        #if BENJI_DISTRIBUTION
        return true
        #else
        return false
        #endif
    }
    public static let toolPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    public let executable: URL
    public let arguments: [String]
    public let directory: URL
    public let environment: [String: String]

    public enum LaunchError: LocalizedError {
        case invalidBundle
        public var errorDescription: String? { "Benji's bundled engine is missing or damaged. Replace the app with a complete copy." }
    }
    private struct Manifest: Decodable {
        let schema: Int
        let architecture: String
        let python: String
        let files: [String: String]
    }
    public static func engineDirectory(bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Contents/Resources/engine", isDirectory: true)
    }
    // Full listed-file validation belongs to bootstrap, in the child process. This small
    // launch check protects the bootstrap before invoking it and rejects incomplete copies.
    // Neither check replaces the owner's release signing or authenticates a modified app.
    private static let validationLock = NSLock()
    private static var validatedKey: String?
    private static func validate(_ bundle: URL) throws {
        validationLock.lock()
        defer { validationLock.unlock() }
        do {
            let root = bundle.resolvingSymlinksInPath()
            let data = try Data(contentsOf: root.appendingPathComponent("Contents/Resources/distribution.json"))
            let m = try JSONDecoder().decode(Manifest.self, from: data)
            guard m.schema == 1, m.architecture == "arm64", m.python == "3.12.16", !m.files.isEmpty else { throw LaunchError.invalidBundle }
            let required = ["Contents/Frameworks/BenjiPython.framework/Versions/A/BenjiPython",
                            "Contents/Frameworks/BenjiPython.framework/Versions/A/bin/python3.12",
                            "Contents/Resources/engine/bootstrap.py", "Contents/Resources/engine/benji/__main__.py",
                            "Contents/Resources/trust/cacert.pem", "Contents/Resources/engine/browser-extension/manifest.json",
                            "Contents/Resources/engine/skills/SKILLS.sha256.json"]
            var key = root.path + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            for path in required {
                let file = root.appendingPathComponent(path).resolvingSymlinksInPath()
                var info = stat()
                guard let digest = m.files[path], digest.count == 64,
                      file.path.hasPrefix(root.path + "/"), stat(file.path, &info) == 0,
                      (info.st_mode & S_IFMT) == S_IFREG else { throw LaunchError.invalidBundle }
                key += ":\(file.path):\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
            }
            if validatedKey == key { return }
            let bootstrap = root.appendingPathComponent("Contents/Resources/engine/bootstrap.py")
            let handle = try FileHandle(forReadingFrom: bootstrap)
            defer { try? handle.close() }
            var hash = SHA256()
            while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == m.files["Contents/Resources/engine/bootstrap.py"] else { throw LaunchError.invalidBundle }
            validatedKey = key  // Cache successes only. Every launch still checks current file identities.
        } catch {
            validatedKey = nil
            throw LaunchError.invalidBundle
        }
    }
    public static func make(entry: Entry, arguments: [String] = [], sourceDirectory: String,
                            environment: [String: String], bundleURL: URL = Bundle.main.bundleURL,
                            optionalPython: String? = nil) throws -> EngineLaunch {
        var env = environment
        if isDistribution {
            try validate(bundleURL)
            let root = engineDirectory(bundleURL: bundleURL)
            let python = bundleURL.appendingPathComponent("Contents/Frameworks/BenjiPython.framework/Versions/A/bin/python3.12")
            for key in Array(env.keys) where key.hasPrefix("PYTHON") { env.removeValue(forKey: key) }
            env.removeValue(forKey: "BENJI_DIR")
            env.removeValue(forKey: "BENJI_PHONE_DIR")
            env["PATH"] = toolPath
            // Explicit user CA selection is validated by the shared in-process TLS function.
            env["BENJI_TLS_CA_FILE"] = env["BENJI_TLS_CA_FILE"] ?? bundleURL.appendingPathComponent("Contents/Resources/trust/cacert.pem").path
            return EngineLaunch(executable: (entry == .tts ? optionalPython : nil).map { URL(fileURLWithPath: $0) } ?? python,
                arguments: ["-I", "-B", "-u", root.appendingPathComponent("bootstrap.py").path, entry.rawValue] + arguments,
                directory: root, environment: env)
        }
        let root = URL(fileURLWithPath: sourceDirectory)
        if entry == .tts {
            guard let optionalPython else { throw LaunchError.invalidBundle }
            env["PYTHONUNBUFFERED"] = "1"
            return EngineLaunch(executable: URL(fileURLWithPath: optionalPython), arguments: ["-m", "benji", "--tts"] + arguments,
                                directory: root, environment: env)
        }
        if entry == .nativeHost {
            return EngineLaunch(executable: URL(fileURLWithPath: "/usr/bin/env"),
                                arguments: ["python3", "-I", root.appendingPathComponent("benji/browser_host.py").path] + arguments,
                                directory: root, environment: env)
        }
        env["BENJI_DIR"] = sourceDirectory
        env["PYTHONUNBUFFERED"] = "1"
        let command: String
        switch entry {
        case .modelSetup: command = "python3 -c 'from benji.model_setup import model_setup_main; model_setup_main()'"
        case .remote: command = "python3 -m benji.remote"
        default: command = "python3 -m benji"
        }
        return EngineLaunch(executable: URL(fileURLWithPath: "/bin/zsh"),
                            arguments: ["-lc", "cd \"$BENJI_DIR\" && exec " + command + " \"$@\"", "benji"] + arguments,
                            directory: root, environment: env)
    }
    public func apply(to process: Process) {
        process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = directory; process.environment = environment
    }
    public static func configure(_ process: Process, entry: Entry = .engine, arguments: [String] = [],
                                 sourceDirectory: String, environment: [String: String], optionalPython: String? = nil) throws {
        try make(entry: entry, arguments: arguments, sourceDirectory: sourceDirectory,
                 environment: environment, optionalPython: optionalPython).apply(to: process)
    }
}
