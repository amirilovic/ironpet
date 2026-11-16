---
name: dev-open-pr
description: >-
  Create GitHub pull requests for ironpet (macOS desktop pet: Swift app,
  agent hooks, ACP chat, bundled adapters, scripts) with gh, including branch
  checks, the CI gates, a conventional title, and a What / How / Verification
  body with safety and privacy notes. Use when the user asks to open, create,
  or prepare a PR, or to push the current branch and open a PR for it.
metadata:
  category: pull-request
---

# Open Pull Request

Create merge-ready pull requests for ironpet: the SwiftPM app in `Sources/IronPet` with its XCTest suite, and the tooling in `sidecar/`, `scripts/` and `tools/`. CI (`.github/workflows/ci.yml`) runs on every PR, but run the gates locally before opening it rather than waiting for CI.

## Use this skill when

- The user asks to open, create, or prepare a PR.
- The user asks to push the current branch and open a PR for it.
- A change is complete and needs to be sent for review.

## Do not use this skill when

- The task is just committing locally (no PR yet).
- The user wants to update an existing PR's description or CI. Use `gh pr edit` / `gh pr view` directly.
- The change has not been reviewed for merge readiness yet. Run `.cursor/skills/dev-code-review/SKILL.md` first, or at minimum the gates below. If a gate fails, stop and report it. Do not open the PR unless the user explicitly asks for a draft anyway.

## Minimum gates

The same checks CI runs, from the repo root:

| Branch touches | Run |
|---|---|
| Anything in `Sources/`, `Tests/`, `Package.swift` | `swift build` and `swift test` |
| `Package.swift`, `sidecar/`, `tools/`, `Resources/`, `scripts/bundle.sh` | Also `./scripts/bundle.sh`, `test -f build/IronPet.app/Contents/Resources/spritesheet.png`, `codesign --verify --verbose build/IronPet.app`, `./scripts/check_adapters.sh build/IronPet.app` |
| `scripts/` | `for script in scripts/*.sh; do bash -n "$script"; done` and `python3 -m py_compile scripts/e2e.py scripts/gen_agent_catalog.py` |
| Docs or skills only | No build gate; check links and paths you mention exist |

`bundle.sh` needs Bun and npm. Never run `./scripts/install.sh`, `./scripts/uninstall.sh`, `./scripts/configure_sentry.sh` or `python3 scripts/e2e.py` while opening a PR unless the user asks: they change the user's installed app, config and agent hooks, and e2e spends agent quota.

## Workflow

1. **Detect the base branch.** Never hardcode `main`:
   - `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`
   - Use the returned name as `<base>` in every command below.

