---
name: dev-feature
description: >-
  End-to-end workflow for an ironpet feature or fix: investigate, ask
  follow-up questions, load the relevant skills, write a plan the user
  approves, implement with XCTest coverage, verify with swift build/test,
  the app bundle, rendered previews and the matching e2e scenarios, update
  README/SPEC/SECURITY, get a fresh-subagent dev-code-review with automatic
  fixes, and open a ready PR. Use when adding or planning a feature, setting,
  integration, agent, UI change, or a non-trivial fix in this repo.
---

# ironpet feature — investigate to PR

Covers the Swift app (`Sources/IronPet`, `Tests/IronPetTests`) and the tooling around it (`sidecar/`, `scripts/`, `tools/`). One branch, one plan, one review, one PR.

ironpet edits other tools' config files and starts agents that can change files, so `CONTRIBUTING.md` › Guidelines applies to every feature: safety first, settings in `Config` with safe defaults, network and credential features off by default, follow the code around the change, no new dependencies without discussion.

The review rules live in [../dev-code-review/](../dev-code-review/SKILL.md): `app.md` for the Swift app and `tooling.md` for scripts, adapters and CI. Build to them from the start.

## Workflow

Track progress with `TodoWrite` using these phases:

```
Feature Progress:
- [ ] Phase 0: Branch
- [ ] Phase 1: Investigate (load skills first)
- [ ] Phase 2: Clarify with the user
- [ ] Phase 3: Plan approved
- [ ] Phase 4: Build, owner by owner, with tests
- [ ] Phase 5: Verify (gates, previews, installed app and e2e if allowed)
- [ ] Phase 6: Docs
- [ ] Phase 7: Fresh-subagent review loop
- [ ] Phase 8: PR
```

---

### Phase 0 — Branch

1. `BASE=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)`
2. If the working tree has uncommitted changes unrelated to this feature, ask the user how to handle them (stash, commit, or abort). Never discard them.
3. `git fetch origin && git switch -c feat/<slug> origin/$BASE` (`fix/<slug>` for a fix, `chore/<slug>` for tooling).

---

### Phase 1 — Investigate

**No assumptions.** Every product, UX, safety, or scope decision the code, the docs and the request cannot answer goes to the user as a question.

#### 1.1 Restate the feature

One sentence: **what** the user gets, **how** they reach it (shortcut, right-click menu, Settings, bubble, chat), and **what it touches** on their Mac (files, network, permissions).

> *"Ghost shows a bubble when a watched Codex session has waited for input for 2 minutes; it reads only the hook events ironpet already gets and sends nothing anywhere."*

#### 1.2 Tag the areas

Tag every folder the feature touches, using the layout table in `dev-code-review/app.md` (`App/`, `Pet/`, `Sessions/`, `Hooks/`, `Bridge/`, `Chat/`, `Chat/ACP/`, `Signals/`, `Voice/`, `Meeting/`, `Reminders/`, `Support/`) and `tooling.md` (`sidecar/`, `scripts/`, `tools/`, CI). Also tag:

| Tag | When |
|---|---|
| `safety` | Hooks, `ApprovalRules`, Auto mode, the local server or test endpoints, anything that writes outside `~/.ironpet` |
| `privacy` | A new network destination, credentials, microphone, screen, or data sent to an agent or a server |
| `config` | A new `config.json` key or Settings control |
| `ui` | A window, panel, bubble, menu item, shortcut, or pet animation |

#### 1.3 Rate and load skills

| Rating | Meaning | Action |
|--------|---------|--------|
| 5 | Core to the feature | **Read now, before investigating further** |
| 4 | Guides major decisions | **Read now** |
| 3 | Touches one sub-step | Note; read when that step starts |
| ≤ 2 | Tangential | Skip |

Always:

- Rate `.agents/skills/swift/SKILL.md` **5** for any Swift change. Its conventions table overrides the generic guides.
- Rate `dev-code-review` **4**, and open `app.md` and/or `tooling.md` for every surface touched.
- Rate `.agents/skills/apple-design/SKILL.md` **4** for any `ui` tag (macOS: `designing-for-macos.md`, `windows.md`, `the-menu-bar.md`, `keyboards.md`, plus what is on screen).

Usually 4–5 by area (guides under `.agents/skills/swift/skills/`):

| Area | Skills |
|---|---|
| `Chat/ACP/`, `Meeting/`, `Voice/`, `Bridge/`, anything async | `swift-concurrency` |
| Config, JSON-RPC, hook payloads, threads | `swift-codable` |
| Keychain, tokens | `swift-security` |
| Uploads, polling, downloads, the local server | `ios-networking` |
| SwiftUI content | `swiftui-patterns`, `swiftui-layout-components`; `swiftui-animation` for motion; `swiftui-performance` for the chat transcript or anything that redraws often |
| Notifications | `push-notifications` (local only) |
| Keyboard access, labels | `ios-accessibility` |

