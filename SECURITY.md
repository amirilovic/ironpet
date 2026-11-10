# Security

ironpet runs on your Mac with your user's permissions, watches your coding agents, and can start agents that edit files and run commands. This page lists what it touches and what protects it, so you can decide what to turn on. Nothing outside `~/.ironpet` is changed until you confirm the welcome window on first launch.

## Reporting a vulnerability

Please use GitHub's **Report a vulnerability** button on the repository's Security tab instead of a public issue. You'll get a reply within a week.

## What runs where

- **Local HTTP server.** The app listens on `127.0.0.1` only (port written to `~/.ironpet/port`). Every request has to carry the random 256-bit token in `~/.ironpet/token` (mode `0600`), or it gets a 403. The `/test/*` endpoints exist only when the app is started with `--test-mode`.
- **Hooks.** `~/.ironpet/bin/ironpet-hook` is called by Cursor and Claude Code. Status hooks have short timeouts and always exit 0, so they never block or fail your agents. Approval hooks only act for agents ironpet itself started (they carry `IRONPET_RUN_ID`); for every other agent they return immediately.
- **Approvals.** Agents started from Ghost's chat ask before each file edit, shell command and non-read-only MCP tool. The per-chat **Auto** switch skips those prompts for that chat only. It is never saved and resets with each new chat. Even with Auto on, commands that match a destructive pattern (`rm -rf`, `git push --force`, `git reset --hard`, `git clean -f`, `DROP TABLE`, `mkfs`, `dd if=`, …) still ask. Writes to ironpet's own memory notes (`~/.ironpet/memory`) don't ask. Because these prompts run through the hooks, a chat refuses to start when the hooks for its backend aren't installed, and if the app isn't running the hooks deny.
- **No API keys.** Chat goes through your existing `cursor-agent` or `claude` login. ironpet sends nothing anywhere itself, except the optional GitHub and Sentry polling below.

## Files ironpet writes outside `~/.ironpet`

| File | When | Undo |
| --- | --- | --- |
| `~/.cursor/hooks.json` | Only if you choose to watch Cursor (welcome window or Settings) | Settings → General → Watch Cursor off. The original is backed up as `hooks.json.ironpet-backup` |
| `~/.claude/settings.json` | Only if you choose to watch Claude Code | Settings → General → Watch Claude Code off. Backed up as `settings.json.ironpet-backup` |
| `~/.cursor/projects/*/mcp-auth.json` | Only with **Share MCP sign-ins** on (off by default) | Turn it off; copied entries stay until you sign out of that server |
| Login item | Only if you leave Launch at login on in the welcome window | Settings → General, or right-click → Launch at login |
| Keychain item `ironpet.sentry` | Only if you run `scripts/configure_sentry.sh` | `security delete-generic-password -s ironpet.sentry` |

## What ironpet reads

- `~/.config/gh/hosts.yml` and the `gh` CLI, only with GitHub alerts on (off by default).
- `~/.ironpet/sentry.json` and its Keychain token, only after you've configured Sentry.
- Cursor's `storage.json` and iTerm2 via AppleScript, to find the project you're working in.
- Wispr Flow's local database, to pick up dictation while the chat is open.

## Data in `~/.ironpet`

| Path | Contents |
| --- | --- |
| `config.json` | Your settings |
| `threads/` | Saved chats |
| `memory/` | Markdown notes Ghost keeps about you and your projects (you can edit them) |
| `screenshots/` | Screen captures you attached to chats |
| `scratch/` | Working folder for chats that aren't about a project |
| `token`, `port` | Local server credentials |

Delete the folder to erase all of it, or run `./scripts/uninstall.sh` to remove ironpet completely (hooks, login item, app, Keychain item, and optionally this folder).

## Integrations are off by default

| Integration | Default | Turn on |
| --- | --- | --- |
| GitHub PR & CI alerts | Off | Right-click → Integrations |
| Share MCP sign-ins across folders | Off | Right-click → Integrations (shows a warning first) |
| Sentry alerts | Off | `./scripts/configure_sentry.sh` |
