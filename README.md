# Notchification

A pixelated buddy that lives in your Mac's notch and keeps you posted on Claude Code and Codex.

## Behavior

- **Task starts** (`UserPromptSubmit` hook): the character walks ~80px out of the notch, lingers, and hides back in.
- **Claude asks a selection / needs input** (`Notification` hook): banner with the prompt message; the character stays out pacing until you answer.
- **Task completes** (`Stop` hook): banner with project name, token usage, and a Claude Code-style context-usage progress bar. **Click the banner** to focus the terminal it came from (exact kitty window via remote control when available, otherwise the terminal app).
- **Hover the notch** (or the character): expands into a panel with active sessions (working / needs input / idle, agent, model, elapsed time), usage limits as ring gauges (5h session, weekly, model weekly — same data as `/usage`), the last 5 completions, and today's token totals.

## How it works

- Claude Code hooks in `~/.claude/settings.json` wrap the hook JSON with terminal identity (`$TERM_PROGRAM`, `$KITTY_WINDOW_ID`, `$KITTY_LISTEN_ON`) and drop it into `~/.notchification/events/`.
- The app watches that folder and parses the session transcript for usage and model.
- Usage limits come from the same OAuth endpoint `/usage` uses; the app reads the token from `~/.claude/.credentials.json` or the macOS Keychain (allow the one-time Keychain prompt).

**Caveat:** Claude Code snapshots hooks at session startup — sessions already running when the hooks were installed won't report until restarted. The app also only knows about sessions from their events, so a task started before the app launched appears only on its next event.

## Running it

Requires macOS 14+ and Xcode (or the command line tools with a Swift 6 toolchain).

```sh
make run      # dev run from the terminal (Ctrl-C to stop)
make app      # build Notchification.app in the repo root
make install  # build + copy to /Applications + launch
```

The menu bar icon (little orange buddy) has the settings: character, sound on/off, launch at login (installed app only), and Quit.

### One-time hook setup

The app is fed by Claude Code hooks. Add this command to the `Stop`, `UserPromptSubmit`, `Notification`, and `SessionEnd` hooks in `~/.claude/settings.json` (create each event's entry if missing):

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "mkdir -p \"$HOME/.notchification/events\"; t=$(mktemp); { printf '{\"term_program\":\"%s\",\"kitty_win\":\"%s\",\"kitty_sock\":\"%s\",\"payload\":' \"$TERM_PROGRAM\" \"$KITTY_WINDOW_ID\" \"$KITTY_LISTEN_ON\"; cat; printf '}'; } > \"$t\"; mv \"$t\" \"$HOME/.notchification/events/$(date +%s)-$$.json\""
          }
        ]
      }
    ]
  }
}
```

Repeat the same hook object under `UserPromptSubmit`, `Notification`, and `SessionEnd`. Restart running Claude Code sessions afterwards — hooks are snapshotted at session start.

On first launch, allow the Keychain prompt so the app can read the Claude Code OAuth token for the usage-limit bars (or click Deny — everything else still works).

## Releases & branching

Releases are automated with semantic-release: every qualifying push to `main` analyzes
[conventional commits](https://www.conventionalcommits.org), bumps the version, publishes a
GitHub Release with generated notes, and attaches a built `Notchification.app.zip`.

- `feat:` → minor release, `fix:` → patch, `feat!:` / `BREAKING CHANGE:` → major
- `chore:` / `docs:` / `refactor:` → no release

Branching strategy (weekly cadence, trunk-based):

- **`main` is the release branch.** Anything merged here with a `feat:`/`fix:` commit ships immediately.
- **Day-to-day work goes on `dev`** (or short-lived feature branches). Merge `dev` → `main` once a week — that merge becomes the weekly release.
- **Emergency fixes** branch off `main`, land as a single `fix:` commit straight to `main`, and ship as a patch release right away — no waiting for the weekly merge.

### Codex

Codex CLI has a `notify` hook that runs a command with a JSON payload when a turn completes. Add this to
`~/.codex/config.toml`:

```toml
notify = ["sh", "-c", "mkdir -p \"$HOME/.notchification/events\"; t=$(mktemp); printf '{\"agent\":\"codex\",\"cwd\":\"%s\",\"term_program\":\"%s\",\"kitty_win\":\"%s\",\"kitty_sock\":\"%s\",\"payload\":%s}' \"$PWD\" \"$TERM_PROGRAM\" \"$KITTY_WINDOW_ID\" \"$KITTY_LISTEN_ON\" \"$1\" > \"$t\"; mv \"$t\" \"$HOME/.notchification/events/$(date +%s)-$$.json\"", "notchification"]
```

`notify` takes a single command. If it is already set (e.g. Codex Computer Use), point it at a
small script that runs both commands with `"$1"`.

Codex only reports turn completion, so Codex sessions show as idle with a completion banner (no
"working" state, no usage or limit data). The pet, banner and rows take the Codex mint tint.

### Picking an agent

Menu bar → **Agents** → All / Claude / Codex. Filters sessions, recent completions, banners, sound
and the pet to the chosen agent. Hidden agents are still tracked, so switching back is instant.

## Future

- Other agent platforms: write the same JSON shape (`hook_event_name`, `cwd`, `transcript_path` optional,
  `agent`) into `~/.notchification/events/`.
- Codex usage limits — no public endpoint yet.
- Custom character sheets: replace the pixel maps in `Sources/Views.swift` (`Sprite.walkA/walkB/blink`).
