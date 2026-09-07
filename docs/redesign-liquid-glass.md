# UI redesign — liquid glass + gradients, Claude & Codex

Figma: https://www.figma.com/design/vMPWs7zf2CuoOCuZn7FNUf/Notchification?node-id=0-1

Three directions, each with four states (idle peek, Claude completion banner,
Codex needs-input banner, hover panel). Pick one; the code follows the pick.

| # | Direction | Feel |
|---|-----------|------|
| 1 | Frosted Ember | Dark smoked glass attached to the notch, hairline gradient rim, ember glow in the agent colour. Closest to today's app. |
| 2 | Aurora Glass | Light frosted pill floating below the notch, rainbow rim, specular band, pet on a glass shelf. Most colourful. |
| 3 | Obsidian Liquid | Near-opaque black glass, bright specular rim, liquid accent pooling at the bottom edge, mono details, ring gauges. Most compact. |

## Common to all three

- Agent accent: Claude = orange `#FF8C1A`, Codex = mint `#2BC79E`. Needs-input = amber `#FFD34D`.
- Pet stays. Same sprite, tinted per agent. Peeks on task start, paces while any session waits.
- Banner 420–460 pt, panel 400–420 pt, notch 200×32 (real values come from `safeAreaInsets` as today).
- Sessions / recent / limits rows carry an agent chip so mixed Claude + Codex lists stay readable.

## Codex support (implementation notes, not yet built)

- Codex writes the same event JSON into `~/.notchification/events/` (see README "Future"), plus an
  `agent` field (`"claude"` | `"codex"`); missing `agent` defaults to `claude` so existing hooks keep working.
- `SessionInfo` / `Completion` / `TaskEvent` gain `agent`; views pick accent + pet tint from it.
- Codex limits: separate `LimitBucket` ids prefixed `codex-`; source TBD (no public usage endpoint yet).

## SwiftUI mapping

- Glass = `.background(.ultraThinMaterial)` / `NSVisualEffectView` + overlay `LinearGradient` stroke + `.shadow`.
- Glow blobs = blurred `Circle().fill(accent).blur(radius:)` clipped by the card shape.
- Ring gauges (design 3) = `Circle().trim(from:to:).stroke(style:)`.
