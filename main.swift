import Cocoa

let ifconfigPath = "/sbin/ifconfig"
let gfnBundleID = "com.nvidia.gfnpc.mall"
let autoKey = "autoWithGeForceNow"
let defaultLogDir = NSHomeDirectory() + "/Library/Application Support/NVIDIA/GeForceNOW"

// Test mode: AWDL and the client are simulated by files, the real interface is never touched.
let testDir = ProcessInfo.processInfo.environment["AWDL_TEST_DIR"]
let journalPath = testDir.map { $0 + "/events.log" } ?? NSHomeDirectory() + "/Library/Logs/AWDLToggle.log"

// English by default, Russian when it is the first preferred language.
let russian = Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
func tr(_ en: String, _ ru: String) -> String { russian ? ru : en }

func note(_ message: String) {
    // One older copy is kept, so a long fight with macOS cannot grow the journal without bound.
    if let size = (try? FileManager.default.attributesOfItem(atPath: journalPath))?[.size] as? Int, size > 1_000_000 {
        try? FileManager.default.removeItem(atPath: journalPath + ".1")
        try? FileManager.default.moveItem(atPath: journalPath, toPath: journalPath + ".1")
    }
    let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8)
    if let handle = FileHandle(forWritingAtPath: journalPath) {
        handle.seekToEndOfFile()
        handle.write(line)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: journalPath, contents: line)
    }
}

func run(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

// Reads the flags in-process: no root and no process spawned per check.
func awdlIsUp() -> Bool {
    if let dir = testDir {
        return (try? String(contentsOfFile: dir + "/awdl", encoding: .utf8))?.hasPrefix("up") ?? false
    }
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return false }
    defer { freeifaddrs(list) }
    var entry = list
    while let ifa = entry {
        if String(cString: ifa.pointee.ifa_name) == "awdl0" {
            return ifa.pointee.ifa_flags & UInt32(IFF_UP) != 0
        }
        entry = ifa.pointee.ifa_next
    }
    return false
}

