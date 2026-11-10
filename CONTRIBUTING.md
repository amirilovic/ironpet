# Contributing

Thanks for helping out! Bug reports, ideas and pull requests are all welcome. For anything bigger than a small fix, please open an issue first so we can agree on the approach before you spend time on it.

## Setup

You need macOS 14+, the Xcode command line tools (Swift 5.10+), and at least one agent CLI (`cursor-agent` or `claude`) to try the chat.

```bash
git clone https://github.com/irtazahashmi/ironpet.git
cd ironpet
./scripts/install.sh      # build, install to /Applications and start
```

The [README](README.md) covers features and configuration, [SPEC.md](SPEC.md) the design and the reasons behind it, and [SECURITY.md](SECURITY.md) what the app reads and writes.

## Making changes

```bash
swift build               # debug build
swift test                # unit tests: config parsing, shortcuts, hook install/uninstall
./scripts/install.sh      # release build, install, restart
./scripts/screenshots.sh  # render the README screenshots from sample data
```

Check your change in the installed app, not just with `swift build`. Things like global hotkeys, Screen Recording and notifications only behave properly from `/Applications/IronPet.app`, signed with the `ironpet-dev` identity that `install.sh` creates.

### End-to-end tests

`python3 scripts/e2e.py [scenario ...]` relaunches the installed app with `--test-mode` and drives it through test-only endpoints and the real windows. Most scenarios run real `cursor-agent` and Claude Code turns, so they use your agent quota and need both signed in, with both agents turned on under Settings → General. The `setup` and `settings` scenarios click through the native windows using accessibility, so your terminal needs Accessibility permission and you shouldn't type while they run. Scenarios that change `config.json` or the hook files restore your copies afterwards.

Run the scenarios related to your change, and mention which ones you ran in the pull request. `mcp` and `sentry` only run when named, because they need a Langfuse or Sentry MCP signed in with `cursor-agent`.

## Guidelines

- **Safety first.** ironpet edits other tools' config files and starts agents that can change files. Changes to hooks, approvals, Auto mode or anything that writes outside `~/.ironpet` need tests and a note in SECURITY.md. New integrations that touch the network or credentials are off by default.
- **Settings** go in `Config` (`Support/Config.swift`) with a safe default, plus a control in the Settings window if most people would want to change them. Document new keys in the README's Configuration section.
- **Style.** Follow the code around your change. Keep functions small, comment the *why* rather than the *what*, and don't add dependencies without discussing it first.
- **Commits and PRs.** Keep each PR focused on one thing. Describe what changed, why, and how you tested it; include a screenshot for UI changes. CI runs `swift build`, `swift test` and builds the app bundle on every PR.

## Reporting bugs

Use the bug report template. Please leave tokens, chat contents and anything private out of issues. Report security problems privately (see [SECURITY.md](SECURITY.md)).

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
