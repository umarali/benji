import Foundation
import Darwin

let a = CommandLine.arguments
let mode = a[1], bundle = URL(fileURLWithPath: a[2])
let environment = ProcessInfo.processInfo.environment
let root = EngineLaunch.engineDirectory(bundleURL: bundle).path
func output(_ object: [String: Any]) {
    print(String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
}
do {
    if mode == "cache-check" {
        func make() throws { _ = try EngineLaunch.make(entry: .engine, sourceDirectory: root, environment: [:], bundleURL: bundle) }
        try make(); try make()
        let bootstrap = bundle.appendingPathComponent("Contents/Resources/engine/bootstrap.py")
        let bytes = try Data(contentsOf: bootstrap)
        let attributes = try FileManager.default.attributesOfItem(atPath: bootstrap.path)
        var damaged = bytes; damaged[damaged.startIndex] ^= 1
        try damaged.write(to: bootstrap)
        if let date = attributes[.modificationDate] { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: bootstrap.path) }
        var rejected = false
        do { try make() } catch { rejected = true }
        try bytes.write(to: bootstrap)
        guard rejected else { fatalError("cached bootstrap modification accepted") }
        try make()
        let runtime = bundle.appendingPathComponent("Contents/Frameworks/BenjiPython.framework/Versions/A/BenjiPython")
        let moved = runtime.appendingPathExtension("missing")
        try FileManager.default.moveItem(at: runtime, to: moved)
        rejected = false
        do { try make() } catch { rejected = true }
        try FileManager.default.moveItem(at: moved, to: runtime)
        guard rejected else { fatalError("cached missing runtime accepted") }
        let manifest = bundle.appendingPathComponent("Contents/Resources/distribution.json")
        let manifestBytes = try Data(contentsOf: manifest)
        try Data("{}".utf8).write(to: manifest)
        rejected = false
        do { try make() } catch { rejected = true }
        try manifestBytes.write(to: manifest)
        guard rejected else { fatalError("cached manifest replacement accepted") }
        try make()
        output(["cache_invalidations": 3, "distribution": EngineLaunch.isDistribution])
    } else if mode == "locate" {
        output(["directory": AssistantLocator.resolve(environment: environment, bundleURL: bundle, executableURL: nil, currentDirectory: "/tmp")])
    } else if ["register", "current", "owned", "unregister", "repair"].contains(mode) {
        let r = BrowserHostRegistration(home: URL(fileURLWithPath: a[3]), assistantDir: root, bundleURL: bundle)
        if mode == "register" { try r.register() }
        if mode == "repair" { try BrowserHostRegistration.repairOwned(home: URL(fileURLWithPath: a[3]), assistantDir: root, bundleURL: bundle) }
        if mode == "unregister" { r.unregister() }
        output(["owned": r.isOwned, "current": r.isRegistered, "launcher": r.launcherURL.path, "manifest": r.manifestURL.path])
    } else {
        let entry = EngineLaunch.Entry(rawValue: a[3])!
        let launch = try EngineLaunch.make(entry: entry, arguments: Array(a.dropFirst(4)), sourceDirectory: environment["DISTRIBUTION_PROBE_SOURCE"] ?? "/invalid/source", environment: environment, bundleURL: bundle, optionalPython: environment["DISTRIBUTION_PROBE_OPTIONAL_PYTHON"])
        if mode == "describe" {
            output(["executable": launch.executable.path, "arguments": launch.arguments, "directory": launch.directory.path, "environment": launch.environment])
        } else {
            let p = Process(); launch.apply(to: p)
            try p.run(); p.waitUntilExit(); exit(p.terminationStatus)
        }
    }
} catch let error as BrowserHostRegistration.RegistrationError {
    fputs("Browser registration refused: \(String(describing: error))\n", stderr); exit(78)
} catch {
    fputs("\(error.localizedDescription)\n", stderr); exit(78)
}
