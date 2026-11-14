# Security

ironpet runs on your Mac with your user's permissions, watches your coding agents, and can start agents that edit files and run commands. This page lists what it touches and what protects it, so you can decide what to turn on. Nothing outside `~/.ironpet` is changed until you confirm the welcome window on first launch.

## Reporting a vulnerability

Please use GitHub's **Report a vulnerability** button on the repository's Security tab instead of a public issue. You'll get a reply within a week.

## What runs where

- **Local HTTP server.** The app listens on `127.0.0.1` only (port written to `~/.ironpet/port`). Every request has to carry the random 256-bit token in `~/.ironpet/token` (mode `0600`), or it gets a 403. The `/test/*` endpoints exist only when the app is started with `--test-mode`.
- **Hooks.** `~/.ironpet/bin/ironpet-hook` is called by the agents you choose to watch (Cursor, Claude Code, Codex, Gemini CLI, GitHub Copilot and Pi), so ironpet can show sessions you started yourself. The welcome window and Settings list only agents found on this Mac, and each is off until you turn it on. Hooks only report status: short timeouts, always exit 0, never block or fail your agents. They no longer approve anything. A chat that ironpet runs sets `IRONPET_ACP_RUN=1` on the agent, and the hook script skips those runs.
- **Agents over ACP.** Chat talks to the agent over the [Agent Client Protocol](https://agentclientprotocol.com) (JSON-RPC on the agent's stdin and stdout). ironpet starts the agent you pick from your own install, found through your login shell's `PATH`: `cursor-agent acp`, `gemini --acp`, `opencode acp` and so on. Claude Code, Codex and Pi have no ACP mode of their own, so ironpet runs a small adapter (a single `.mjs` file in `IronPet.app/Contents/Resources/acp/`) on your Node 22 or newer. The adapter drives your installed `claude`, `codex` or `pi`, which ironpet passes in `CLAUDE_CODE_EXECUTABLE`, `CODEX_PATH` or `PI_ACP_PI_COMMAND`. The app bundle contains no agent and no JavaScript runtime. ironpet declares no `fs` or `terminal` client capability, so agents read and write files and run commands with their own tools, under their own permission settings. It lists an agent in the picker only when its command exists and, for agents with native ACP, answers `initialize` (ironpet starts each one briefly to check).
- **Approvals.** The agent decides when to ask. When it wants to run a tool it may send `session/request_permission`, and ironpet either answers or shows an Allow / Deny card. File edits, deletions and shell commands ask. Reads, searches, web fetches and read-only MCP tools (names starting with `get`, `list`, `search` and similar) are allowed without a card. The per-chat **Auto** switch skips the cards for that chat only. The agent stays in its normal asking mode and ironpet answers for it. Even with Auto on, commands that match a destructive pattern (`rm -rf`, `git push --force`, `git reset --hard`, `git clean -f`, `DROP TABLE`, `mkfs`, `dd if=`, …) still ask. Auto resets with each new chat and when you open a chat from history. It is remembered only for the chat that was open when the app quit, so a restart doesn't silently turn it off mid-task. Writes to ironpet's own memory notes (`~/.ironpet/memory`) don't ask. A request that ironpet cannot show (the app quit, or the turn was stopped) is answered with a cancel, and an unanswered card waits until you decide or stop the turn.
- **Approval cards depend on the agent.** ironpet cannot force an agent to send `session/request_permission`. An agent that runs a tool without asking, because of its own settings, an allow-list or a "never ask" mode, does so without any card, and ironpet only sees the tool call afterwards. For example, `cursor-agent acp` runs commands on its own allow-list (such as `ls`) without asking and asks for the rest. Check an agent's own permission settings before you rely on the cards. The destructive-command check applies only to requests the agent sends.
- **One download, only when you allow it.** If you pick Claude Code, Codex or Pi and your PATH has no Node 22 or newer, the chat shows a **Download Bun** button instead of failing. Only a click starts the download. ironpet fetches Bun 1.4.4 (about 40 MB) from `github.com/oven-sh/bun`, reads the expected SHA-256 from the same release's `SHASUMS256.txt`, and unpacks the archive only if the checksum matches. It then clears the macOS quarantine flag on that file and keeps it at `~/.ironpet/runtime/bun`. A mismatch or a failed download shows an error and runs nothing. This is the only network request ironpet makes on its own initiative besides the optional GitHub, Sentry and voice features below.
- **No API keys.** Chat goes through the sign-in your agent already has. If an agent says it needs you to sign in, ironpet shows a button: for an agent that signs in over ACP it calls `authenticate`, and for a terminal sign-in it opens Terminal with the command the agent gave. ironpet sends nothing anywhere itself, except the optional GitHub and Sentry polling below, voice notes if you turn them on, and the Bun download above.

## Files ironpet writes outside `~/.ironpet`

| File | When | Undo |
| --- | --- | --- |
| `~/.cursor/hooks.json` | Only if you choose to watch Cursor (welcome window or Settings) | Settings → General → Watch Cursor off. The original is backed up as `hooks.json.ironpet-backup` |
| `~/.claude/settings.json` | Only if you choose to watch Claude Code | Settings → General → Watch Claude Code off. Backed up as `settings.json.ironpet-backup` |
| `~/.codex/hooks.json` | Only if you choose to watch Codex. Codex still asks you to trust the hooks in its `/hooks` screen before it runs them | Watch Codex off. Backed up as `hooks.json.ironpet-backup` |
| `~/.gemini/settings.json` | Only if you choose to watch Gemini CLI | Watch Gemini CLI off. Backed up as `settings.json.ironpet-backup` |
| `~/.copilot/hooks/ironpet.json` | Only if you choose to watch GitHub Copilot. A file ironpet owns | Watch GitHub Copilot off deletes it |
| `~/.pi/agent/extensions/ironpet.ts` | Only if you choose to watch Pi. A small extension that runs the hook script. A file ironpet owns | Watch Pi off deletes it, but only if it carries ironpet's first-line marker |
| `~/.cursor/projects/*/mcp-auth.json` | Only with **Share MCP sign-ins** on (off by default) | Turn it off; copied entries stay until you sign out of that server |
| Login item | Only if you leave Launch at login on in the welcome window | Settings → General, or right-click → Launch at login |
| Keychain item `ironpet.sentry` | Only if you run `scripts/configure_sentry.sh` | `security delete-generic-password -s ironpet.sentry` |
| Keychain item `ironpet.voice` | Only if you save an API key in Settings → Voice | Remove in Settings → Voice, or `security delete-generic-password -s ironpet.voice` |

## What ironpet reads

- `~/.config/gh/hosts.yml` and the `gh` CLI, only with GitHub alerts on (off by default).
- `~/.ironpet/sentry.json` and its Keychain token, only after you've configured Sentry.
- Cursor's `storage.json` and iTerm2 via AppleScript, to find the project you're working in.
- The microphone, only while you record a voice note with voice notes on (off by default). macOS asks for permission the first time you record, not before.
- The microphone and one app's audio (or all system audio, through ScreenCaptureKit), only while a meeting transcript is recording, with meeting transcripts on (off by default). macOS asks for microphone and Screen & System Audio Recording access the first time you start one.
- Wispr Flow's local database, to pick up dictation while the chat is open.

## Data in `~/.ironpet`

| Path | Contents |
| --- | --- |
| `config.json` | Your settings |
| `threads/` | Saved chats (agent, ACP session id, folder and the visible transcript) |
| `runtime/` | Bun, only if you allowed the download |
| `memory/` | Markdown notes Ghost keeps about you and your projects (you can edit them) |
| `screenshots/` | Screen captures you attached to chats |
| `scratch/` | Working folder for chats that aren't about a project |
| `meetings/` | One folder per meeting transcript: the recorded audio as WAV chunks, `transcript.md`, `summary.md`. Kept until you delete them |
| `token`, `port` | Local server credentials |

The chat that was open when the app quit is reopened on launch. Its id, its Auto switch, your unsent draft and the paths of attached screenshots are kept in the app's preferences (`dev.ironpet.app`), which `uninstall.sh` deletes.

Delete the folder to erase all of it, or run `./scripts/uninstall.sh` to remove ironpet completely (hooks, login item, app, Keychain item, and optionally this folder).

## Voice notes send audio to a server you choose

With voice notes on (Settings → Voice, off by default), each recording is uploaded as a WAV file to the base URL you set, along with the model name and, if you saved one, an `Authorization: Bearer` header carrying your API key. That may be a service such as OpenAI or Groq, or a server on your own Mac. ironpet does not choose the server or fall back to another. While the feature is off, the microphone is never opened and nothing is sent, apart from the one-second test tone that the Test connection button uploads when you press it. The key lives in the Keychain item `ironpet.voice` and is never written to `~/.ironpet`. Recordings are held in memory only: the last one is kept until its transcription succeeds, so Retry can send it again, and none is written to disk. A plain `http://` base URL sends audio and the key unencrypted, so use it only for `localhost`.

## Meeting transcripts record other people

With meeting transcripts on (Settings → Meetings, off by default), starting a meeting records two tracks until you stop: your microphone ("Me") and the audio of the app you picked, or all system audio ("Them"). ironpet's own sound is excluded. Both are written as 16 kHz mono WAV chunks to `~/.ironpet/meetings/<date-time>/` and stay there after the meeting. They are your recording, so ironpet never deletes them; remove the folder when you no longer need it. At most one chunk (up to 5 minutes per track) is held in memory at a time.

- **Audio goes to the configured server.** Every chunk is uploaded to the base URL under Settings → Voice, with the model name and your API key if you saved one. A plain `http://` URL sends it unencrypted, so use it only for `localhost`. Chunks that fail are retried against the same server.
- **The transcript goes to the chosen agent.** When a meeting ends and "Summarize automatically" is on, the full text of `transcript.md` is sent to the agent set as the summary agent (an ACP agent such as Claude Code or Cursor), and from there to that agent's model provider. Turn the setting off and no agent runs.
- **The summary agent cannot change anything.** It runs over ACP in the meeting folder only (ironpet's memory and screenshot folders are not shared), and ironpet answers every `session/request_permission` from it with a refusal, so it cannot edit files or run commands. ironpet itself writes `summary.md` from the agent's text answer. The agent can still read files inside the meeting folder.
- **Consent.** Recording people without their consent is illegal in many places (for example §201 StGB in Germany). The first meeting shows a notice, the picker repeats it, and the recording status shows in the pet's bubble. You can close that bubble, but the pet then shows a red Recording button for as long as ironpet records, and clicking it brings the bubble back.
- **Permissions are asked late.** Microphone and Screen & System Audio Recording access are requested when you press Start recording for the first time, never at launch and never with the feature off.
- **Quitting.** Quitting ironpet during a meeting writes the audio captured so far and what is already transcribed. Chunks not yet transcribed are marked as such in `transcript.md`.

## Integrations are off by default

| Integration | Default | Turn on |
| --- | --- | --- |
| GitHub PR & CI alerts | Off | Right-click → Integrations |
| Share MCP sign-ins across folders | Off | Right-click → Integrations (shows a warning first) |
| Sentry alerts | Off | `./scripts/configure_sentry.sh` |
| Voice notes (audio sent to a server you choose) | Off | Settings → Voice |
| Meeting transcripts (microphone and app audio sent to that server, transcript sent to an agent) | Off | Settings → Meetings |
