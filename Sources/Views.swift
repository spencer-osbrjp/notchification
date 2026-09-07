import SwiftUI

/// Design 3 "Obsidian Liquid": near-opaque black glass, specular rim, liquid accent, ring gauges.
enum Theme {
    static let warn = Color(red: 1, green: 0.83, blue: 0.3)
    static let dim = Color.white.opacity(0.4)

    static func accent(_ a: Agent) -> Color {
        a == .claude ? Color(red: 1.0, green: 0.55, blue: 0.1) : Color(red: 0.17, green: 0.78, blue: 0.62)
    }
    static func accentDark(_ a: Agent) -> Color {
        a == .claude ? Color(red: 0.85, green: 0.4, blue: 0.05) : Color(red: 0.08, green: 0.55, blue: 0.43)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// ponytail: placeholder pixel art, swap maps when real character sheets arrive
enum Sprite {
    static let walkA = [
        "....oo......",
        "....oO......",
        "..OOOOOOOO..",
        ".OOOOOOOOOO.",
        ".OOWWOOWWOO.",
        ".OOWBOOWBOO.",
        ".OOOOOOOOOO.",
        ".OOOOoooOOO.",
        "..OOOOOOOO..",
        "..OO..OO....",
        "..oo..oo....",
    ]
    static let walkB = [
        "....oo......",
        "....oO......",
        "..OOOOOOOO..",
        ".OOOOOOOOOO.",
        ".OOWWOOWWOO.",
        ".OOWBOOWBOO.",
        ".OOOOOOOOOO.",
        ".OOOOoooOOO.",
        "..OOOOOOOO..",
        "....OO..OO..",
        "....oo..oo..",
    ]
    static let blink = [
        "....oo......",
        "....oO......",
        "..OOOOOOOO..",
        ".OOOOOOOOOO.",
        ".OOooOOooOO.",
        ".OOooOOooOO.",
        ".OOOOOOOOOO.",
        ".OOOOoooOOO.",
        "..OOOOOOOO..",
        "..OO..OO....",
        "..oo..oo....",
    ]

    /// Same sprite, tinted per agent.
    static func color(_ c: Character, _ agent: Agent = .claude) -> Color? {
        switch c {
        case "O": return Theme.accent(agent)
        case "o": return Theme.accentDark(agent)
        case "W": return .white
        case "B": return .black
        default: return nil
        }
    }
}

struct PixelSprite: View {
    let map: [String]
    var agent: Agent = .claude
    var scale: CGFloat = 2
    var flipped = false

    var body: some View {
        Canvas { ctx, _ in
            let cols = map[0].count
            for (y, row) in map.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let c = Sprite.color(ch, agent) else { continue }
                    let px = flipped ? cols - 1 - x : x
                    ctx.fill(Path(CGRect(x: CGFloat(px) * scale, y: CGFloat(y) * scale,
                                         width: scale, height: scale)),
                             with: .color(c))
                }
            }
        }
        .frame(width: CGFloat(map[0].count) * scale, height: CGFloat(map.count) * scale)
    }
}

// MARK: - Glass primitives

/// Obsidian glass card hanging from the notch: 90% black, specular top band,
/// liquid accent pooling bottom-right (and optionally bottom-left), hairline gradient rim.
/// No SwiftUI material: on macOS it blends behind the whole window rectangle, not the clipped shape.
struct Obsidian: View {
    let accent: Color
    var accent2: Color?
    var radius: CGFloat = 30

    var body: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)
        ZStack {
            // soft drop shadow — `.shadow()` rasterizes the whole transparent window as a grey rectangle
            shape.fill(.black.opacity(0.55)).blur(radius: 14).offset(y: 8)
            card(shape)
        }
    }

    private func card(_ shape: UnevenRoundedRectangle) -> some View {
        ZStack {
            shape.fill(Color(red: 0.02, green: 0.02, blue: 0.03).opacity(0.9))
            LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 70)
                .frame(maxHeight: .infinity, alignment: .top)
            Ellipse().fill(accent)
                .frame(width: 220, height: 90).blur(radius: 30).opacity(0.55)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 40, y: 30)
            if let accent2 {
                Ellipse().fill(accent2)
                    .frame(width: 180, height: 80).blur(radius: 30).opacity(0.4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .offset(x: -40, y: 30)
            }
            LinearGradient(colors: [accent.opacity(0), accent.opacity(0.9), accent.opacity(0)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(
            LinearGradient(stops: [.init(color: .white.opacity(0.55), location: 0),
                                   .init(color: .white.opacity(0.08), location: 0.35),
                                   .init(color: .white.opacity(0.03), location: 1)],
                           startPoint: .top, endPoint: .bottom),
            lineWidth: 1))
    }
}

struct AgentBadge: View {
    let agent: Agent
    var body: some View {
        Text(agent.rawValue)
            .font(Theme.mono(9))
            .foregroundStyle(Theme.accent(agent))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent(agent).opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent(agent).opacity(0.4), lineWidth: 1))
    }
}