// Without a sudoers rule `sudo -n` fails and macOS shows its own password dialog.
func setAwdl(up: Bool) -> Bool {
    let action = up ? "up" : "down"
    if let dir = testDir {
        // In place, so the watcher's file descriptor keeps pointing at the same file.
        return (try? action.write(toFile: dir + "/awdl", atomically: false, encoding: .utf8)) != nil
    }
    if run("/usr/bin/sudo", ["-n", ifconfigPath, "awdl0", action]) == 0 { return true }
    let script = "do shell script \"\(ifconfigPath) awdl0 \(action)\" with administrator privileges"
    return run("/usr/bin/osascript", ["-e", script]) == 0
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

// True for a routing message saying awdl0's flags changed. Only a hint: any local user can send
// such a message, so the caller reads the real flags before acting on it.
func isAwdlChange(_ bytes: UnsafeRawBufferPointer, awdlIndex: UInt32) -> Bool {
    guard awdlIndex != 0, bytes.count >= MemoryLayout<if_msghdr>.size else { return false }
    let msg = bytes.loadUnaligned(as: if_msghdr.self)
    return Int32(msg.ifm_type) == RTM_IFINFO && UInt32(msg.ifm_index) == awdlIndex
}

// Reports the state of awdl0 whenever it may have changed: on messages from the kernel's routing
// socket, which any user can read, or in test mode on writes to the simulated interface file.
final class AwdlWatcher {
    private var source: DispatchSourceProtocol?
    var isActive: Bool { source != nil }

    init(onChange: @escaping (Bool) -> Void) {
        if let dir = testDir {
            let fd = open(dir + "/awdl", O_EVTONLY)
            guard fd >= 0 else { return }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            s.setEventHandler { onChange(awdlIsUp()) }
            s.setCancelHandler { close(fd) }
            s.resume()
            source = s
            return
        }
        let fd = socket(PF_ROUTE, SOCK_RAW, 0)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        s.setEventHandler {
            // Looked up on each wakeup, since the index can change if awdl0 is recreated.
            let index = if_nametoindex("awdl0")
            var buffer = [UInt8](repeating: 0, count: 2048)
            var changed = false
            // Drains the queue, so a burst of messages costs one check.
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                guard n > 0 else { break }
                if buffer.withUnsafeBytes({ isAwdlChange(UnsafeRawBufferPointer(rebasing: $0[..<n]), awdlIndex: index) }) {
                    changed = true
                }
            }
            if changed { onChange(awdlIsUp()) }
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var busy = false
    // A switch asked for while another one was running; the newest request wins.
    var queued: Bool?
    var wasStreaming = false
    // Set after a manual "on" or a failed switch, cleared when a stream starts or ends.
    var keepOn = false
    // Recent forced offs, to slow down when macOS keeps raising AWDL right back.
    var recentOffs: [Date] = []
    var slowed = false
    var recheckScheduled = false
    var rendered: (up: Bool, streaming: Bool, auto: Bool)?
    var watcher: AwdlWatcher?

    var autoEnabled: Bool {
        get { testDir != nil || UserDefaults.standard.bool(forKey: autoKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        watcher = AwdlWatcher { [weak self] up in self?.awdlChanged(up: up) }
        if watcher?.isActive != true { note("interface watcher unavailable, relying on the 3 s check") }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func tick() {
        // A crashed client never logs Streamer_Exit, so the stream also needs a live client.
        let streaming = autoEnabled && gfnIsRunning() && logSaysStreaming()
        let up = awdlIsUp()
        render(up: up, streaming: streaming)

        if wasStreaming && !streaming {
            note("stream end")
            wasStreaming = false
            keepOn = false
            // A running switch may still turn it off, so the restore is queued behind it.
            if !up || busy { apply(up: true) }
            return
        }
        if streaming && !wasStreaming {
            note("stream start")
            keepOn = false
        }
        wasStreaming = streaming
        // A backup for a missed event: macOS can raise awdl0 on its own during the stream.
        holdDown(up: up, reason: "awdl is up during stream")
    }

    // macOS can raise awdl0 mid-stream at any moment; reacting to the event instead of waiting
    // for the next tick keeps it from staying up for up to 3 seconds.
    func awdlChanged(up: Bool) {
        render(up: up, streaming: wasStreaming)
        holdDown(up: up, reason: "awdl came up during stream")
    }

    // Turns AWDL off when it is up during a stream: at most every 0.5 s, and every 3 s after 10
    // forced offs within 10 s, so a macOS that keeps raising it cannot pin the app in a loop of
    // sudo calls.
    func holdDown(up: Bool, reason: String) {
        // A running switch checks the state again when it finishes.
        guard wasStreaming && autoEnabled && up && !keepOn && !busy else { return }
        let now = Date()
        recentOffs.removeAll { now.timeIntervalSince($0) > 10 }
        let gap: TimeInterval = recentOffs.count >= 10 ? 3 : 0.5
        if gap > 1 && !slowed { note("awdl keeps coming back, turning it off at most every 3 s") }
        slowed = gap > 1
        if let last = recentOffs.last, now.timeIntervalSince(last) < gap {
            guard !recheckScheduled else { return }
            recheckScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + gap - now.timeIntervalSince(last)) {
                self.recheckScheduled = false
                self.holdDown(up: awdlIsUp(), reason: reason)
            }
            return
        }
        recentOffs.append(now)
        note("\(reason), turning off")
        apply(up: false)
    }

    func apply(up: Bool) {
        if busy {
            queued = up
            return
        }
        busy = true
        DispatchQueue.global().async {
            let ok = setAwdl(up: up)
            note("set \(up ? "up" : "down"): \(ok ? "ok" : "failed")")
            DispatchQueue.main.async {
                self.busy = false
                // A failed or cancelled switch would otherwise be retried at once with another
                // password dialog, so AWDL stays as it is until a stream starts or ends.
                if !ok { self.keepOn = true }
                if let next = self.queued {
                    self.queued = nil
                    if next != awdlIsUp() {
                        self.apply(up: next)
                        return
                    }
                }
                self.awdlChanged(up: awdlIsUp())
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
                                  action: #selector(toggleClicked(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.tag = up ? 0 : 1
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

    // The clicked title decides, not the state at click time, which may have changed since the
    // menu was drawn; a click during another switch runs after it.
    @objc func toggleClicked(_ sender: NSMenuItem) {
        let turnOn = sender.tag == 1
        note("manual toggle: turn \(turnOn ? "on" : "off")")
        keepOn = turnOn
        apply(up: turnOn)
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
if CommandLine.arguments.contains("--watch") {
    let watcher = AwdlWatcher { up in print(up ? "up" : "down"); fflush(stdout) }
    guard watcher.isActive else {
        print("cannot watch awdl0")
        exit(1)
    }
    print(awdlIsUp() ? "up" : "down")
    fflush(stdout)
    withExtendedLifetime(watcher) { dispatchMain() }
}
// Checks the routing-message filter on hand-made messages, which test.sh cannot produce.
if CommandLine.arguments.contains("--self-test") {
    func message(type: Int32, index: UInt16, length: Int = MemoryLayout<if_msghdr>.size) -> [UInt8] {
        var msg = if_msghdr()
        msg.ifm_msglen = UInt16(MemoryLayout<if_msghdr>.size)
        msg.ifm_version = UInt8(RTM_VERSION)
        msg.ifm_type = UInt8(type)
        msg.ifm_index = index
        msg.ifm_flags = IFF_UP
        return Array(withUnsafeBytes(of: msg) { Array($0) }.prefix(length))
    }
    let cases: [(name: String, bytes: [UInt8], index: UInt32, expected: Bool)] = [
        ("awdl0 change", message(type: RTM_IFINFO, index: 7), 7, true),
        ("other interface", message(type: RTM_IFINFO, index: 8), 7, false),
        ("other message type", message(type: RTM_NEWADDR, index: 7), 7, false),
        ("truncated message", message(type: RTM_IFINFO, index: 7, length: 20), 7, false),
        ("awdl0 missing, forged index 0", message(type: RTM_IFINFO, index: 0), 0, false),
    ]
    var failed = 0
    for c in cases where c.bytes.withUnsafeBytes({ isAwdlChange($0, awdlIndex: c.index) }) != c.expected {
        print("FAIL \(c.name)")
        failed += 1
    }
    print(failed == 0 ? "ok" : "\(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