A generic skill that suggests a different architecture (`@Observable` migration, SwiftUI `App` lifecycle, TCA) is downgraded to ≤ 2: `SPEC.md` decides the architecture.

Load the 4s and 5s **before** reading feature code.

#### 1.4 Investigate

Read, do not guess. At minimum:

- `SPEC.md` for the area (how it works and why), `SECURITY.md` for what it may touch, the README section that describes it.
- The nearest existing feature with a similar shape, and copy its shape later. For example: a new integration → `Signals/GitHubWatcher.swift` and its `Config.integrations` key; a new opt-in capture feature → `Voice/` and `Meeting/`; a new agent → `HookInstaller`, `SessionStore` and `AgentCatalogData.swift`; a new bubble → `Announcer` and `Bubbles`.
- Every file the feature would touch, plus its callers and tests in `Tests/IronPetTests/`.
- Which `/test/*` endpoints in `App/TestControl.swift` and which `scripts/e2e.py` scenarios already cover the area (the table in `dev-code-review/app.md` › Gates).
- For an agent integration: the agent's own hook or ACP docs. Do not reconstruct a third-party payload from memory; ask the user or read a real payload.

Use parallel searches; use an `explore` subagent for broad sweeps. Write findings down as you go: what exists, what is missing, what conflicts.

---

### Phase 2 — Clarify

Ask before planning. Use `AskQuestion` with concrete options (recommended first). Batch related questions; ask again if answers open new ones. Typically:

- **Default**: on or off? Anything with the `privacy` tag is off by default; say so rather than ask.
- **Surface**: where the user reaches it (right-click menu, Settings section, shortcut and its default, bubble, chat settings) and whether it needs a Settings control or only a `config.json` key.
- **Safety**: what it may do without asking, and what still needs Allow / Deny, including in Auto mode.
- **States**: first run, feature off, permission denied, server unreachable, agent missing, chat open or closed, pet on a small screen.
- **Copy**: final wording for menu items, bubbles, Settings labels and errors. Propose it in the voice of the existing UI and ask.
- **Scope**: what is in, what is explicitly out.

Do **not** ask what the code or a convention already answers; state the convention you found instead.

Push back before planning when a request breaks a rule:

| Request | Response |
|---------|----------|
| A network, microphone or screen feature on by default | "Integrations that touch the network or credentials are off by default (`CONTRIBUTING.md`). It ships off, with a Settings switch." |
| Let Auto mode run destructive commands | "Destructive commands always ask (`ApprovalRules.destructive`), even in Auto. That is a safety guarantee in `SECURITY.md`." |
| A hook that waits for the app or decides something | "Hooks only report status with a one-second timeout and always exit 0, so they can never block an agent." |
| Store a token in `config.json` | "Tokens go in the Keychain, as `ironpet.voice` and `ironpet.sentry` do." |
| Add a Swift package or npm dependency | "`CONTRIBUTING.md` asks to discuss dependencies first. Here is what it would take without one: …" |
| Write to another tool's config without asking | "Nothing outside `~/.ironpet` changes until the user turns it on, and each file is backed up first." |

---

### Phase 3 — Plan

Write the plan to `build/plans/<slug>.md` (gitignored, local only) and show it to the user. The durable decisions go into `SPEC.md` in Phase 6.