/// Ring gauge (context usage, limits).
struct Ring: View {
    let pct: Double
    let accent: Color
    var size: CGFloat = 30
    var label: String?

    var body: some View {
        let w = size * 0.11
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: w)
            Circle().trim(from: 0, to: min(max(pct, 0.005), 1))
                .stroke(accent, style: StrokeStyle(lineWidth: w, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: accent.opacity(0.6), radius: 4)
            if let label {
                Text(label).font(Theme.mono(size * 0.27)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: size, height: size)
    }
}

struct GlowDot: View {
    let color: Color
    var glow = true
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .shadow(color: glow ? color.opacity(0.9) : .clear, radius: 4)
    }
}

// MARK: - Hosts

struct OverlayView: View {
    @ObservedObject var model: NotchModel
    let panelSize: CGSize

    var body: some View {
        ZStack(alignment: .top) {
            PeekingCharacter(model: model, width: panelSize.width)
            if model.expanded {
                ExpandedView(model: model)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(width: panelSize.width, height: panelSize.height, alignment: .top)
    }
}

/// Content of the small clickable panel that hosts the banner.
struct BannerHost: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        ZStack(alignment: .top) {
            if let ev = model.current, !model.expanded {
                Banner(event: ev, model: model)
                    .contentShape(Rectangle())
                    .onTapGesture { model.focusTerminal(ev.term) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Hidden by default. On a task event it walks ~80px out of the notch, lingers, walks back in.
/// While any session waits for user input it stays out, pacing, until answered.
struct PeekingCharacter: View {
    @ObservedObject var model: NotchModel
    let width: CGFloat
    @State private var x: CGFloat = 0 // offset from notch center
    @State private var dir: CGFloat = 1
    @State private var phase = Phase.hidden
    @State private var waitTicks = 0
    @State private var step = false
    @State private var blinkTicks = 0
    private let timer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    enum Phase { case hidden, exiting, waiting, returning }

    var body: some View {
        PixelSprite(map: currentMap, agent: model.lastAgent, flipped: dir < 0)
            .position(x: width / 2 + x, y: model.notchHeight - 11)
            .opacity(phase == .hidden ? 0 : 1)
            .onReceive(timer) { _ in tick() }
            .onChange(of: model.peekTrigger) { _, _ in startPeek() }
    }

    private var currentMap: [String] {
        if blinkTicks > 0 { return Sprite.blink }
        if phase == .waiting { return Sprite.walkA }
        return step ? Sprite.walkA : Sprite.walkB
    }

    private func startPeek() {
        if phase == .hidden {
            dir = Bool.random() ? 1 : -1
            x = dir * max(0, model.notchWidth / 2 - 20) // start tucked at the notch edge
            phase = .exiting
        }
    }

    private func tick() {
        step.toggle()
        blinkTicks = blinkTicks > 0 ? blinkTicks - 1 : (Int.random(in: 0..<40) == 0 ? 3 : 0)
        let outerEdge = model.notchWidth / 2 + 80
        switch phase {
        case .hidden:
            if model.anyWaiting { startPeek() }
        case .exiting:
            x += dir * 2
            if abs(x) >= outerEdge {
                phase = .waiting
                waitTicks = Int.random(in: 20...45)
                dir = -dir
            }
        case .waiting:
            if model.anyWaiting {
                // pace back and forth until the user answers
                if Int.random(in: 0..<30) == 0 { dir = -dir }
                x += dir * 1
                if abs(x) >= outerEdge { dir = x > 0 ? -1 : 1 }
                if abs(x) <= model.notchWidth / 2 + 10 { dir = x > 0 ? 1 : -1 }
            } else {
                waitTicks -= 1
                if waitTicks <= 0 {
                    phase = .returning
                    dir = x > 0 ? -1 : 1
                }
            }
        case .returning:
            x += dir * 2
            if abs(x) < 8 { phase = .hidden }
        }
        model.characterOut = phase != .hidden
    }
}

// MARK: - Banner

/// Obsidian banner extending down from the notch.
struct Banner: View {
    let event: TaskEvent
    @ObservedObject var model: NotchModel
    @State private var bob = false

    var body: some View {
        let accent = Theme.accent(event.agent)
        HStack(spacing: 12) {
            PixelSprite(map: Sprite.walkA, agent: event.agent, scale: 3)
                .offset(y: bob ? -2 : 2)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: bob)
                .onAppear { bob = true }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(event.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    AgentBadge(agent: event.agent)
                    if event.needsInput {
                        HStack(spacing: 4) {
                            GlowDot(color: Theme.warn)
                            Text("needs input").font(Theme.mono(9)).foregroundStyle(Theme.warn)
                        }
                    } else if let meta = event.meta {
                        Text(meta).font(Theme.mono(9)).foregroundStyle(Theme.dim)
                    }
                }
                Text(event.subtitle)
                    .font(Theme.mono(10))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if event.needsInput {
                Text("open ↗")
                    .font(Theme.mono(9))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.06)],
                                                              startPoint: .top, endPoint: .bottom)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
            } else if let pct = event.pct {
                Ring(pct: pct, accent: accent, label: "\(Int(pct * 100))")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, model.notchHeight + 10)
        .padding(.bottom, 14)
        .frame(minWidth: model.notchWidth + 60, maxWidth: 460)
        .background(Obsidian(accent: accent))
    }
}

// MARK: - Hover panel

/// Hover panel: sessions now, limits, recent completions, today's totals.
struct ExpandedView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("NOW")
                Spacer()
                if let f = model.agentFilter {
                    Text("showing \(f.rawValue)").font(Theme.mono(8)).foregroundStyle(Theme.accent(f).opacity(0.8))
                }
            }
            if model.visibleSessions.isEmpty {
                Text("No active sessions").font(Theme.mono(9)).foregroundStyle(Theme.dim)
            }
            ForEach(model.visibleSessions) { s in
                HStack(spacing: 8) {
                    GlowDot(color: dotColor(s), glow: s.state != .idle)
                    Text(s.project).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    AgentBadge(agent: s.agent)
                    if let m = s.model {
                        Text(m.replacingOccurrences(of: "claude-", with: ""))
                            .font(Theme.mono(9)).foregroundStyle(Theme.dim)
                    }
                    Spacer()
                    stateText(s)
                }
            }

