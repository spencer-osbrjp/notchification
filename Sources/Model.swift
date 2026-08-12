import AppKit
import SwiftUI

struct TaskEvent {
    var title: String
    var subtitle: String
    var needsInput = false
    var term: TermInfo?
}

struct LimitBucket: Identifiable {
    let id: String
    var label: String
    var pct: Double // 0...1
    var resetsAt: Date?
}

struct TermInfo {
    var program: String?
    var kittyWin: String?
    var kittySock: String?

    var bundleId: String? {
        if kittyWin?.isEmpty == false { return "net.kovidgoyal.kitty" }
        switch program {
        case "iTerm.app": return "com.googlecode.iterm2"
        case "Apple_Terminal": return "com.apple.Terminal"
        case "WezTerm": return "com.github.wez.wezterm"
        case "ghostty", "Ghostty": return "com.mitchellh.ghostty"
        case "kitty": return "net.kovidgoyal.kitty"
        case "vscode": return "com.microsoft.VSCode"
        default: return nil
        }
    }
}

struct HookEvent {
    enum Kind { case promptSubmit, stop, sessionEnd, notification }
    var kind: Kind
    var sessionId: String
    var project: String
    var transcriptPath: String?
    var message: String?
    var term: TermInfo?
}

struct SessionInfo: Identifiable {
    enum State { case working, waiting, idle }
    let id: String
    var project: String
    var state: State
    var model: String?
    var taskStartedAt: Date?
    var lastActivity: Date
    var term: TermInfo?
}

struct Completion: Identifiable {
    let id = UUID()
    var project: String
    var finishedAt: Date
    var usage: String
}

