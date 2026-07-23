// HerdrApprovr notifier -- UNUserNotificationCenter replacement for alerter.
//
// Modes (decided by argv):
//   --title ...      post a notification and exit (no waiting process)
//   --remove <id>    withdraw the notification posted under <id>
//   --list           print delivered notification ids (debugging)
//   --status         print authorization status (debugging)
//   (no args)        respond mode: the system launches us when the user acts on
//                    a notification; the delegate performs the action and exits
//
// The click context travels inside the notification's userInfo (pane id, herdr
// binary path, option digits), so the responder instance needs no environment.
// Responder activity is appended to ~/Library/Logs/HerdrApprovr.log because its
// stdout goes nowhere.

import AppKit
import UserNotifications

let logPath = ("~/Library/Logs/HerdrApprovr.log" as NSString).expandingTildeInPath

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) \(message)\n"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

@discardableResult
func runProcess(_ executable: String, _ arguments: [String]) -> (status: Int32, stdout: String) {
    let process = Process()
    if executable.contains("/") {
        process.executableURL = URL(fileURLWithPath: executable)
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
    }
    if process.arguments == nil { process.arguments = arguments }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return (127, "") }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

struct Options {
    var title = ""
    var subtitle = ""
    var message = ""
    var group = "default"
    var sound = ""
    var paneId = ""
    var herdr = "herdr"
    var actions: [(digit: String, label: String)] = []
    var remove: String? = nil
    var list = false
    var status = false
}

func parseArguments() -> Options {
    var options = Options()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let flag = iterator.next() {
        switch flag {
        case "--title": options.title = iterator.next() ?? ""
        case "--subtitle": options.subtitle = iterator.next() ?? ""
        case "--message": options.message = iterator.next() ?? ""
        case "--group": options.group = iterator.next() ?? "default"
        case "--sound": options.sound = iterator.next() ?? ""
        case "--pane": options.paneId = iterator.next() ?? ""
        case "--herdr": options.herdr = iterator.next() ?? "herdr"
        case "--action":
            // "digit=label"
            if let raw = iterator.next(), let eq = raw.firstIndex(of: "=") {
                options.actions.append((String(raw[..<eq]), String(raw[raw.index(after: eq)...])))
            }
        case "--remove": options.remove = iterator.next()
        case "--list": options.list = true
        case "--status": options.status = true
        default: break
        }
    }
    return options
}

// ---------------------------------------------------------------------------
// Responder (launched by the system when the user acts on a notification)
// ---------------------------------------------------------------------------

final class Responder: NSObject, UNUserNotificationCenterDelegate, NSApplicationDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let paneId = info["pane_id"] as? String ?? ""
        let herdr = info["herdr"] as? String ?? "herdr"
        defer {
            completionHandler()
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        guard !paneId.isEmpty else {
            log("respond: no pane_id in userInfo, ignoring")
            return
        }

        switch response.actionIdentifier {
        case UNNotificationDismissActionIdentifier:
            log("respond: dismissed \(paneId)")
        case UNNotificationDefaultActionIdentifier:
            log("respond: body click, focusing \(paneId)")
            focusPane(paneId, herdr: herdr)
        default:
            let digit = response.actionIdentifier
            guard stillBlocked(paneId, herdr: herdr) else {
                log("respond: skipped \(paneId), no longer blocked (answered in terminal?)")
                return
            }
            let result = runProcess(herdr, ["pane", "send-keys", paneId, digit])
            log("respond: sent \"\(digit)\" to \(paneId) (exit \(result.status))")
        }
    }

    private func stillBlocked(_ paneId: String, herdr: String) -> Bool {
        let result = runProcess(herdr, ["pane", "get", paneId])
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pane = ((root["result"] as? [String: Any])?["pane"]) as? [String: Any]
        else { return false }
        return pane["agent_status"] as? String == "blocked"
    }

    private func focusPane(_ paneId: String, herdr: String) {
        runProcess(herdr, ["agent", "focus", paneId])
        // `pane focus` switches inside herdr; the terminal app still needs to
        // come forward. Best effort over the usual suspects.
        let terminals = [("kitty", "kitty"), ("ghostty", "Ghostty"), ("iTerm2", "iTerm"),
                         ("wezterm-gui", "WezTerm"), ("alacritty", "Alacritty"), ("Terminal", "Terminal")]
        for (processName, appName) in terminals {
            if runProcess("/usr/bin/pgrep", ["-xq", processName]).status == 0 {
                runProcess("/usr/bin/open", ["-a", appName])
                return
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

let options = parseArguments()
let center = UNUserNotificationCenter.current()
let semaphore = DispatchSemaphore(value: 0)

if options.status {
    center.getNotificationSettings { settings in
        print("authorization: \(settings.authorizationStatus.rawValue) (2=authorized), alertStyle: \(settings.alertStyle.rawValue) (2=alert 1=banner 0=none)")
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

if options.list {
    center.getDeliveredNotifications { delivered in
        for notification in delivered {
            print(notification.request.identifier)
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

if let removeId = options.remove {
    center.removeDeliveredNotifications(withIdentifiers: [removeId])
    center.removePendingNotificationRequests(withIdentifiers: [removeId])
    // Removal is fire-and-forget in the API; give it a beat to land.
    Thread.sleep(forTimeInterval: 0.3)
    exit(0)
}

if !options.title.isEmpty {
    var authorized = false
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        authorized = granted
        semaphore.signal()
    }
    semaphore.wait()
    if !authorized {
        FileHandle.standardError.write("notification authorization denied\n".data(using: .utf8)!)
        exit(1)
    }

    let content = UNMutableNotificationContent()
    content.title = options.title
    if !options.subtitle.isEmpty { content.subtitle = options.subtitle }
    content.body = options.message
    content.threadIdentifier = options.group
    content.userInfo = ["pane_id": options.paneId, "herdr": options.herdr]
    if !options.sound.isEmpty { content.sound = UNNotificationSound(named: UNNotificationSoundName(options.sound)) }

    if !options.actions.isEmpty {
        let actions = options.actions.map {
            UNNotificationAction(identifier: $0.digit, title: $0.label, options: [])
        }
        let category = UNNotificationCategory(
            identifier: options.group, actions: actions, intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.getNotificationCategories { existing in
            var categories = existing.filter { $0.identifier != options.group }
            categories.insert(category)
            center.setNotificationCategories(categories)
            semaphore.signal()
        }
        semaphore.wait()
        content.categoryIdentifier = options.group
    }

    let request = UNNotificationRequest(identifier: options.group, content: content, trigger: nil)
    center.add(request) { error in
        if let error { FileHandle.standardError.write("post failed: \(error)\n".data(using: .utf8)!) }
        semaphore.signal()
    }
    semaphore.wait()
    print("posted: \(options.group)")
    exit(0)
}

// No recognized arguments: we were launched by the system to deliver a
// notification response. Set the delegate before anything else so the pending
// response is not dropped, run the app loop, and bail out if nothing arrives.
let responder = Responder()
center.delegate = responder
let app = NSApplication.shared
app.delegate = responder
log("responder: launched, waiting for response delivery")
DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
    log("responder: nothing delivered within 15s, exiting")
    NSApp.terminate(nil)
}
app.run()
