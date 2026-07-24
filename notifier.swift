// Herdr Prompt Reply -- the whole plugin in one Swift binary.
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
// Responder activity is appended to ~/Library/Logs/HerdrPromptReply.log because its
// stdout goes nowhere.
//
// UNUserNotificationCenter only works from inside an .app bundle, which is why
// build-app.sh compiles this straight into HerdrPromptReply.app.

import AppKit
import UserNotifications

let logPath = ("~/Library/Logs/HerdrPromptReply.log" as NSString).expandingTildeInPath

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
    // Subtitle line of the notification. Herdr names tabs "1", "2", "3" by
    // default, so the raw tab label is a poor identifier -- this template lets
    // the user say *which* session is asking in their own terms.
    // Tokens: {workspace} {agent} {topic} {cwd} {tab}
    var subtitleFormat = "{workspace} · {agent}"
    // A finished notification needs no interaction, so unlike a prompt it should
    // not sit on screen under the Alerts style. Auto-withdraw it after this many
    // seconds; 0 keeps it until clicked or its pane is focused.
    var doneDismissSeconds = 10
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
        // "" is a valid choice: it formats to nothing, and the empty-subtitle
        // fallback then renders a minimal "<Agent> needs input|finished".
        case "subtitle_format": config.subtitleFormat = raw
        case "done_dismiss_seconds": config.doneDismissSeconds = max(0, Int(raw) ?? config.doneDismissSeconds)
        default: break
        }
    }
    return config
}

// ---------------------------------------------------------------------------
// Subtitle formatting
// ---------------------------------------------------------------------------

// herdr reports agent ids in lower case ("claude", "codex"). This map is the
// single place to teach the plugin an agent's display name; capitalize-first is
// only the fallback for ids not yet listed. Add new agents here as they appear.
let agentDisplayNames: [String: String] = [
    "claude": "Claude", "codex": "Codex", "hermes": "Hermes", "cursor": "Cursor",
    "aider": "Aider", "gemini": "Gemini", "copilot": "Copilot", "amp": "Amp",
    "goose": "Goose", "opencode": "OpenCode", "openai": "OpenAI", "chatgpt": "ChatGPT",
]

func prettyAgent(_ raw: String) -> String {
    let key = raw.trimmingCharacters(in: .whitespaces)
    if key.isEmpty { return "" }
    if let known = agentDisplayNames[key.lowercased()] { return known }
    return key.prefix(1).uppercased() + key.dropFirst()
}

