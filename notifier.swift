// Herdr Approvr -- the whole plugin in one Swift binary.
//
// Modes (decided by argv):
//   handle-event     invoked by herdr for subscribed events and the manual
//                    action; reads HERDR_PLUGIN_EVENT* from the environment,
//                    parses the blocked pane's prompt, posts the notification
//   --remove <id>    withdraw the notification posted under <id>
//   --title ...      post a notification directly (debugging)
//   --list           print delivered notification ids (debugging)
//   --status         print authorization status (debugging)
//   --self-test      run the prompt-parser test cases
//   (no args)        respond mode: the system launches us when the user acts on
//                    a notification; the delegate performs the action and exits
//
// Posting is fire-and-exit: the click context (pane id, herdr path, option
// digits) travels inside the notification's userInfo, and the system relaunches
// this binary to deliver the response -- no process waits for an answer.
// Responder activity is appended to ~/Library/Logs/HerdrApprovr.log because its
// stdout goes nowhere.
//
// UNUserNotificationCenter only works from inside an .app bundle, which is why
// build-app.sh compiles this straight into HerdrApprovr.app.

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
        process.arguments = arguments
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
    }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return (127, "") }
    // Read before waiting so a chatty child cannot deadlock on a full pipe.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func herdrJSON(_ herdr: String, _ arguments: [String]) -> [String: Any]? {
    let result = runProcess(herdr, arguments)
    guard result.status == 0, let data = result.stdout.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

// ---------------------------------------------------------------------------
// Config (flat `key = value` TOML, same shape as examples/default-config.toml)
// ---------------------------------------------------------------------------

struct Config {
    var sound = ""
    var suppressWhenFocused = true
    var notifyDone = false
}

func loadConfig() -> Config {
    var config = Config()
    guard let dir = ProcessInfo.processInfo.environment["HERDR_PLUGIN_CONFIG_DIR"],
          let text = try? String(contentsOfFile: dir + "/config.toml", encoding: .utf8)
    else { return config }
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("[") { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
        var raw = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("\"") || raw.hasPrefix("'") {
            let quote = raw.first!
            raw = String(raw.dropFirst())
            if let end = raw.firstIndex(of: quote) { raw = String(raw[..<end]) }
        } else if let hash = raw.range(of: #"\s+#"#, options: .regularExpression) {
            raw = String(raw[..<hash.lowerBound])
        }
        switch key {
        case "sound": config.sound = raw
        case "suppress_when_focused": config.suppressWhenFocused = raw != "false"
        case "notify_done": config.notifyDone = raw == "true"
        default: break
        }
    }
    return config
}

// ---------------------------------------------------------------------------
// Prompt parsing
// ---------------------------------------------------------------------------

struct Approval {
    let question: String
    let context: [String]
    let options: [(digit: String, label: String)]
}

let optionLine = /^(?:[❯>]\s*)?(\d+)\.\s+(.+)$/
let ruleLine = /^[╭╰]?[─━┄┈-]{3,}[╮╯]?$/
let chromeMarkers: Set<Character> = ["✻", "⏺", "⎿", "❯", "✳", "✽", "·", "※"]

// Find the bottom-most numbered option list (1. ... 2. ...) in the pane text,
// as rendered by Claude Code and similar agents, plus the approval block above
// it. Returns nil when the visible screen holds no such list.
func parseApproval(_ text: String) -> Approval? {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine -> String in
        var line = String(rawLine)
        line.removeAll { char in
            if let scalar = char.unicodeScalars.first, char.unicodeScalars.count == 1 {
                return (scalar.value < 0x20 && scalar.value != 0x09) || scalar.value == 0x7f
            }
            return false
        }
        return line.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "│┃|")))
    }

    var start = -1
    for index in stride(from: lines.count - 1, through: 0, by: -1) {
        if let match = lines[index].wholeMatch(of: optionLine), match.1 == "1" {
            start = index
            break
        }
    }
    if start < 0 { return nil }

    var options: [(digit: String, label: String)] = []
    for index in start..<lines.count {
        guard let match = lines[index].wholeMatch(of: optionLine) else {
            if options.isEmpty { continue } else { break } // wrapped label line -> list ended
        }
        if Int(match.1) != options.count + 1 { break }
        options.append((String(match.1), String(match.2).trimmingCharacters(in: .whitespaces)))
    }
    if options.count < 2 { return nil }

    // Context above the list: the approval block's content (tool name, command,
    // question). It ends upward at a horizontal rule or at conversation chrome.
    // Long commands are compressed to head + tail -- the head names the tool
    // and command, the tail holds the question.
    var context: [String] = []
    for index in stride(from: start - 1, through: 0, by: -1) {
        if context.count >= 40 { break }
        let line = lines[index]
        if line.wholeMatch(of: ruleLine) != nil { break }
        if let first = line.first, chromeMarkers.contains(first) { break }
        if line.isEmpty { continue }
        context.insert(line, at: 0)
    }
    if context.count > 7 { context = context.prefix(4) + ["…"] + context.suffix(2) }
    let question = context.last(where: { $0.hasSuffix("?") }) ?? ""
    return Approval(question: question, context: context, options: options)
}

