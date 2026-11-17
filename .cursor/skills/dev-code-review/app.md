# App review — `Sources/IronPet`, `Tests/IronPetTests`, `Package.swift`

The design is `SPEC.md`. Swift 5.10 tools (Swift 5 language mode), macOS 14 minimum, AppKit for windows, panels, menus and hotkeys, SwiftUI for the content inside them through `NSHostingView`. One SwiftPM executable target and one XCTest target. No third-party Swift dependencies.

## Layout and ownership

| Folder | Owns |
|---|---|
| `main.swift` | Entry point: `--render-previews`, `--uninstall`, `--test-mode` flags, then `AppDelegate` |
| `App/` | App glue: `AppDelegate` (menus, status, wiring), Settings and welcome windows, hotkeys (Carbon), login item, notifications (`Notifier`), speech-bubble announcements (`Announcer`), jumping to a session's terminal or editor (`SourceJumper`, `Editors`), `TestControl` (`/test/*`, test mode only), `PreviewRenderer` (README screenshots) |
| `Pet/` | The pet window and sprite atlas (`PetController`, `PetView`, `Atlas`, `PetMood`), speech bubbles, the ironpet window (`IronPetPanel`: chat, agents, alerts, tasks, transcripts, actions and automations in one sidebar window) |
| `Sessions/` | Watched agent sessions: hook event mapping to status (`SessionStore`, `AgentSession`), process ancestry (`ProcessTree`) |
| `Hooks/` | The hook shell script (`HookScript`) and merging it into each agent's config, with backups and uninstall (`HookInstaller`) |
| `Bridge/` | Local HTTP server on `127.0.0.1` with the token (`EventServer`), the status snapshot it serves |
| `Chat/` | The chat view, sessions, saved threads, memory notes, markdown, screenshots and image/file intake, Wispr Flow bridge, workspace detection, MCP sign-in sharing |
| `Chat/ACP/` | Agent Client Protocol: JSON-RPC client over stdio (`ACPClient`), one process per chat (`ACPBackend`), runtimes for the bundled adapters and the Bun download (`ACPRuntime`), tool calls and `ApprovalRules` (`ACPToolCall`), the agent catalog (`AgentCatalogData.swift` is generated) |
| `Signals/` | GitHub (via `gh`) and Sentry polling and the alert store |
| `Voice/` | Voice notes: hold-to-talk key, microphone capture and conversion, WAV encoding, the transcription client, the level buffer and waveform bar, the Keychain key |
| `Meeting/` | Meeting transcripts: call detection, track sources (mic and ScreenCaptureKit), recorder and chunker, transcript assembly, summary, panel |
| `Reminders/` | Break reminders scheduler |
| `Activity/` | The local activity log in `ironpet.db` (`ActivityEvent`, `ActivityLog`), the digest built from it (`ActivityDigest`), away detection and the welcome back summary (`AwayTracker`, `WelcomeBack`) |
| `Support/` | `Config` and `ConfigStore`, `Paths` (everything under `~/.ironpet`) |
| `Tests/IronPetTests/` | XCTest, one file per area (`ApprovalRulesTests`, `HookInstallerTests`, `ConfigTests`, `ACPClientTests`, `MeetingTests`, …) |

Findings on this surface:

- A file that belongs to one area but sits in another (for example ACP parsing in `ChatView`, hook mapping in `AppDelegate`) is **Medium**.
- Rules that can be tested without a window (approval policy, event mapping, config parsing, chunking, transcript layout, markdown) written inside a view or `AppDelegate`, so no test can reach them, is **Medium**.
- A path under `~/.ironpet` built by hand instead of through `Paths` is **Low**.
- A hand edit to `Chat/ACP/AgentCatalogData.swift` is **High**: regenerate it with `python3 scripts/gen_agent_catalog.py`.

## Rules to check

- **Hooks.** `HookScript` stays a reporter: `curl` with `--connect-timeout 0.3 -m 1`, `exit 0` on every path, early exit for `IRONPET_ACP_RUN` and for Claude hooks fired by Cursor (`CURSOR_VERSION`). `HookInstaller` merges into the agent's file without touching other entries, backs the file up once, removes only its own entries on uninstall, and only deletes files it owns when they carry its marker (Copilot `ironpet.json`, Pi `ironpet.ts`). Every behavior change has a case in `HookInstallerTests`.
- **Event mapping.** A new agent or event updates `SessionStore`, the mapping table in `SPEC.md` › Event mapping, and `SessionMappingTests`. `done` / `failed` stay until acknowledged.
- **Approvals.** `ApprovalRules.policy` allows only `read`, `search`, `think`, `fetch`, memory-file edits, read-only MCP verbs, and non-destructive calls in Auto mode. Anything else shows a card. Identical requests within a turn share one card. A request that cannot be shown is answered with a cancel. Every rule change has a case in `ApprovalRulesTests` and a line in `SECURITY.md` › Approvals.
- **ACP.** The agent process stays alive between messages; Stop sends `session/cancel`; reopening a thread uses `session/load` and ignores the replay. ironpet declares no `fs` or `terminal` client capability. Chat runs set `IRONPET_ACP_RUN=1`. Executables are found on the login-shell `PATH`. The summary agent for meetings refuses every permission request. JSON-RPC framing changes have a case in `ACPClientTests`.
- **Local server and test mode.** `EventServer` binds `127.0.0.1`, checks the token on every request and answers 403 otherwise. Routes under `/test/*` are registered only when `--test-mode` is set. A test endpoint drives the same code path as the UI, not a parallel one.
- **Config.** New settings go in `Config` with a default, decoding laid over the encoded defaults, and clamping. `ConfigStore` (main actor) picks changes up by polling; code reads the config where it is used. UserDefaults holds UI state only. An invalid file keeps working with defaults and an error in Settings.
- **Secrets and privacy.** Keys and tokens through the Keychain helpers. Microphone and screen access are requested on first use of an opt-in feature. Meeting audio stays in `~/.ironpet/meetings/` and is never deleted by the app. Nothing is logged that includes a token, a prompt, or a transcript.
- **Concurrency.** UI types and stores on `@MainActor`. No blocking file, process or network work on the main thread. `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency`, or `MainActor.assumeIsolated` added without a comment on that line saying why it is safe is **High**. Timers, observers and closures held by panels capture `self` weakly; a retain cycle in a long-lived object is **Medium**.
- **UI.** Panels are non-activating where they are today (bubbles), clamped to the pet's screen, and keyboard-reachable (Esc closes, ⌘↩ allows). Reduced motion shows frame 0 only. Bubble lifetimes follow `SPEC.md` › Speech bubbles. Check controls against `apple-design` with the macOS files.
- **Tests.** XCTest only, one test file per area, temp directories created and removed per test. A bug fix comes with a test that fails without it when the logic is reachable from a test.

