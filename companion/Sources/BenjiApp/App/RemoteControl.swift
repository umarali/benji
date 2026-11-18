import Foundation
import BenjiCore

/// Phone control's listener (docs/remote-control.md): starts `python3 -m benji.remote` when the user
/// turns phone control on, and stops it when they turn it off or quit. The child starts no engine and
/// reads no key. Its stdin and stdout are the only way commands reach the app: each one is handed to
/// the model, which owns the task and its approvals, and the model's snapshot goes back every second.
/// The access key lives in memory only, and is new each time phone control is turned on.
final class RemoteControl: ObservableObject {
    @Published var address: String
    @Published private(set) var accessKey = ""
    @Published private(set) var status = "Off"
    @Published private(set) var isRunning = false
    private let model: CompanionModel
    private let assistantDir: String
    private let port: Int
    private var process: Process?
    private var input: FileHandle?
    private var timer: Timer?
    private let writes = DispatchQueue(label: "benji.phone-pipe")
    private var startingAt = Date.distantPast

    init(model: CompanionModel, assistantDir: String, port: Int = PhoneControl.port) {
        // Writing to a listener that has just exited must fail, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        self.model = model
        self.assistantDir = assistantDir
        self.port = port
        address = PhoneControl.loopback(port: port)
    }

    func start() {
        guard process == nil else { return }
        guard let value = PhoneControl.normalizedAddress(address, port: port) else {
            status = "Use your HTTPS Tailscale address, with no path, or \(PhoneControl.loopback(port: port))."
            return
        }
        address = value
        model.endRemoteControl()
        let child = Process(), incoming = Pipe(), outgoing = Pipe()
        // The listener needs no key: none is passed on.
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasSuffix("_KEY") && !key.hasSuffix("_TOKEN") && !key.hasSuffix("_SECRET")
        }
        env["BENJI_PHONE_DIR"] = assistantDir
        env["BENJI_PHONE_ORIGIN"] = value
        env["BENJI_PHONE_PORT"] = String(port)
        env["PYTHONUNBUFFERED"] = "1"
        child.standardInput = incoming
        child.standardOutput = outgoing
        child.standardError = FileHandle.nullDevice   // nothing of a request or the key reaches a log
        process = child
        input = incoming.fileHandleForWriting
        startingAt = Date()
        status = "Starting…"
        let reader = LineReader { [weak self, weak child] line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            DispatchQueue.main.async {
                guard let self, let child, self.process === child else { return }
                self.receive(obj)
            }
        }
        outgoing.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { reader.consume(data) }
        }
        child.terminationHandler = { [weak self] child in
            outgoing.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, self.process === child else { return }
                let started = !self.accessKey.isEmpty
                self.stop()
                self.status = started ? "Phone control stopped. Turn it on again to reconnect."
                    : "Couldn't start phone control. Check Python 3, the address and whether port \(self.port) is free."
            }
        }
        do {
            try EngineLaunch.configure(child, entry: .remote, arguments: ["--port", String(port), "--origin", value], sourceDirectory: assistantDir, environment: env)
            try child.run()
            isRunning = true
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.accessKey.isEmpty && Date().timeIntervalSince(self.startingAt) > 10 {
                    self.stop()
                    self.status = "Couldn't start phone control. Check that Python 3 is installed."
                    return
                }
                self.write(["type": "snapshot", "state": self.model.remoteSnapshot])   // the listener's heartbeat
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } catch {
            stop()
            status = "Couldn't start phone control. Check that Python 3 is installed."
        }
    }

    /// Revokes the key, stops the listener and stops the phone's running task. Nothing else is touched.
    func stop() {
        timer?.invalidate()
        timer = nil
        model.endRemoteControl()
        let child = process
        process = nil
        let pipe = input
        input = nil
        writes.async { try? pipe?.close() }   // closing its stdin makes the child stop its listener
        if child?.isRunning == true { child?.terminate() }
        accessKey = ""
        isRunning = false
        status = "Off"
    }

    private func write(_ value: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        writes.async { try? input.write(contentsOf: data + Data([10])) }
    }

    private func receive(_ value: [String: Any]) {
        switch value["type"] as? String {
        case "ready":
            guard let token = value["token"] as? String, !token.isEmpty else { stop(); return }
            if let resolved = value["origin"] as? String { address = resolved }
            accessKey = token
            status = "On while Benji is open"
            write(["type": "snapshot", "state": model.remoteSnapshot])
        case "error":
            let message = value["message"] as? String ?? "Couldn't start phone control."
            stop()
            status = message
        case "command":
            guard let id = value["id"] as? String else { return }
            let (ok, message) = model.remoteCommand(value)
            write(["type": "result", "id": id, "ok": ok, "message": message])
            write(["type": "snapshot", "state": model.remoteSnapshot])
        default:
            break
        }
    }
}