```markdown
# <Feature title>

Branch `feat/<slug>`. Status: awaiting approval.

## Goal
<what the user gets, how they reach it, what it touches on their Mac; one paragraph>

**Done when:** <a concrete walk-through in the installed app that a tester can follow>

## Decisions
| Area | Choice |
| --- | --- |
| <each Phase 2 question> | <the user's answer> |

## Out of scope

## Safety and privacy
- Default: <off / on and why>
- Files read or written outside `~/.ironpet`, network destinations, permissions, data sent to agents
- What asks for approval, including in Auto mode
- The `SECURITY.md` lines this adds or changes

## Architecture
<one bullet per owning folder: which type it extends or adds, and why there>
- Config: new keys, defaults, clamping, Settings control
- Test hooks: new `/test/*` endpoints (test mode only), if the e2e needs them

## Work breakdown
1. <owner>: <change> + <test file and the cases>
2. ...
N. Docs: README (feature, config keys, permissions), SPEC (how it works), SECURITY (what it touches)

## Verification
- Unit tests: <files and cases>
- Previews: <screens rendered with `--render-previews`, if UI>
- Installed app: <what to click and see>
- e2e: <scenarios that cover it, new scenario if any, opt-in or not>

## Open
- <risks and questions left>
```

**Stop for approval.** Do not write code until the user approves. If they change the plan, update the file and confirm again.

---

### Phase 4 — Build

Execute the work breakdown one owner at a time. Finish an owner (code and tests) before starting the next. Default order, skipping what the plan does not touch:

1. **Config** (`Support/Config.swift`): key, default, clamping, decode-over-defaults; a case in `ConfigTests`.
2. **Rules** as plain, testable types: event mapping (`SessionStore`), approval policy (`ApprovalRules`), parsing (`swift-codable`), chunking, layout. XCTest in the matching `Tests/IronPetTests/<Area>Tests.swift`.
3. **Services**: processes, networking, capture, Keychain, the local server. Off the main thread; weak captures in long-lived closures.
4. **Hooks** (`HookScript`, `HookInstaller`) when the feature watches a new agent or event: merge, backup, uninstall, marker-owned files; cases in `HookInstallerTests` and `SessionMappingTests`.
5. **UI**: AppKit owner (panel, menu item, hotkey) and SwiftUI content; Settings control; bubble through `Announcer`. Keyboard-reachable, reduced motion respected.
6. **Test endpoints** in `TestControl` (test mode only) and the e2e scenario in `scripts/e2e.py`, registered in `SCENARIOS` and in `OPT_IN` when it needs extra services or a lot of agent quota. It restores every file it changes.
7. **Tooling** (`sidecar/`, `scripts/`, `tools/`) per `tooling.md`: exact pins with the lockfile, pinned and checksum-verified downloads, uninstall removes what install adds.

Follow the code around each change: naming, comment density (the *why*, not the *what*), error handling, test style. If ownership turns out unclear while building, stop and update the plan.

---

### Phase 5 — Verify

**Gates** (repo root), the same as CI:

```bash
swift build
swift test
./scripts/bundle.sh && ./scripts/check_adapters.sh build/IronPet.app   # when Package.swift, sidecar/, tools/, Resources/ or bundle.sh changed
for script in scripts/*.sh; do bash -n "$script"; done                  # when scripts changed
python3 -m py_compile scripts/e2e.py scripts/gen_agent_catalog.py       # when they changed
```

Fix failures before moving on. Re-run only the failed gate after a fix.

**Previews (UI changes).** When the screen is one `PreviewRenderer` renders, extend it with the new state using sample data and render to a scratch folder: `./scripts/screenshots.sh build/screenshots/<slug>`. Look at every image with the `Read` tool and check it against `apple-design` (macOS files) and the surrounding UI: spacing, clipped text, light and dark, keyboard focus. Fix and re-render if anything is off. Only regenerate `docs/screenshots/` when a README screenshot changed on purpose.

**Installed app and e2e (ask first).** `CONTRIBUTING.md` asks for a check in the installed app, because hotkeys, Screen Recording and notifications only behave from `/Applications/IronPet.app` signed with `ironpet-dev`. Both steps change the user's machine, so ask with `AskQuestion` before running them:

- `./scripts/install.sh` replaces and restarts the installed app (and may ask for the login password the first time).
- `python3 scripts/e2e.py <scenarios>` relaunches it in `--test-mode`, runs real agent turns on the user's quota, edits and restores `config.json` and hook files; `setup` and `settings` take over the keyboard. Pick scenarios from the table in `dev-code-review/app.md` › Gates.

Record what ran and what did not, for the PR's test plan.

---

### Phase 6 — Docs

- `README.md`: the feature in **What it does** or its own section, every new `config.json` key in **Configuration**, new permissions in the permissions table, new shortcuts in **Using it**, new files in **Your data**.
- `SPEC.md`: how it works and the decisions behind it, in the voice of the existing sections. New agent events go in the Event mapping table.
- `SECURITY.md`: every new file read or written, network destination, credential, permission, or data sent to an agent or server; the integrations table when a new opt-in feature lands.
- `CONTRIBUTING.md`: only when the dev workflow changed (a new gate, a new required tool).
- `dev-code-review/app.md` or `tooling.md`: when a review rule changed (a new owning folder, a new e2e scenario, a new generated file).

### Phase 7 — Review

Follow [review-and-pr.md → Review](review-and-pr.md#review--fresh-subagent-loop).

### Phase 8 — PR

Follow [review-and-pr.md → PR](review-and-pr.md#pr).

---

## Done when

- [ ] Plan approved, and `SPEC.md` holds its lasting decisions
- [ ] Every work-breakdown item landed in its owning folder, with tests
- [ ] `swift build` and `swift test` pass; bundle and script checks pass when they apply
- [ ] Previews reviewed for UI changes; installed-app and e2e checks run or listed as not run
- [ ] README, SPEC and SECURITY updated for what changed
- [ ] Final fresh reviewer status is Approved or Approved with minor changes
- [ ] PR opened with its screenshots on `pr-screenshots`; URL and checks not run reported to the user