## Skills to open

Start with `.agents/skills/swift/SKILL.md` (it holds ironpet's conventions), then the guides under `.agents/skills/swift/skills/` that match the diff:

| Diff touches | Skills |
|---|---|
| Any Swift | `swift-language`, `swift-api-design-guidelines` |
| `Task`, queues, `Sendable`, `@MainActor`, `Chat/ACP/`, `Meeting/`, `Voice/`, `Bridge/` | `swift-concurrency` |
| `Config`, JSON-RPC, hook payloads, threads, transcription responses | `swift-codable` |
| Keychain, tokens | `swift-security` |
| `Transcriber`, `SentryWatcher`, `ACPRuntime` download, `EventServer` | `ios-networking` |
| SwiftUI views | `swiftui-patterns`, `swiftui-layout-components` |
| Bubbles, waveform, pet effects | `swiftui-animation` |
| Chat transcript, waveform, anything that re-renders often | `swiftui-performance` |
| Leaks, hangs, crashes | `debugging-instruments` |
| Panels, Settings, setup, keyboard access | `ios-accessibility`, `.agents/skills/apple-design/SKILL.md` (load `designing-for-macos.md`, `windows.md`, `the-menu-bar.md`, `keyboards.md`) |
| `Notifier` | `push-notifications` (local notifications only) |

The architecture in `SPEC.md` (AppKit owners with SwiftUI content, `ObservableObject` stores, one process per chat) is decided. Do not raise findings asking for `@Observable`, TCA, a SwiftUI `App` lifecycle, or another architecture.

## Gates

From the repo root:

```bash
swift build                 # debug build
swift test                  # XCTest suite
./scripts/bundle.sh         # release build of build/IronPet.app with the adapters and sprite sheet (needs Bun and npm)
./scripts/check_adapters.sh build/IronPet.app
```

CI (`.github/workflows/ci.yml`) runs the same four plus the script syntax checks in `tooling.md`. Run `bundle.sh` when the diff touches `Package.swift`, resources, the sprite tools, the adapters, or anything `bundle.sh` copies; otherwise mark it `N/A`.

Installed-app and e2e checks change the user's machine (see Ground rules in `SKILL.md`), so they are residual risks unless the user asked for them. Name the scenarios that cover the diff:

| Diff touches | e2e scenarios (`python3 scripts/e2e.py <names>`) |
|---|---|
| `Chat/ACP/`, chat sending, threads | `cursor`, `cursor-session`, `claude`, `codex`, `agents` |
| `ApprovalRules`, approval cards, Auto mode | `cursor`, `claude`, `auto`, `asks` (opt-in), `notification` |
| `ACPRuntime`, Bun download | `runtime` (opt-in) |
| `WorkspaceDetector`, folder picker | `picker` |
| `SourceJumper`, iTerm | `iterm` |
| `ScreenCapture` | `capture` |
| `Sessions/`, `Hooks/`, summaries | `summaries`, `setup` |
| `Signals/` | `github`; `sentry` (opt-in, needs Sentry MCP) |
| MCP gating, `MCPAuthSharing` | `mcp` (opt-in, needs Langfuse MCP) |
| `SetupWindow`, `SettingsWindow`, `IronPetPanel`, `Config` | `setup`, `settings` (take over the keyboard) |
| `Voice/` | `voice`, `voice-key` (opt-in, need a local mlx-audio server) |
| `Meeting/` | `meeting`, `meeting-system` (opt-in) |
| `Tasks/`, task tools, `IronPet tasks` | `tasks` |
| `Activity/`, digest bubbles | `welcome-back` |

Summary rows for the **App** table:

| Check | Result |
|---|---|
| `swift build` | |
| `swift test` | count |
| App bundle | `bundle.sh` + `check_adapters.sh`, or `N/A — <reason>` |
| Safety rules | Hooks, approvals, local server, test mode, writes outside `~/.ironpet` |
| Tests for risky changes | `ApprovalRulesTests`, `HookInstallerTests`, `SessionMappingTests`, `ConfigTests` cover the change |
| Config and secrets | New keys in `Config` with defaults and in README; secrets in the Keychain |
| Concurrency and main thread | Isolation reasoned about; no blocking I/O on the main thread |
| Generated files | `AgentCatalogData.swift` regenerated, not hand-edited, or `N/A` |
| e2e scenarios | Which cover the diff, and whether they ran |
| Design / HIG | `apple-design` checked for UI changes, or `N/A` |
