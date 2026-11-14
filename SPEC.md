# ironpet v1 spec

A personal macOS desktop pet that floats above all windows, watches coding agents, and runs agent tasks for me.

## Decisions

| Area | Decision |
| --- | --- |
| Audience | Just me. Rough edges are fine. |
| Platform | macOS only, native Swift (AppKit + SwiftUI), Dock app. |
| v1 jobs | Agent watcher, quick chat, screen-aware help. |
| Later | Tasks, focus coach, calendar, dev signals, more chat backends, auto-hide. |
| Movement | Stays where dragged (position persists). Idle animations, eyes follow cursor. |
| Art | Ghost, a chibi white direwolf in a Night's Watch cloak, drawn in code by `tools/make_wolf.swift` (alternate theme: Mochi, a mint wolf) into the Codex v2 atlas layout (1536x2288, 8x11 cells of 192x208). |
| Success | I stop alt-tabbing to check agents, fire small tasks from the pet, use screenshot help daily. |

## Agent watcher

- Watches Cursor (IDE chats and CLI) and Claude Code via global hooks that the pet installs itself.
  - Merges into each watched agent's own config, preserving other entries (Superset, Orca): `~/.cursor/hooks.json`, `~/.claude/settings.json`, `~/.codex/hooks.json`, `~/.gemini/settings.json`. GitHub Copilot gets its own file in `~/.copilot/hooks/` and Pi gets an extension in `~/.pi/agent/extensions/` that calls the same hook script. `SessionStore` maps each agent's events (Codex uses Claude's names; Gemini's are BeforeAgent/AfterAgent/BeforeTool; Copilot's are camelCase; Pi's come from the extension). The agents offered are the ones found on this Mac.
  - Backs up each file once to `<file>.ironpet-backup` before the first write. Uninstall removes only ironpet entries.
- Hooks POST to the pet on `127.0.0.1` with a token from `~/.ironpet/token`. The hook never blocks or fails the agent (1s timeout, always exits 0).
- Status per session: `running`, `needsInput`, `done`, `failed`, `idle`.
- Pet shows one mood by priority `needsInput > failed > done > running` with a count badge. Click opens the session list.
- `done` and `failed` stay until acknowledged (clicked, jumped to, or a new prompt starts).
- Speech bubble (and optionally a macOS notification) on entering `needsInput`, `failed`, `done`.
- Jump to source: iTerm tab when the hook saw `ITERM_SESSION_ID`, otherwise the Cursor window for the workspace (`open -a Cursor <root>`). Exact Cursor chat/terminal tab is out of scope.

### Event mapping