func fmtTokens(_ n: Int) -> String {
    n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var current: TaskEvent?
    @Published var expanded = false
    @Published var sessions: [SessionInfo] = []
    @Published var completions: [Completion] = []
    @Published var todayIn = 0
    @Published var todayOut = 0
    @Published var peekTrigger = 0
    @Published var limits: [LimitBucket] = []
    var characterOut = false // written by the character view, read by the hover check
    var notchWidth: CGFloat = 200
    var notchHeight: CGFloat = 32
    private var hideTask: Task<Void, Never>?
    // ponytail: in-memory only — today's totals reset on app restart
    private var todayBySession: [String: (input: Int, output: Int)] = [:]
    private var todayDate = Calendar.current.startOfDay(for: .now)

    /// Character stays out of the notch while any session waits for the user.
    var anyWaiting: Bool { sessions.contains { $0.state == .waiting } }

    init() {
        refreshLimits()
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLimits() }
        }
    }

    func handle(_ ev: HookEvent) {
        sessions.removeAll { $0.lastActivity.timeIntervalSinceNow < -8 * 3600 }
        switch ev.kind {
        case .promptSubmit:
            upsert(ev) { $0.state = .working; $0.taskStartedAt = .now; $0.term = ev.term ?? $0.term }
            peekTrigger += 1
        case .notification:
            // Claude Code fires this hook both for real prompts (permissions, selections —
            // always mid-turn) and for "waiting for your input" idle nags ~60s after a turn
            // already ended. The payload doesn't distinguish them; the turn lifecycle does:
            // only honor it while the session is still working (unknown sessions pass, so a
            // real prompt is never dropped after an app restart).
            let midTurn = sessions.first { $0.id == ev.sessionId }.map { $0.state == .working } ?? true
            guard midTurn else { break }
            upsert(ev) { $0.state = .waiting; $0.term = ev.term ?? $0.term }
            peekTrigger += 1
            showBanner(TaskEvent(title: ev.project,
                                 subtitle: ev.message ?? "Claude needs your input",
                                 needsInput: true, term: ev.term),
                       for: 12, sound: "Funk")
        case .stop:
            let stats = TranscriptStats.parse(ev.transcriptPath)
            upsert(ev) {
                $0.state = .idle
                $0.model = stats.model ?? $0.model
                $0.term = ev.term ?? $0.term
            }
            completions.insert(Completion(project: ev.project, finishedAt: .now, usage: stats.lastUsage), at: 0)
            completions = Array(completions.prefix(5))
            addToday(session: ev.sessionId, input: stats.todayIn, output: stats.todayOut)
            let what = stats.lastText.isEmpty ? "Task completed" : stats.lastText
            let subtitle = stats.lastUsage.isEmpty ? what : "\(what) · \(stats.lastUsage)"
            showBanner(TaskEvent(title: ev.project, subtitle: subtitle, term: ev.term),
                       for: 6, sound: "Pop")
            refreshLimits()
        case .sessionEnd:
            sessions.removeAll { $0.id == ev.sessionId }
        }
    }

    private func upsert(_ ev: HookEvent, _ mutate: (inout SessionInfo) -> Void) {
        if let i = sessions.firstIndex(where: { $0.id == ev.sessionId }) {
            sessions[i].lastActivity = .now
            mutate(&sessions[i])
        } else {
            var s = SessionInfo(id: ev.sessionId, project: ev.project, state: .idle,
                                model: nil, taskStartedAt: nil, lastActivity: .now)
            mutate(&s)
            sessions.insert(s, at: 0)
        }
    }

    private func addToday(session: String, input: Int, output: Int) {
        let today = Calendar.current.startOfDay(for: .now)
        if today != todayDate { todayDate = today; todayBySession = [:] }
        todayBySession[session] = (input, output)
        todayIn = todayBySession.values.reduce(0) { $0 + $1.input }
        todayOut = todayBySession.values.reduce(0) { $0 + $1.output }
    }

    private var lastLimitsFetch = Date.distantPast

    /// Same rate-limit data Claude Code's /usage shows: 5h window, weekly, model-specific weekly.
    func refreshLimits(retryOn429: Bool = true) {
        guard Date.now.timeIntervalSince(lastLimitsFetch) > 60 else { return }
        lastLimitsFetch = .now
        Task.detached(priority: .utility) {
            func dbg(_ s: String) {
                if ProcessInfo.processInfo.environment["NOTCH_DEBUG"] != nil {
                    try? s.write(toFile: "/tmp/notch-usage.log", atomically: true, encoding: .utf8)
                }
            }
            guard let token = Self.loadOAuthToken(),
                  let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
                dbg("no token"); return
            }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("claude-cli/2.1.2 (external, cli)", forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
                dbg("request failed"); return
            }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                dbg("status=\(status) body=\(String(data: data.prefix(600), encoding: .utf8) ?? "?")")
                if status == 429, retryOn429 {
                    try? await Task.sleep(for: .seconds(60))
                    await MainActor.run { self.refreshLimits(retryOn429: false) }
                }
                return
            }
            dbg("status=200 keys=\(obj.keys.sorted())")
            let iso = ISO8601DateFormatter()
            let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
            var out: [LimitBucket] = []
            for (key, val) in obj {
                guard let d = val as? [String: Any], let util = d["utilization"] as? Double else { continue }
                // the response also carries internal codename buckets (e.g. nimbus_quill) — show only recognizable ones
                let known = order.contains(key)
                    || ["fable", "mythos", "opus", "sonnet", "haiku"].contains { key.contains($0) }
                guard known else { continue }
                out.append(LimitBucket(id: key, label: Self.limitLabel(key), pct: util / 100,
                                       resetsAt: (d["resets_at"] as? String).flatMap { iso.date(from: $0) }))
            }
            out.sort { (order.firstIndex(of: $0.id) ?? 99) < (order.firstIndex(of: $1.id) ?? 99) }
            await MainActor.run { [out] in self.limits = out }
        }
    }

    nonisolated private static func limitLabel(_ key: String) -> String {
        switch key {
        case "five_hour": return "Session (5h)"
        case "seven_day": return "Week · all"
        case "seven_day_opus": return "Week · Opus"
        case "seven_day_sonnet": return "Week · Sonnet"
        default:
            if key.contains("fable") { return "Week · Fable" }
            return key.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Claude Code stores OAuth creds in ~/.claude/.credentials.json or the macOS Keychain.
    nonisolated private static func loadOAuthToken() -> String? {
        func token(from data: Data) -> String? {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = obj["claudeAiOauth"] as? [String: Any] else { return nil }
            return oauth["accessToken"] as? String
        }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let t = token(from: data) { return t }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return token(from: data)
    }

    /// App-level notice shown through the banner (e.g. update available).
    func notice(_ text: String) {
        showBanner(TaskEvent(title: "Notchification", subtitle: text), for: 8, sound: "Pop")
    }

    /// Click on the banner: focus the exact kitty window when possible, then bring the terminal app front.
    func focusTerminal(_ t: TermInfo?) {
        guard let t else { return }
        if let sock = t.kittySock, !sock.isEmpty, let win = t.kittyWin, !win.isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/Applications/kitty.app/Contents/MacOS/kitten")
            p.arguments = ["@", "--to", sock, "focus-window", "--match", "id:\(win)"]
            try? p.run()
        }
        if let bid = t.bundleId,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            app.activate()
        }
    }

    private func showBanner(_ event: TaskEvent, for seconds: Double, sound: String) {
        if !UserDefaults.standard.bool(forKey: "soundOff") {
            NSSound(named: sound)?.play()
        }
        withAnimation(.spring(duration: 0.45)) { current = event }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { current = nil }
        }
    }
}

