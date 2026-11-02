import Cocoa

let ifconfigPath = "/sbin/ifconfig"
let gfnBundleID = "com.nvidia.gfnpc.mall"
let autoKey = "autoWithGeForceNow"
let defaultLogDir = NSHomeDirectory() + "/Library/Application Support/NVIDIA/GeForceNOW"

// Test mode: AWDL and the client are simulated by files, the real interface is never touched.
let testDir = ProcessInfo.processInfo.environment["AWDL_TEST_DIR"]

// English by default, Russian when it is the first preferred language.
let russian = Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
func tr(_ en: String, _ ru: String) -> String { russian ? ru : en }

func note(_ message: String) {
    let path = testDir.map { $0 + "/events.log" } ?? NSHomeDirectory() + "/Library/Logs/AWDLToggle.log"
    let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8)
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line)
    }
}

@discardableResult
func run(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func awdlIsUp() -> Bool {
    if let dir = testDir {
        return (try? String(contentsOfFile: dir + "/awdl", encoding: .utf8))?.hasPrefix("up") ?? false
    }
    return run(ifconfigPath, ["awdl0"]).out.split(separator: "\n").first?.contains("<UP") ?? false
}

// Without a sudoers rule `sudo -n` fails and macOS shows its own password dialog.
func setAwdl(up: Bool) -> Bool {
    let action = up ? "up" : "down"
    if let dir = testDir {
        return (try? action.write(toFile: dir + "/awdl", atomically: true, encoding: .utf8)) != nil
    }
    if run("/usr/bin/sudo", ["-n", ifconfigPath, "awdl0", action]).code == 0 { return true }
    let script = "do shell script \"\(ifconfigPath) awdl0 \(action)\" with administrator privileges"
    return run("/usr/bin/osascript", ["-e", script]).code == 0
}

func gfnIsRunning() -> Bool {
    if let dir = testDir { return FileManager.default.fileExists(atPath: dir + "/gfn") }
    return !NSRunningApplication.runningApplications(withBundleIdentifier: gfnBundleID).isEmpty
}

// The client logs Streamer_Start and Streamer_Exit for each game stream. The newest of the
// two tells the state; the log rotates to .bak, so a file with neither event defers to it.
func logSaysStreaming() -> Bool {
    let dir = testDir ?? defaultLogDir
    let start = Data("\"name\": \"Streamer_Start\"".utf8)
    let exit = Data("\"name\": \"Streamer_Exit\"".utf8)
    for name in ["geronimo.log", "geronimo.log.bak"] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/" + name)) else { continue }
        let lastStart = data.range(of: start, options: .backwards)?.lowerBound
        let lastExit = data.range(of: exit, options: .backwards)?.lowerBound
        if lastStart == nil && lastExit == nil { continue }
        return (lastStart ?? -1) > (lastExit ?? -1)
    }
    return false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var busy = false
    var wasStreaming = false
    // Set after a manual "on" or a cancelled dialog, cleared when the stream ends.
    var keepOn = false
    var rendered: (up: Bool, streaming: Bool, auto: Bool)?

    var autoEnabled: Bool {
        get { testDir != nil || UserDefaults.standard.bool(forKey: autoKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func tick() {
        guard !busy else { return }
        // A crashed client never logs Streamer_Exit, so the stream also needs a live client.
        let streaming = autoEnabled && gfnIsRunning() && logSaysStreaming()
        let up = awdlIsUp()
        render(up: up, streaming: streaming)

        if wasStreaming && !streaming {
            note("stream end")
            wasStreaming = false
            keepOn = false
            if !up { apply(up: true) }
            return
        }
        if streaming && !wasStreaming {
            note("stream start")
            keepOn = false
        }
        wasStreaming = streaming
        // macOS can raise awdl0 on its own, so this keeps checking during the stream.
        if streaming && up && !keepOn {
            note("awdl is up during stream, turning off")
            apply(up: false, auto: true)
        }
    }

    func apply(up: Bool, auto: Bool = false) {
        guard !busy else { return }
        busy = true
        DispatchQueue.global().async {
            let ok = setAwdl(up: up)
            note("set \(up ? "up" : "down"): \(ok ? "ok" : "failed")")
            DispatchQueue.main.async {
                self.busy = false
                if auto && !ok { self.keepOn = true }
                self.render(up: awdlIsUp(), streaming: self.wasStreaming)
            }
        }
    }

    func render(up: Bool, streaming: Bool) {
        let auto = autoEnabled
        if let r = rendered, r.up == up, r.streaming == streaming, r.auto == auto { return }
        rendered = (up, streaming, auto)

        let symbol = up ? "dot.radiowaves.left.and.right" : "gamecontroller.fill"
        let description = up ? tr("AWDL on", "AWDL включён") : tr("AWDL off", "AWDL выключен")
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: up ? tr("AWDL on: AirDrop works", "AWDL включён: AirDrop работает")
                                   : tr("AWDL off: game mode", "AWDL выключен: режим для игры"),
                     action: nil, keyEquivalent: "")
        if streaming {
            menu.addItem(withTitle: tr("GeForce NOW game is running", "Игра в GeForce NOW запущена"),
                         action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        let toggle = menu.addItem(withTitle: up ? tr("Turn AWDL off", "Выключить AWDL")
                                                : tr("Turn AWDL on", "Включить AWDL"),
                                  action: #selector(toggleClicked), keyEquivalent: "")
        toggle.target = self
        let autoItem = menu.addItem(withTitle: tr("Auto: off while playing GeForce NOW",
                                                  "Авто: выключать на время игры в GeForce NOW"),
                                    action: #selector(autoClicked), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = auto ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Quit", "Выйти"), action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "")
        item.menu = menu
    }

    @objc func toggleClicked() {
        let up = awdlIsUp()
        note("manual toggle, awdl was \(up ? "up" : "down")")
        keepOn = !up
        apply(up: !up)
    }

    @objc func autoClicked() {
        autoEnabled.toggle()
        keepOn = false
        tick()
    }
}

if CommandLine.arguments.contains("--status") {
    print(awdlIsUp() ? "up" : "down")
    exit(0)
}
if CommandLine.arguments.contains("--stream-state") {
    print(logSaysStreaming() ? "streaming" : "idle")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