| Source | Event | Effect |
| --- | --- | --- |
| Cursor | `sessionStart`, `beforeSubmitPrompt`, `postToolUse`, `afterAgentResponse` | running (headless CLI never fires `beforeSubmitPrompt`) |
| Cursor | `stop` (`status`: completed / error / aborted) | done / failed / idle |
| Cursor | `sessionEnd` | remove unless unacknowledged done/failed |
| Claude Code | `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | running |
| Claude Code | `Notification` (`permission_prompt`) | needsInput |
| Claude Code | `Stop` | done |
| Claude Code | `SessionEnd` | remove unless unacknowledged done/failed |

Cursor also runs Claude Code hooks from `~/.claude/settings.json` ("Third-Party Imports", on by default, always on in cursor-agent), so each Cursor event would arrive twice, the second time labelled Claude Code and often without a folder. The hook script exits early for `claude` when `CURSOR_VERSION` is set (only Cursor sets it for hooks), and the app drops `claude` events whose payload has `cursor_version`.

Known gap: Cursor has no hook for "waiting on the user's approval", so Cursor sessions never show `needsInput`.

## Quick chat (milestone 2)

- ⌥⌘G (or clicking the pet when no watched agent needs attention) opens a focused chat bubble. Opening the bubble activates ironpet (and closing it reactivates the previous app), because Wispr Flow (hold fn) finds the focused text field through the frontmost app's Accessibility tree. A dictation shows up as one large insert; with "Send automatically after dictation" on, it sends after 0.8s.
- Agents over ACP (`Chat/ACP/`): `ACPClient` speaks newline-delimited JSON-RPC, `ACPBackend` keeps one process per chat and maps `session/update` onto the chat's events. The agent comes from the catalog in `AgentCatalogData.swift` (generated from the ACP registry) and is chosen in the chat settings. Claude Code, Codex and Pi run through the `.mjs` adapters in `Contents/Resources/acp/` on the user's Node 22+ (or a Bun downloaded on request into `~/.ironpet/runtime`), pointed at the user's own CLI by `CLAUDE_CODE_EXECUTABLE`, `CODEX_PATH` or `PI_ACP_PI_COMMAND`. Executables are found on the login-shell PATH. Model choice is stored per agent; threads store the agent id, ACP session id and folder.
- Working directory: frontmost Cursor window (window title matched against `windowsState.openedWindows` in Cursor's `storage.json`) or iTerm session path (AppleScript `session.path`). Opened from any other app, a new chat shows a "Which project?" picker (recent folders, "No project" → `~/.ironpet/scratch`, or choose a folder) and won't send until one is picked.
- Approvals: the agent sends `session/request_permission` with the tool call (`kind`, `title`, `rawInput`) and a list of options. `ApprovalRules` decides whether ironpet answers at once (read, search, think, fetch, read-only MCP verbs, memory-file edits, and everything non-destructive in Auto mode) or shows a card. The reply picks `allow_once` or `reject_once`. Identical repeated requests within a turn share one card. ironpet cannot make an agent ask; an agent that does not send the request runs its tools unprompted.
- Auto mode: per-chat toggle handled in ironpet. The agent stays in its asking mode, ironpet auto-allows, and destructive commands (`rm -rf`, `git reset --hard`, `git push --force`, dropping tables) still require approval.
- Stop sends `session/cancel` and keeps the process. Threads are kept and reopened with `session/load`; the replayed transcript is ignored because the chat already holds it.
- ACP chat runs set `IRONPET_ACP_RUN=1`; the hook script skips them so they do not show up as external sessions.
- Memory: the agent writes editable markdown in `~/.ironpet/memory/` (`me.md` plus one file per project), injected into each chat.

## Screen-aware help (milestone 3)

- ⇧⌥⌘G captures the frontmost window, ⌃⌥⌘G a dragged region (also in the pet's right-click menu). Opens quick chat with the image attached.
- Screenshots go to `~/.ironpet/screenshots/` (last 30 kept), which is passed as `additionalDirectories` where the agent supports it. Images go as ACP image blocks when the agent advertises `promptCapabilities.image`; otherwise the prompt names the file.
- The app is signed with a local self-signed identity (`scripts/make_signing_identity.sh`, run by `install.sh` when missing) so TCC permissions survive rebuilds. `scripts/uninstall.sh` removes hooks and the login item by running the installed binary with `--uninstall` (which reuses `HookInstaller`), then deletes the app, Keychain item and preferences, and asks before deleting `~/.ironpet` and the identity.
- Needs Screen Recording permission (also unlocks Cursor window titles for workspace detection). No app exclusions.

## Pet states

| ironpet state | Atlas row |
| --- | --- |
| idle | 0 idle, plus look rows 9-10 following the cursor |
| working | 7 running |
| needs input | 6 waiting |
| done | 4 jumping once, then 8 review |
| failed | 5 failed |
| listening | 3 waving once, then idle |
| dragged | 1 / 2 running right / left |
| sleeping | idle frame 0, dimmed (no row exists); after 10 min with no activity |
| drinking (water reminder) | 11 sipping from a glass, ironpet extra row |
| stretching (stretch reminder) | 12 arms overhead, side stretch, ironpet extra row |

Rows 11-12 are ironpet additions below the Codex v2 layout, so ironpet's sheet is 1536x2704. Atlases without them (Codex pets, older sheets) play the waving row instead.

Reduced motion: frame 0 only. Pet art is loaded from `pet.sprite` in config.json, else `~/.ironpet/pet/spritesheet.{webp,png}`, else the Ghost sheet bundled in the app (generated by `scripts/bundle.sh` with `tools/make_wolf.swift`), else a drawn placeholder. OpenAI's built-in pet art is never used or bundled.

Status of milestone 2: built. Threads are saved to `~/.ironpet/threads/` and reopened from the history menu (reopened with `session/load`). Memory files are created on first use, injected into the first turn of each thread, reachable via `--add-dir`, and edits to them never need approval.

## Additions after v1

- **Agent summaries.** Per turn, the watcher records edited files (Cursor `postToolUse`, Claude `PostToolUse` on edit tools) and the final reply (Cursor `afterAgentResponse.text`; Claude `Stop.last_assistant_message` or the tail of `transcript_path`). The summary is "Edited N files · first sentence of the reply" and is used in done/failed notifications and the session list. Headless cursor-agent sends no reply event, so its summary is files only.
- **Approve from notifications.** Approval notifications (chat hidden) use a category with Allow / Deny actions that call the same `decide` as the chat card; resolving a card clears its notification.
- **Alerts (`Signals/`).** Off by default. With `integrations.githubAlerts` on (right-click → Integrations), `GitHubWatcher` polls each host in `~/.config/gh/hosts.yml` every 2 min with one GraphQL query (own open PRs with CI rollup and review decision, plus review requests). The first poll per host is silent; current CI failures and change requests still appear in the list. Transitions notify: CI → failed, CI → passed (from pending/failed), approved, changes requested, new review request. `SentryWatcher` polls `is:unresolved firstSeen:-1h` and `is:escalating` when configured. Alerts feed the pet's mood and badge; each offers Open, Ask Ghost (prefilled prompt, not auto-sent) and Dismiss.

- **MCP in chat.** Headless cursor-agent loads the user's MCP servers (signed in with `cursor-agent mcp login`). Cursor fires `preToolUse` (`MCP:<tool>`, allowed) and then `beforeMCPExecution` (tool, input, server URL), which ironpet gates; Claude Code tools named `mcp__<server>__<tool>` are gated on `PreToolUse`. Read-only verbs (`get`, `list`, `search`, `find`, `fetch`, `read`, `describe`, `whoami`, `lookup`, `show`, `count`) pass; everything else asks, and in Auto mode still asks if the arguments match the destructive pattern. Sentry: REST API for alert polling, Sentry MCP for "Ask Ghost" investigations.
- **Shared MCP sign-ins (opt-in, `integrations.shareMCPSignIns` in `~/.ironpet/config.json`).** cursor-agent keeps OAuth sign-ins per workspace in `~/.cursor/projects/<slug>/mcp-auth.json` (slug = path with non-alphanumerics as `-`). Before each pet chat run, `MCPAuthSharing` copies every server entry that has tokens (with its client registration) from the most recently modified file into the run's workspace file(s), covering both `/tmp/...` and `/private/tmp/...` slugs. This relies on an internal Cursor file format.
- **Break reminders (`Reminders/`).** Defaults: water 45 min, stretch 60 min, eyes 20 min (configurable). Every 30 s `ReminderScheduler` adds the elapsed time to each enabled reminder unless the system idle time (`CGEventSource.secondsSinceLastEventType`) or the gap since the last tick is 5 min or more, which resets all of them. A reminder is due at its interval, or at 75% of it while a watched agent or Ghost chat is running; everything at 75% or more goes out in one notification. Nothing goes out while the chat is open, an approval is pending, or a session needs input. Actions: Done (Ghost jumps) and Snooze (due again in 10 min). When one arrives Ghost drinks (water), stretches (stretch) or waves (eyes), one after another for a batch. Per-reminder toggles and Pause live in the right-click and Dock menus and in Settings; intervals, idle reset and snooze are in `reminders` in config.json.
- **Speech bubbles (`Pet/Bubbles.swift`, `App/Announcer.swift`).** Every announcement (agent needs input / failed / done, chat approvals, alerts, reminders, chat finished) is a bubble in a transparent non-activating panel beside the pet, on the side with more room, tail pointing at his head; it follows him when dragged. Up to 4 stack, newest at the bottom; the same id replaces (one per session, approval, alert). Lifetimes: approvals until answered, reminders 3 min, failed / needs input / alerts 40-45 s, done and passed 15 s, paused while hovered. Bubbles carry the same actions the notifications had (Allow / Deny, Done / Snooze, Open / Ask Ghost) and play the "Pop" sound unless the news is good. Hidden while the chat or agents window is open. macOS notifications are off by default; right-click → "Also show macOS notifications" (`notifications.system`) sends both.
- **Agents window (`Pet/AgentsPanel.swift`).** A key panel instead of an NSPopover so it is clamped to the pet's screen (NSPopover got cut off with the pet at the right edge). Opens below the pet, or above when there is no room; closes on Esc or losing focus. Tabs: Agents and Alerts.

- **Configuration (`Support/Config.swift`, `App/SettingsWindow.swift`).** `~/.ironpet/config.json` holds pet name and sprite, hotkeys, reminders and integrations. The file is laid over the encoded defaults before decoding, so it only needs changed keys; values are clamped (minutes ≥ 1, empty name → default). An invalid file yields defaults plus an error shown in Settings, and is copied to `config.invalid.json` before Settings overwrites it. `ConfigStore` (main actor) polls the file's modification date every 2 s; `AppDelegate` re-registers hotkeys, starts/stops GitHub polling and reloads the atlas on change, everything else reads the config where it's used. Hotkeys are Carbon `RegisterEventHotKey` from strings like `cmd+opt+g`; a combination another app holds is reported in Settings, and hotkeys are unregistered while the Settings recorder is listening. Chat backend, model, recent folders and window size stay in UserDefaults as UI state.

- **First run (`App/SetupWindow.swift`).** Shown when setup was never finished or skipped and there is no `config.json` (a config brought from another Mac counts as set up). It offers pet name, hooks per agent (pre-ticked when the tool is detected or ironpet's hooks are already there), launch at login, break reminders and GitHub alerts. Start writes `config.json`, installs the chosen hooks, removes unticked ones left by an older version, and switches chat to Claude Code if cursor-agent is missing. Not now or closing the window writes the default config (no hooks). Hooks are recorded as `integrations.cursorHooks` / `claudeHooks`; on each launch the chosen ones are refreshed, and toggling them in Settings installs or removes only that agent's hooks.

## Voice notes

Opt-in (`voice.enabled`, off by default). `VoiceController` is one state machine (idle, recording, transcribing) driven by the mic button, the hold-to-talk hotkey (`hotkeys.voice`, registered only while enabled) and the `--test-mode` endpoints under `/test/voice/*`, which feed a WAV file through the same states. `MicrophoneSource` records with AVAudioEngine and converts to 16 kHz mono; `Transcriber` posts the WAV to `{baseUrl}/audio/transcriptions` with `file`, `model` and an explicit `response_format=json` (mlx-audio defaults to `ndjson`). The API key is in the Keychain (`ironpet.voice`), never in config.json. The waveform reads a `LevelBuffer` on its own display-rate timeline, so level updates never re-render the chat. A failed transcription keeps the recording in memory so Retry can re-send it. Recordings are capped at 5 minutes instead of being chunked.

## Testing

`python3 scripts/e2e.py [scenario ...]` (cursor, claude, auto, picker, iterm, capture, summaries, notification, github, setup, settings; mcp, sentry, voice and voice-key only when named) relaunches the installed app with `--test-mode`, which enables token-protected `/test/*` endpoints that drive the same code paths as the UI (show chat, send, Allow/Deny, session jump, capture). It runs real cursor-agent and Claude Code turns, checks files on disk and iTerm state via AppleScript, then relaunches the app normally. Test endpoints do not exist outside `--test-mode`.

## Milestones

1. Pet window + agent watcher + hook installer + notifications.
2. Quick chat with cursor-agent, approvals, auto mode, threads, memory.
3. Screenshot hotkeys and workspace detection via Cursor window titles.
