import SwiftUI

// ponytail: placeholder pixel art, swap maps when real character sheets arrive
enum Sprite {
    static let orange = Color(red: 1.0, green: 0.55, blue: 0.1)
    static let dimText = Color.white.opacity(0.45)

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

    static func color(_ c: Character) -> Color? {
        switch c {
        case "O": return orange
        case "o": return Color(red: 0.85, green: 0.4, blue: 0.05)
        case "W": return .white
        case "B": return .black
        default: return nil
        }
    }
}

struct PixelSprite: View {
    let map: [String]
    var scale: CGFloat = 2
    var flipped = false

    var body: some View {
        Canvas { ctx, _ in
            let cols = map[0].count
            for (y, row) in map.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let c = Sprite.color(ch) else { continue }
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

/// Claude Code-style context usage bar.
struct ContextBar: View {
    let pct: Double

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule()
                        .fill(pct > 0.8 ? Color.red : Sprite.orange)
                        .frame(width: max(3, g.size.width * min(pct, 1)))
                }
            }
            .frame(height: 4)
            Text("\(Int(pct * 100))%")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(Sprite.dimText)
        }
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
        PixelSprite(map: currentMap, flipped: dir < 0)
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

/// Dynamic-island-style banner extending down from the notch.
struct Banner: View {
    let event: TaskEvent
    @ObservedObject var model: NotchModel
    @State private var bob = false

    var body: some View {
        HStack(spacing: 12) {
            PixelSprite(map: Sprite.walkA, scale: 2)
                .offset(y: bob ? -2 : 2)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: bob)
                .onAppear { bob = true }
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(event.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(event.needsInput ? .yellow : Sprite.orange)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, model.notchHeight + 8)
        .padding(.bottom, 12)
        .frame(minWidth: model.notchWidth + 60, maxWidth: 420)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18)
                .fill(.black)
        )
    }
}

/// Hover panel: sessions now, recent completions, today's totals.
struct ExpandedView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("NOW")
            if model.sessions.isEmpty {
                Text("No active sessions")
                    .font(.system(size: 11)).foregroundStyle(Sprite.dimText)
            }
            ForEach(model.sessions) { s in
                HStack(spacing: 8) {
                    Circle()
                        .fill(dotColor(s.state))
                        .frame(width: 6, height: 6)
                    Text(s.project)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    if let m = s.model {
                        Text(m.replacingOccurrences(of: "claude-", with: ""))
                            .font(.system(size: 10)).foregroundStyle(Sprite.dimText)
                    }
                    Spacer()
                    stateText(s)
                }
            }

            divider
            sectionLabel("LIMITS")
            if model.limits.isEmpty {
                Text("No limit data")
                    .font(.system(size: 11)).foregroundStyle(Sprite.dimText)
            }
            ForEach(model.limits) { b in
                HStack(spacing: 8) {
                    Text(b.label)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 100, alignment: .leading)
                    ContextBar(pct: b.pct)
                    if let r = b.resetsAt {
                        Text(resetText(r))
                            .font(.system(size: 9)).foregroundStyle(Sprite.dimText)
                    }
                }
            }

            divider
            sectionLabel("RECENT")
            if model.completions.isEmpty {
                Text("Nothing finished yet")
                    .font(.system(size: 11)).foregroundStyle(Sprite.dimText)
            }
            ForEach(model.completions) { c in
                HStack {
                    Text(c.project)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                    Spacer()
                    Text(ago(c.finishedAt))
                        .font(.system(size: 10)).foregroundStyle(Sprite.dimText)
                    Text(c.usage)
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Sprite.orange)
                }
            }

            divider
            HStack {
                sectionLabel("TODAY")
                Spacer()
                Text("\(fmtTokens(model.todayIn))↑ \(fmtTokens(model.todayOut))↓ tokens")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Sprite.orange)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, model.notchHeight + 10)
        .padding(.bottom, 14)
        .frame(width: 380, alignment: .leading)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22)
                .fill(.black)
        )
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.vertical, 2)
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 9, weight: .bold)).foregroundStyle(Sprite.dimText).kerning(1)
    }

    private func dotColor(_ s: SessionInfo.State) -> Color {
        switch s {
        case .working: return Sprite.orange
        case .waiting: return .yellow
        case .idle: return .gray
        }
    }

    @ViewBuilder
    private func stateText(_ s: SessionInfo) -> some View {
        switch s.state {
        case .working:
            if let start = s.taskStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("working · \(elapsed(start))")
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(Sprite.orange)
                }
            } else {
                Text("working").font(.system(size: 10)).foregroundStyle(Sprite.orange)
            }
        case .waiting:
            Text("needs input")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.yellow)
        case .idle:
            Text("idle").font(.system(size: 10)).foregroundStyle(Sprite.dimText)
        }
    }

    private func elapsed(_ d: Date) -> String {
        let s = Int(-d.timeIntervalSinceNow)
        return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }

    private func ago(_ d: Date) -> String {
        let m = Int(-d.timeIntervalSinceNow) / 60
        if m < 1 { return "now" }
        if m < 60 { return "\(m)m ago" }
        return "\(m / 60)h ago"
    }

    private func resetText(_ d: Date) -> String {
        if d.timeIntervalSinceNow < 24 * 3600 {
            return "resets \(d.formatted(date: .omitted, time: .shortened))"
        }
        return "resets \(d.formatted(.dateTime.weekday(.abbreviated)))"
    }
}