// Substitute {token}s from `tokens`; unknown tokens are left literal. Then tidy
// what empty tokens leave behind: collapse whitespace, collapse a separator
// repeated across a gap ("herdr · · Fix" -> "herdr · Fix"), and trim separators
// stranded at either end. Order matters: whitespace first so repeats are
// uniformly spaced, repeats before trimming so an end-run of separators shrinks
// to one char the trim then removes.
//
// The trim set is decorative separators only. `-` and `/` stay out of it: they
// occur inside real content ("my-app-", "a/b") and trimming them would rewrite
// the user's data, not the template's punctuation.
func applyFormat(_ format: String, _ tokens: [String: String]) -> String {
    var result = format
    for (key, value) in tokens {
        result = result.replacingOccurrences(of: "{\(key)}", with: value)
    }
    result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    result = result.replacingOccurrences(
        of: #"([·—–•|])( \1)+"#, with: "$1", options: .regularExpression)
    return result.trimmingCharacters(in: CharacterSet(charactersIn: " ·—–•|:"))
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

// `group` is the pane id: threadIdentifier AND the request id, so any newer
// notification for the pane replaces the older one. `stamp` marks a finished
// notification so its delayed remover can verify it is still the same instance
// before removing -- a request id of its own would be cleaner, but usernoted
// then never delivers the body-click response (verified by A/B on macOS 26.5).
func post(title: String, subtitle: String, message: String, group: String, sound: String,
          paneId: String, herdr: String, stamp: String? = nil,
          actions: [(digit: String, label: String)]) {
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
    var userInfo: [String: Any] = ["pane_id": paneId, "herdr": herdr]
    if let stamp { userInfo["stamp"] = stamp }
    content.userInfo = userInfo
    if !sound.isEmpty { content.sound = UNNotificationSound(named: UNNotificationSoundName(sound)) }

    // Every notification gets a category, even with no actions: usernoted does
    // not deliver the default-action (body click) response for category-less
    // notifications -- the responder launches and then hears nothing. Found the
    // hard way; actions-bearing prompts always worked, buttonless ones never.
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

// Remove the pane's notification only if it is still the instance carrying
// `stamp` -- the delayed remover for a finished notification must leave alone
// whatever replaced it (a prompt, or a newer finished notification) inside the
// delay window.
func removeIfStamped(_ identifier: String, stamp: String) {
    let semaphore = DispatchSemaphore(value: 0)
    var matches = false
    center.getDeliveredNotifications { delivered in
        matches = delivered.contains {
            $0.request.identifier == identifier &&
            ($0.request.content.userInfo["stamp"] as? String) == stamp
        }
        semaphore.signal()
    }
    semaphore.wait()
    if matches { remove(identifier) }
}

// Fire-and-forget expiry for a finished notification. The sleeper MUST be
// /bin/sh, not another instance of this bundle: while a bundle process is
// alive, usernoted routes a click's response to it instead of launching the
// responder -- and the sleeper has no delegate, so the click would vanish.
// (Found by A/B: clicks delivered fine exactly when no remover was pending.)
func spawnDetachedExpiry(seconds: Int, identifier: String, stamp: String) {
    let process = Process()
    let selfPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "sleep \(seconds); exec \"$0\" --remove \"$1\" --stamp \"$2\"",
                         selfPath, identifier, stamp]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
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
    // rather than leave a stale entry on screen.
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

    // Pane record carries the identifiers the subtitle tokens draw on
    // (tab_id, workspace_id, cwd) plus the focus check below.
    let pane = (herdrJSON(herdr, ["pane", "get", paneId])?["result"] as? [String: Any])?["pane"] as? [String: Any]
    var tabLabel = ""
    if let tabId = pane?["tab_id"] as? String,
       let tab = (herdrJSON(herdr, ["tab", "get", tabId])?["result"] as? [String: Any])?["tab"] as? [String: Any],
       let label = tab["label"] as? String {
        tabLabel = label
    } else if let label = pane?["label"] as? String {
        tabLabel = label
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

    // Subtitle: a user-chosen template naming which session is asking. Herdr's
    // default tab names ("1", "2", ...) make the raw tab label a poor
    // identifier, hence the default "{workspace} · {agent}". Workspace is looked
    // up lazily -- only when the template actually asks for it.
    var workspace = ""
    if config.subtitleFormat.contains("{workspace}"),
       let wsId = pane?["workspace_id"] as? String {
        workspace = ((herdrJSON(herdr, ["workspace", "get", wsId])?["result"] as? [String: Any])?["workspace"] as? [String: Any])?["label"] as? String ?? ""
    }
    let cwd = (pane?["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
    var subtitle = applyFormat(config.subtitleFormat, [
        "workspace": workspace,
        "agent": prettyAgent(agent),
        "topic": topic,
        "cwd": cwd,
        "tab": tabLabel,
    ])
    // A finished agent's message is just its topic, so preserve the
    // finished/needs-input distinction the template itself may not carry.
    if subtitle.isEmpty {
        subtitle = "\(prettyAgent(agent)) \(isDone ? "finished" : "needs input")"
    } else if isDone {
        subtitle += " — finished"
    }

    warnIfHerdrAlsoNotifies()
    // One request id per pane, so any newer notification replaces the older
    // one. A finished notification carries a stamp its delayed remover must
    // re-find before removing -- that is what keeps the remover off a prompt
    // that takes over the pane inside the delay window.
    let stamp = isDone ? String(Int(Date().timeIntervalSince1970 * 1000)) : nil
    post(title: "Herdr", subtitle: subtitle, message: message, group: paneId,
         sound: config.sound, paneId: paneId, herdr: herdr, stamp: stamp,
         actions: approval?.options ?? [])
    if let stamp, config.doneDismissSeconds > 0 {
        spawnDetachedExpiry(seconds: config.doneDismissSeconds, identifier: paneId, stamp: stamp)
    }
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

    // Agent name casing.
    expect(prettyAgent("claude") == "Claude", "prettyAgent: known lower-case")
    expect(prettyAgent("CODEX") == "Codex", "prettyAgent: known upper-case")
    expect(prettyAgent("mytool") == "Mytool", "prettyAgent: unknown capitalized")
    expect(prettyAgent("") == "", "prettyAgent: empty stays empty")

    // Subtitle templates.
    let tok = ["workspace": "herdr", "agent": "Claude", "topic": "Fix the parser bug",
               "cwd": "my-project", "tab": "1"]
    expect(applyFormat("{workspace} · {agent}", tok) == "herdr · Claude", "format: default")
    expect(applyFormat("{agent}: {topic}", tok) == "Claude: Fix the parser bug", "format: agent+topic")
    expect(applyFormat("{unknown}", tok) == "{unknown}", "format: unknown left literal")
    // An empty token must not strand its separator.
    let noWs = ["workspace": "", "agent": "Claude", "topic": "", "cwd": "", "tab": "1"]
    expect(applyFormat("{workspace} · {agent}", noWs) == "Claude", "format: empty workspace trims separator")
    expect(applyFormat("{agent} — {cwd}", noWs) == "Claude", "format: empty cwd trims separator")
    // A separator repeated across a gap collapses without doubling spaces, and
    // strands at the start disappear entirely.
    let midGap = ["workspace": "herdr", "agent": "", "topic": "Fix bug", "cwd": "", "tab": ""]
    expect(applyFormat("{workspace} · {agent} · {topic}", midGap) == "herdr · Fix bug",
           "format: doubled middle separator collapses cleanly")
    let twoGaps = ["workspace": "", "agent": "", "topic": "Fix bug", "cwd": "", "tab": ""]
    expect(applyFormat("{workspace} · {agent} · {topic}", twoGaps) == "Fix bug",
           "format: leading separator run removed")
    // Trimming targets template separators, never characters inside content.
    let dashCwd = ["workspace": "", "agent": "", "topic": "", "cwd": "my-app-", "tab": ""]
    expect(applyFormat("{cwd}", dashCwd) == "my-app-", "format: content trailing dash preserved")
    let question = ["workspace": "", "agent": "Claude", "topic": "Is it done?", "cwd": "", "tab": ""]
    expect(applyFormat("{agent}: {topic}", question) == "Claude: Is it done?", "format: content question mark preserved")
    // An empty template stays empty, which the caller turns into the minimal
    // "<Agent> needs input|finished" subtitle.
    expect(applyFormat("", tok) == "", "format: empty template stays empty")

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
    // --delay is how a finished notification expires: post spawns a detached
    // `--remove <pane-id> --delay N --stamp S` child that sleeps out the
    // display time, then removes only if the stamp still matches.
    if options.delay > 0 { Thread.sleep(forTimeInterval: TimeInterval(options.delay)) }
    if let stamp = options.stamp {
        removeIfStamped(removeId, stamp: stamp)
    } else {
        remove(removeId)
    }
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
log("responder: launched, exe=\(Bundle.main.executablePath ?? "?") bundleId=\(Bundle.main.bundleIdentifier ?? "?")")
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
    var delay = 0
    var stamp: String? = nil
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
        case "--delay": options.delay = max(0, Int(iterator.next() ?? "0") ?? 0)
        case "--stamp": options.stamp = iterator.next()
        case "--list": options.list = true
        case "--status": options.status = true
        case "--self-test": options.selfTest = true
        default: break
        }
    }
    return options
}