// Cap button labels: macOS ellipsises them anyway, and a bounded label keeps
// the action rows readable when the notification is expanded.
func buttonLabel(_ label: String) -> String {
    let clean = label.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    return clean.count > 40 ? String(clean.prefix(39)) + "…" : clean
}

// ---------------------------------------------------------------------------
// Notification center helpers
// ---------------------------------------------------------------------------

let center = UNUserNotificationCenter.current()

func post(title: String, subtitle: String, message: String, group: String, sound: String,
          paneId: String, herdr: String, actions: [(digit: String, label: String)]) {
    let semaphore = DispatchSemaphore(value: 0)
    var authorized = false
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        authorized = granted
        semaphore.signal()
    }
    semaphore.wait()
    guard authorized else {
        FileHandle.standardError.write("notification authorization denied\n".data(using: .utf8)!)
        exit(1)
    }

    let content = UNMutableNotificationContent()
    content.title = title
    if !subtitle.isEmpty { content.subtitle = subtitle }
    content.body = message
    content.threadIdentifier = group
    content.userInfo = ["pane_id": paneId, "herdr": herdr]
    if !sound.isEmpty { content.sound = UNNotificationSound(named: UNNotificationSoundName(sound)) }

    if !actions.isEmpty {
        let notificationActions = actions.map {
            UNNotificationAction(identifier: $0.digit, title: buttonLabel($0.label), options: [])
        }
        let category = UNNotificationCategory(
            identifier: group, actions: notificationActions, intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.getNotificationCategories { existing in
            var categories = existing.filter { $0.identifier != group }
            categories.insert(category)
            center.setNotificationCategories(categories)
            semaphore.signal()
        }
        semaphore.wait()
        content.categoryIdentifier = group
    }

    let request = UNNotificationRequest(identifier: group, content: content, trigger: nil)
    center.add(request) { error in
        if let error { FileHandle.standardError.write("post failed: \(error)\n".data(using: .utf8)!) }
        semaphore.signal()
    }
    semaphore.wait()
    print("posted: \(group)")
}

func remove(_ identifier: String) {
    center.removeDeliveredNotifications(withIdentifiers: [identifier])
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
    // Removal is fire-and-forget in the API; give it a beat to land.
    Thread.sleep(forTimeInterval: 0.3)
}

// ---------------------------------------------------------------------------
// handle-event: the plugin entry point herdr invokes
// ---------------------------------------------------------------------------