/// One pass over a session transcript (JSONL): last message usage, model, and today's token totals.
struct TranscriptStats {
    var lastUsage = ""
    var lastText = "" // first line of the final assistant message, truncated
    var model: String?
    var todayIn = 0
    var todayOut = 0

    static func parse(_ path: String?) -> TranscriptStats {
        var s = TranscriptStats()
        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return s }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        for line in text.split(separator: "\n") {
            guard line.contains("\"usage\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let u = msg["usage"] as? [String: Any]
            else { continue }
            let fresh = (u["input_tokens"] as? Int ?? 0) + (u["cache_creation_input_tokens"] as? Int ?? 0)
            let cached = u["cache_read_input_tokens"] as? Int ?? 0
            let output = u["output_tokens"] as? Int ?? 0
            guard fresh + cached + output > 0 else { continue }
            s.model = msg["model"] as? String ?? s.model
            s.lastUsage = "\(fmtTokens(fresh + cached))↑ \(fmtTokens(output))↓ tokens"
            if let content = msg["content"] as? [[String: Any]],
               let text = content.last(where: { $0["type"] as? String == "text" })?["text"] as? String {
                let line = text.split(separator: "\n").first.map(String.init) ?? ""
                s.lastText = line.count > 70 ? String(line.prefix(70)) + "…" : line
            }
            // today totals count fresh input + output (cache reads excluded — cheap and huge)
            if let ts = obj["timestamp"] as? String,
               let d = isoFrac.date(from: ts) ?? iso.date(from: ts),
               Calendar.current.isDateInToday(d) {
                s.todayIn += fresh
                s.todayOut += output
            }
        }
        return s
    }
}

/// Watches ~/.notchification/events/ — Claude Code hooks drop one JSON file per event.
final class EventWatcher {
    private let dir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".notchification/events")
    private var source: DispatchSourceFileSystemObject?
    private let onEvent: (HookEvent) -> Void

    init(onEvent: @escaping (HookEvent) -> Void) {
        self.onEvent = onEvent
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write,
                                                            queue: .global(qos: .utility))
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        drain()
    }

    private func drain() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension == "json" {
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // hooks wrap the Claude Code JSON with terminal identity: {term_program, kitty_win, kitty_sock, payload}
            var term: TermInfo?
            if let payload = obj["payload"] as? [String: Any] {
                term = TermInfo(program: obj["term_program"] as? String,
                                kittyWin: obj["kitty_win"] as? String,
                                kittySock: obj["kitty_sock"] as? String)
                obj = payload
            }
            let kind: HookEvent.Kind
            switch obj["hook_event_name"] as? String {
            case "UserPromptSubmit": kind = .promptSubmit
            case "Stop": kind = .stop
            case "SessionEnd": kind = .sessionEnd
            case "Notification": kind = .notification
            default: continue
            }
            let cwd = (obj["cwd"] as? String ?? "") as NSString
            let project = cwd.lastPathComponent.isEmpty ? "Claude Code" : cwd.lastPathComponent
            onEvent(HookEvent(kind: kind,
                              sessionId: obj["session_id"] as? String ?? UUID().uuidString,
                              project: project,
                              transcriptPath: obj["transcript_path"] as? String,
                              message: obj["message"] as? String,
                              term: term))
        }
    }
}