2. **Gather branch state** (run in parallel):
   - `git status`: uncommitted changes. If anything from [Do not commit](#do-not-commit) is staged, stop and ask before continuing.
   - `git diff --stat`: staged and unstaged changes.
   - `git log <base>..HEAD --oneline`: commits on this branch.
   - `git diff <base>...HEAD --stat`: full diff against base.
   - `git branch --show-current`: confirm the branch name. If it is `<base>`, create a branch first (`feat/<slug>`, `fix/<slug>`, `chore/<slug>`, `docs/<slug>`).
   - `git status -sb` and `git rev-parse --abbrev-ref @{upstream}`: whether the branch tracks a remote and needs a push.

3. **Ensure a clean, safe tree**:
   - If uncommitted changes belong to this PR, stage and commit them first.
   - If the tree mixes this change with unrelated work, ask before committing.
   - Follow the commit style in `git log --oneline -10`: a lowercase conventional subject (`feat: …`, `fix: …`, `chore: …`, `docs: …`) describing what the user gets, with a short body when needed.
   - Pass the message with a HEREDOC. Do not use `git commit -i`, `--no-verify`, `--amend` (unless the user's amend rules are all met), or force-push.
   - Never update git config.

4. **Analyze all commits** on the branch, not just the latest:
   - Read every commit in `git log <base>..HEAD` and `git diff <base>...HEAD`.
   - Understand the full scope. This drives the title, body, and verification.

5. **Check the docs moved with the code.** A new `config.json` key is in the README's Configuration section; a new file, network destination, credential or permission is in `SECURITY.md`; a design change is in `SPEC.md`. If one is missing, add it (or ask) before opening the PR.

6. **Push the branch.** Never force-push unless the user explicitly asks:
   - `git push -u origin HEAD`

7. **Create the PR** with `gh pr create --base "$BASE"`. Always pass `--body` via a HEREDOC.

8. **Add screenshots** for UI changes, as in [Screenshots](#screenshots).

9. **Return the PR URL**.

## Do not commit

Stop and ask if any of these are staged:

- Anything from `~/.ironpet` (`token`, `port`, `config.json`, `threads/`, `memory/`, `screenshots/`, `meetings/`), chat transcripts, meeting audio, or screenshots of private screens.
- Tokens and keys: GitHub or Sentry tokens, transcription API keys, `.env` files, signing identities or certificates (`*.p12`, `*.pem`, `*.cer`).
- Build output: `.build/`, `build/`, `.swiftpm/`, `sidecar/out/`, `sidecar/node_modules/`, `__pycache__/`.
- A hand-edited `Sources/IronPet/Chat/ACP/AgentCatalogData.swift` (regenerate with `python3 scripts/gen_agent_catalog.py`).

Do not `git add -f` anything `.gitignore` excludes. `docs/screenshots/` changes only when a README screenshot changed on purpose (render with `./scripts/screenshots.sh`, which uses sample data only).

## PR Title

Format: `<type>: <lowercase description of what the user gets>`, matching the squash-merge commits on `main`.

| Type | When |
|---|---|
| `feat` | New behavior the user can see or turn on |
| `fix` | A bug fix |
| `chore` | Tooling, CI, scripts, dependencies, agent skills |
| `docs` | README, SPEC, SECURITY, CONTRIBUTING only |
| `refactor` | No behavior change |
| `test` | Tests only |

Rules:

- Describe the outcome, not the implementation: `fix: rebuild the mic converter when the input format changes`, not `fix: update AudioSource.swift`.
- Keep it under about 80 characters. GitHub appends ` (#N)` on squash merge.

Examples:

- `feat: offer to record calls when another app uses the microphone`
- `fix: open meeting in the current chat and open files in TextEdit`
- `chore: add review, feature and PR skills for agents`

## PR Body Template

```markdown
## What
<one short paragraph: what the user gets or what was broken and now works, in plain words>

## How
- `<Folder/File.swift>`: <what changed and why it lives there>
- <new setting `key` (default …), in Settings and the README>
- <test hook or e2e scenario added>

## Safety and privacy
<Only when the PR touches hooks, approvals, Auto mode, the local server, files outside `~/.ironpet`, the network, credentials, the microphone or the screen>
- <what it reads, writes or sends, and the default>
- <the SECURITY.md lines added or changed>

## Verification
- [x] `swift build`, `swift test` (<count> tests)
- [x] <bundle and adapters check, if run>
- [x] <installed-app walk-through: what was clicked and seen>
- [ ] <e2e scenarios not run, and why>

<Not verified: what still needs a manual check, with the steps to do it>
```

For UI changes, a **Screenshots** section goes between **What** and **How**; see [Screenshots](#screenshots).

## Body Writing Rules

### What

- Always include it. Lead with what the user sees: the shortcut, menu item, bubble, or setting, and the default.
- For a fix, say what was broken and when it happened.

### How

- One bullet per owning folder or file, saying why the change lives there.
- Name new `config.json` keys with their default, new `/test/*` endpoints, new e2e scenarios, and anything regenerated.
- Say explicitly when a sensitive area was left untouched if a reviewer might worry (for example "Nothing under `Hooks/` changed").

### Safety and privacy

- Include it whenever the PR changes what ironpet touches on the user's Mac, and omit it otherwise.
- New integrations that use the network or credentials are off by default; say so.

### Verification

- Mark `[x]` only for checks already run in this session. Leave the rest `[ ]` with the reason (for example "uses agent quota", "needs a real call").
- Behavior that only shows in the installed app (hotkeys, Screen Recording, notifications, microphone) is either walked through in `/Applications/IronPet.app` or listed under **Not verified** with steps.
- Name the e2e scenarios that cover the change (see `.cursor/skills/dev-code-review/app.md` › Gates), whether they ran or not.
- UI changes: show the rendered previews in the PR, as in [Screenshots](#screenshots).

## Screenshots

`gh` cannot upload images (GitHub's attachment upload is web-only), so PR screenshots live on the `pr-screenshots` branch, one `pr-<number>/` folder per PR, and the PR body links to them. That branch has no history in common with `main`: never merge it, rebase it or open a PR from it.

- Only images rendered from sample data: `.build/debug/IronPet --render-previews <dir> --sprite build/ghost-sheet.png` (build the sprite with `swift tools/make_pet.swift ghost build/ghost-sheet.png`). Never a capture of the user's screen, sessions, chats or meetings.
- Upload after `gh pr create`, once the number is known, through a temporary worktree so the PR branch and working tree are untouched:

```bash
N=<pr number>; SHOTS=<dir with the PNGs>; WT=$(mktemp -d)/pr-screenshots
git fetch origin pr-screenshots
git worktree add --detach "$WT" origin/pr-screenshots
mkdir -p "$WT/pr-$N" && cp "$SHOTS"/*.png "$WT/pr-$N/"
git -C "$WT" add "pr-$N" && git -C "$WT" commit -m "Screenshots for PR #$N (sample data)"
git -C "$WT" push origin HEAD:pr-screenshots
git worktree remove "$WT"
```

- Add the section with `gh pr edit <N> --body-file <file>`, linking `https://github.com/<owner>/<repo>/blob/pr-screenshots/pr-<N>/<name>.png?raw=true` (a two-column table reads well). Check one link returns `content-type: image/png` with `curl -sIL`.
- Name what could not be rendered offscreen (on macOS 27 the chat's glass bars come out white, and the Settings window needs the running app) and put the manual check under **Not verified**.
- A `docs/screenshots/` image the README shows still goes in the PR itself, rendered with `./scripts/screenshots.sh`.

## Example

A hypothetical feature, to show the shape:

```bash
BASE=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)

git push -u origin HEAD

gh pr create --base "$BASE" --title "feat: remind me when a watched session has waited for input for a while" --body "$(cat <<'EOF'
## What
When a watched agent session has been in "needs input" for 2 minutes, Ghost shows a second bubble: "Claude Code is still waiting in ironpet." with Jump and Dismiss. Off by default; turn it on under Settings → General → Remind me about waiting agents.

## How
- `Sessions/SessionStore.swift`: records when a session entered `needsInput`; the reminder rule is a plain function so it can be tested.
- `App/Announcer.swift`: the reminder bubble, one per session, replaced rather than stacked.
- New setting `reminders.waitingAgentMinutes` (default 0 = off, clamped to 1–60 when set), in Settings and the README.
- `Tests/IronPetTests/SessionMappingTests.swift`: reminder after the interval, none after the user answers, none while the agents panel is open.
- Nothing under `Hooks/` changed; it uses the events ironpet already receives.

## Verification
- [x] `swift build`, `swift test` (<count> tests)
- [x] Installed app: started a Claude Code session that asked for permission, waited 2 minutes, saw the bubble, Jump opened the iTerm tab.
- [ ] `python3 scripts/e2e.py summaries iterm` (uses agent quota)
EOF
)"
```