func handleEvent() {
    let env = ProcessInfo.processInfo.environment
    // Event payload is wrapped: {"event": "...", "data": {pane_id, agent_status, ...}}
    let rawEvent = (env["HERDR_PLUGIN_EVENT_JSON"]?.data(using: .utf8))
        .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    let event = (rawEvent?["data"] as? [String: Any]) ?? rawEvent
    let context = (env["HERDR_PLUGIN_CONTEXT_JSON"]?.data(using: .utf8))
        .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    let contextPane = context?["pane"] as? [String: Any]

    guard let paneId = (event?["pane_id"] as? String)
        ?? (contextPane?["pane_id"] as? String)
        ?? env["HERDR_PANE_ID"]
    else { return }
    let config = loadConfig()
    var herdr = env["HERDR_BIN_PATH"] ?? "herdr"
    // The responder instance is launched by the system with a near-empty PATH,
    // so bake an absolute herdr path into the notification.
    if !herdr.contains("/") {
        let resolved = runProcess("sh", ["-c", "command -v \(herdr)"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolved.isEmpty { herdr = resolved }
    }

    // Arriving at the pane answers the notification's question: withdraw it
    // rather than leave a stale prompt on screen.
    if env["HERDR_PLUGIN_EVENT"] == "pane.focused" {
        remove(paneId)
        return
    }

    // Event path fires on the flip to `blocked`, and to `done` when the user
    // opted in; the manual `notify` action (no event) skips this gate.
    let status = event?["agent_status"] as? String
    let isDone = status == "done"
    if event != nil && status != "blocked" && !(isDone && config.notifyDone) { return }

    let agent = (event?["display_agent"] as? String)
        ?? (event?["agent"] as? String)
        ?? (contextPane?["agent"] as? String)
        ?? "agent"
    let topic = ((event?["title"] as? String) ?? "")
        .components(separatedBy: .controlCharacters).joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)

    // Title = the tab's label (what the user sees in the tab bar), so the
    // notification says *which* session is asking.
    let pane = (herdrJSON(herdr, ["pane", "get", paneId])?["result"] as? [String: Any])?["pane"] as? [String: Any]
    var heading = ""
    if let tabId = pane?["tab_id"] as? String,
       let tab = (herdrJSON(herdr, ["tab", "get", tabId])?["result"] as? [String: Any])?["tab"] as? [String: Any],
       let label = tab["label"] as? String {
        heading = label
    } else if let label = pane?["label"] as? String {
        heading = label
    }

    if config.suppressWhenFocused && userIsWatching(pane) {
        print("suppressed: \(paneId) is focused and the terminal is frontmost")
        return
    }

    // A finished agent has no prompt to parse and nothing to answer: report the
    // topic and let the click take the user there.
    // "visible" = the current screen -- an approval UI is on it by definition.
    let approval: Approval? = isDone ? nil : parseApproval(
        runProcess(herdr, ["pane", "read", paneId, "--source", "visible", "--lines", "40"]).stdout
    )

    var message = topic.isEmpty ? "Waiting for your answer" : topic
    if isDone {
        message = topic.isEmpty ? "Finished" : topic
    } else if let approval, !approval.context.isEmpty {
        message = approval.context.joined(separator: "\n")
    } else if let approval, !approval.question.isEmpty {
        message = approval.question
    }

    // A finished agent's message is just its topic, so without this the
    // notification looks identical to a prompt waiting for an answer.
    let subtitle = heading.isEmpty
        ? "\(agent) \(isDone ? "finished" : "needs input")"
        : (isDone ? "\(heading) — finished" : heading)

    warnIfHerdrAlsoNotifies()
    post(title: "Herdr", subtitle: subtitle, message: message, group: paneId,
         sound: config.sound, paneId: paneId, herdr: herdr, actions: approval?.options ?? [])
}

// You are "looking at" the pane when it is the focused pane in herdr *and* the
// terminal is the frontmost app -- then herdr's own in-app toast is enough.
func userIsWatching(_ pane: [String: Any]?) -> Bool {
    guard pane?["focused"] as? Bool == true else { return false }
    let front = runProcess("/usr/bin/osascript",
        ["-e", "tell application \"System Events\" to name of first process whose frontmost is true"]
    ).stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if front.isEmpty { return false }
    return ["kitty", "ghostty", "iterm", "wezterm", "alacritty", "terminal"].contains { front.contains($0) }
}

// herdr can post its own system notification for the same blocked agent, which
// then sits next to ours saying the same thing without buttons. We do not touch
// the user's global config, but an unexplained duplicate is worse than a hint.
func warnIfHerdrAlsoNotifies() {
    let path = ("~/.config/herdr/config.toml" as NSString).expandingTildeInPath
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
    if text.range(of: #"(?m)^\s*delivery\s*=\s*["']system["']"#, options: .regularExpression) != nil {
        print("note: herdr [ui.toast] delivery = \"system\" also posts a notification for this event; set it to \"herdr\" to keep only ours")
    }
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
        let pane = (herdrJSON(herdr, ["pane", "get", paneId])?["result"] as? [String: Any])?["pane"] as? [String: Any]
        return pane?["agent_status"] as? String == "blocked"
    }

    private func focusPane(_ paneId: String, herdr: String) {
        // `pane focus` is direction-only; `agent focus` accepts a pane id and
        // jumps workspace + tab + pane. It only switches inside herdr, so the
        // terminal app still needs to come forward. Best effort.
        runProcess(herdr, ["agent", "focus", paneId])
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
// Self-test (ports test.js)
// ---------------------------------------------------------------------------

func selfTest() -> Never {
    var failures = 0
    func expect(_ condition: Bool, _ label: String) {
        if !condition { failures += 1; print("FAIL: \(label)") }
    }

    let claudePrompt = """
    │ Bash(rm -rf node_modules)                                    │
    │                                                              │
    │ Do you want to proceed?                                      │
    │ ❯ 1. Yes                                                     │
    │   2. Yes, and don't ask again for rm commands in this repo   │
    │   3. No, and tell Claude what to do differently (esc)        │
    """
    if let result = parseApproval(claudePrompt) {
        expect(result.options.count == 3, "claude prompt: 3 options")
        expect(result.options[0].digit == "1" && result.options[0].label == "Yes", "claude prompt: option 1")
        expect(result.options[2].digit == "3", "claude prompt: option 3")
        expect(result.question == "Do you want to proceed?", "claude prompt: question")
    } else { expect(false, "claude prompt detected") }

    expect(parseApproval("$ ls\nREADME.md notifier.swift\n$") == nil, "no false positive on plain shell")

    let wrapped = """
     Allow this tool?
     ❯ 1. Yes
       2. No, and tell Claude what to
          do differently
    """
    if let result = parseApproval(wrapped) {
        expect(result.options.count == 2, "wrapped label: 2 options")
        expect(result.question == "Allow this tool?", "wrapped label: question")
    } else { expect(false, "wrapped label detected") }

    let boxed = """
    ✻ Baked for 9s
    ────────────────────────────────────────
     Bash command
       rtk git stash push -q -- src/services/fetch.ts && npx vue-tsc --noEmit
       Test removing fetch.ts AbortSignal
     This command requires approval
     Do you want to proceed?
     ❯ 1. Yes
       2. Yes, and don't ask again for git checkout, rtk npx, and echo commands
       3. No
     Esc to cancel · Tab to amend · ctrl+e to explain
    """
    if let result = parseApproval(boxed) {
        expect(result.options.count == 3, "boxed prompt: 3 options")
        expect(result.context.first == "Bash command", "boxed prompt: context head")
        expect(result.context.contains { $0.contains("rtk git stash push") }, "boxed prompt: command in context")
        expect(!result.context.contains { $0.contains("Baked") }, "boxed prompt: rule stops context")
        expect(result.question == "Do you want to proceed?", "boxed prompt: question")
    } else { expect(false, "boxed prompt detected") }

    let long = """
    ✻ Baked for 3m 2s
     Bash command
       git commit -m "$(cat <<'EOF'
       refactor: strip unrelated changes
       line3
       line4
       line5
       line6
       EOF
       Commit product-picker removal
     This command requires approval
     Do you want to proceed?
     ❯ 1. Yes
       2. Yes, and don't ask again
       3. No
    """
    if let result = parseApproval(long) {
        expect(result.options.count == 3, "long command: 3 options")
        expect(result.context.first == "Bash command", "long command: context head")
        expect(result.context.contains("…"), "long command: compressed")
        expect(result.context.last == "Do you want to proceed?", "long command: question last")
        expect(result.context.count == 7, "long command: 7 context lines")
        expect(!result.context.contains { $0.contains("Baked") }, "long command: chrome stops context")
    } else { expect(false, "long command detected") }

    if failures == 0 { print("self-test OK"); exit(0) }
    exit(1)
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

let options = parseArguments()

if CommandLine.arguments.dropFirst().first == "handle-event" {
    handleEvent()
    exit(0)
}
if options.selfTest { selfTest() }
if options.status {
    let semaphore = DispatchSemaphore(value: 0)
    center.getNotificationSettings { settings in
        print("authorization: \(settings.authorizationStatus.rawValue) (2=authorized), alertStyle: \(settings.alertStyle.rawValue) (2=alert 1=banner 0=none)")
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}
if options.list {
    let semaphore = DispatchSemaphore(value: 0)
    center.getDeliveredNotifications { delivered in
        for notification in delivered { print(notification.request.identifier) }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}
if let removeId = options.remove {
    remove(removeId)
    exit(0)
}
if !options.title.isEmpty {
    post(title: options.title, subtitle: options.subtitle, message: options.message,
         group: options.group, sound: options.sound, paneId: options.paneId,
         herdr: options.herdr, actions: options.actions)
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

// ---------------------------------------------------------------------------
// Argument parsing (kept at the bottom; Swift top-level code runs in order, so
// only declarations may follow the main flow above)
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
    var selfTest = false
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
        case "--self-test": options.selfTest = true
        default: break
        }
    }
    return options
}