            divider
            sectionLabel("LIMITS")
            if model.agentFilter == .codex {
                Text("codex limits unavailable").font(Theme.mono(9)).foregroundStyle(Theme.dim)
            } else if model.limits.isEmpty {
                Text("No limit data").font(Theme.mono(9)).foregroundStyle(Theme.dim)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                          alignment: .leading, spacing: 10) {
                    ForEach(model.limits) { b in
                        HStack(spacing: 10) {
                            Ring(pct: b.pct, accent: b.pct > 0.8 ? .red : Theme.accent(.claude), size: 34)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(Int(b.pct * 100))%").font(Theme.mono(12)).foregroundStyle(.white)
                                Text(b.label).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                                if let r = b.resetsAt {
                                    Text(resetText(r)).font(.system(size: 8)).foregroundStyle(Theme.dim)
                                }
                            }
                        }
                    }
                }
            }

            divider
            sectionLabel("RECENT")
            if model.visibleCompletions.isEmpty {
                Text("Nothing finished yet").font(Theme.mono(9)).foregroundStyle(Theme.dim)
            }
            ForEach(model.visibleCompletions) { c in
                HStack(spacing: 8) {
                    Text(c.project).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                    AgentBadge(agent: c.agent)
                    Spacer()
                    Text(ago(c.finishedAt)).font(Theme.mono(9)).foregroundStyle(Theme.dim)
                    Text(c.usage).font(Theme.mono(9)).foregroundStyle(Theme.accent(c.agent))
                }
            }

            divider
            HStack {
                sectionLabel("TODAY")
                Spacer()
                Text("\(fmtTokens(model.todayIn))↑ \(fmtTokens(model.todayOut))↓")
                    .font(Theme.mono(11)).foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, model.notchHeight + 12)
        .padding(.bottom, 16)
        .frame(width: 400, alignment: .leading)
        .background(Obsidian(accent: Theme.accent(model.agentFilter ?? .claude),
                             accent2: model.agentFilter == nil ? Theme.accent(.codex) : nil,
                             radius: 32))
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.vertical, 2)
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t).font(Theme.mono(8)).foregroundStyle(.white.opacity(0.38)).kerning(1.2)
    }

    private func dotColor(_ s: SessionInfo) -> Color {
        switch s.state {
        case .working: return Theme.accent(s.agent)
        case .waiting: return Theme.warn
        case .idle: return Color(white: 0.45)
        }
    }

    @ViewBuilder
    private func stateText(_ s: SessionInfo) -> some View {
        switch s.state {
        case .working:
            if let start = s.taskStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("working \(elapsed(start))")
                        .font(Theme.mono(9)).foregroundStyle(Theme.accent(s.agent))
                }
            } else {
                Text("working").font(Theme.mono(9)).foregroundStyle(Theme.accent(s.agent))
            }
        case .waiting:
            Text("needs input").font(Theme.mono(9)).foregroundStyle(Theme.warn)
        case .idle:
            Text("idle").font(Theme.mono(9)).foregroundStyle(Theme.dim)
        }
    }

    private func elapsed(_ d: Date) -> String {
        let s = Int(-d.timeIntervalSinceNow)
        return s >= 60 ? "\(s / 60)m\(String(format: "%02d", s % 60))s" : "\(s)s"
    }

    private func ago(_ d: Date) -> String {
        let m = Int(-d.timeIntervalSinceNow) / 60
        if m < 1 { return "now" }
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h"
    }

    private func resetText(_ d: Date) -> String {
        if d.timeIntervalSinceNow < 24 * 3600 {
            return "resets \(d.formatted(date: .omitted, time: .shortened))"
        }
        return "resets \(d.formatted(.dateTime.weekday(.abbreviated)))"
    }
}
