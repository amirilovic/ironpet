# AGENTS.md

Instructions for AI agents working in this repository: ironpet, a macOS desktop pet (Swift, AppKit and SwiftUI) that watches coding agents and chats with them. `README.md` explains what it does, `SPEC.md` how it is built, and `CONTRIBUTING.md` how to build and test it.

## Workflows

| Task | Read first |
|---|---|
| A feature or a non-trivial fix | `.cursor/skills/dev-feature/SKILL.md` |
| Reviewing a diff, branch or PR | `.cursor/skills/dev-code-review/SKILL.md` |
| Opening a pull request | `.cursor/skills/dev-open-pr/SKILL.md` |
| Writing Swift | `.agents/skills/swift/SKILL.md` |
| Reviewing UI design | `.agents/skills/apple-design/SKILL.md` |

## Ground rules

- Ask before running `./scripts/install.sh`, `./scripts/uninstall.sh`, `./scripts/configure_sentry.sh` or `python3 scripts/e2e.py`. They replace the installed app, change `~/.ironpet` and agent hooks, and e2e takes over the keyboard and spends agent quota.
- Never type the user's Keychain or login password; the user answers those prompts.
- Never commit `~/.ironpet` content, tokens, `build/` or `.build/`.

## Screenshots in pull requests

`gh` cannot upload images, so don't ask the user to drag them in. Render previews from sample data (`--render-previews`), push them to the `pr-screenshots` branch under `pr-<number>/`, and link them from a **Screenshots** section in the PR body. `pr-screenshots` shares no history with `main` and is never merged. The commands are in `.cursor/skills/dev-open-pr/SKILL.md` › Screenshots.
