# ironpet

<img src="Resources/icon-1024.png" width="128" align="right" alt="Ghost, the ironpet app icon">

A desktop pet for macOS that keeps an eye on your coding agents and does small tasks for you. Ghost, a chibi direwolf in a Night's Watch cloak, floats above your windows, reacts to what Cursor and Claude Code are doing, and opens a chat where you can type, dictate or show him your screen.

<p align="center"><img src="docs/screenshots/pet.gif" width="560" alt="Ghost works while an agent runs, cheers when it finishes, asks before running a command, then drinks water with a break reminder"></p>

<p align="center"><img src="docs/screenshots/pets.png" width="720" alt="The six pets waving: Ghost the direwolf, Mochi the mint wolf, a hamster, a panda, a bunny and a cat"></p>

## What it does

- **Watches your agents.** Sessions of Cursor (IDE and CLI), Claude Code, Codex, Gemini CLI, GitHub Copilot and Pi report to the pet through hooks (only the agents installed on your Mac are offered). Ghost shows the most urgent state (needs input, failed, done, working) with a count badge, tells you in a speech bubble next to him, with a one-line summary of what the agent did ("Edited 3 files · Fixed the flaky login test."), and clicking a session jumps to its iTerm tab, or opens its folder in the app that started the agent (or one you pick in Settings).
- **PR, CI and Sentry alerts** (opt-in). Not set up by default. Ask your agent for them (ironpet window → Automations → **New automation…**), or tick GitHub alerts in the welcome window. They are script automations you can read and change in `automations.json`. A GitHub one can poll every host `gh` is logged in to for your PRs' CI failing or passing, approvals, changes requested and new review requests. A Sentry one can watch new and escalating issues, using the host and org from `~/.ironpet/sentry.json` and the token in the Keychain (`scripts/configure_sentry.sh` saves both). Each alert has **Open** and **Ask Ghost**, which starts a chat to investigate it.
- **Quick chat.** <kbd>⌥⌘G</kbd> or a click on Ghost opens the ironpet window on Chat, which talks to a coding agent over the [Agent Client Protocol](https://agentclientprotocol.com) in your current project: Cursor, Claude Code, Codex, Gemini CLI, OpenCode and any other agent from the [ACP registry](https://github.com/agentclientprotocol/registry) that you have installed. File edits and shell commands wait for **Allow / Deny** whenever the agent asks for permission (in the chat, or right in Ghost's bubble when the chat is closed); a per-chat **Auto** switch lets it run on its own, but destructive commands (`rm -rf`, `git push --force`, `git reset --hard`, dropping tables) still ask.
- **Voice.** Hold <kbd>fn</kbd> with [Wispr Flow](https://wisprflow.ai) while the chat is open; the dictation is sent automatically. Or turn on **voice notes** (opt-in, see [Voice notes](#voice-notes)): a microphone button and a voice shortcut record your voice, a transcription server you choose turns it into text, and the text lands in the chat input.
- **Screen help.** <kbd>⇧⌥⌘G</kbd> captures the front window, <kbd>⌃⌥⌘G</kbd> a region you drag, and opens a chat with the screenshot attached.
- **Remembers.** Chats are saved and can be reopened. Ghost keeps editable markdown notes about you and each project and reads them at the start of every chat.
- **Break reminders and automations.** Drink water (45 min), stretch (60 min) and rest your eyes (20 min), counted only while you're at the keyboard; stepping away for 5 minutes resets them. While an agent is working they can come a little early, so you take the break while you'd be waiting anyway. Ghost drinks or stretches along with you. His bubble has **Done** and **Snooze 10 min**. These are ordinary [automations](#automations), so an agent can add, change, pause and delete reminders, scheduled jobs and watchers for you. Toggle or pause them under right-click → Automations.
- **Tasks.** Ghost keeps your task list. Ask for something to be done later, tell him when you did it, and the agent adds, updates and closes the task, with every change kept in its history. After a meeting summary, Ghost offers the action items that are yours, and the ones someone else owns as tasks you're waiting on. Watcher automations can suggest tasks too. The Tasks section of the ironpet window shows what needs you, what is in progress, the backlog and what you're waiting on from others. See [Tasks](#tasks).
- **Model and agent picker** (the models come from the agent), per-project folder detection, a resizable window that stays open on Chat when you switch apps, launch at login.
- **One window.** A sidebar switches between Chat, Agents, Alerts, Tasks, Transcripts (past meetings, with their summary and transcript, Ask Ghost, Regenerate and Move to Trash), Actions and Automations. Settings opens its own window from the Settings row at the bottom.

| | |
| --- | --- |
| <img src="docs/screenshots/agents.png" alt="The ironpet window listing sessions that need input, are working, failed and are done"> | <img src="docs/screenshots/chat-approval.png" alt="The chat waiting for Allow or Deny before running a command"> |
| **Agents:** every Cursor and Claude Code session, most urgent first | **Approvals:** edits and commands wait for you |
| <img src="docs/screenshots/alerts.png" alt="The Alerts section with a failed CI run, a review request and an approval"> | <img src="docs/screenshots/reminder.png" alt="Ghost drinking water next to a break reminder"> |
| **Alerts:** CI, reviews and Sentry, with Ask Ghost | **Breaks:** Ghost drinks along with you |

## Requirements

- macOS 14 or later, Apple Silicon or Intel
- Xcode command line tools (Swift 5.10+). With the macOS 27 SDK, full Xcode instead, selected with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` (SwiftUI's macros ship only with Xcode)
- To build: [Bun](https://bun.sh) and npm, which bundle the chat adapters in `sidecar/`
- At least one agent CLI, signed in, that speaks ACP: `cursor-agent`, `gemini`, `opencode` and many more run as they are. `claude`, `codex` and `pi` run through small adapters bundled in the app, which need Node 22 or newer on your PATH (or a one-time Bun download that ironpet asks before making)
- Optional: iTerm2, Wispr Flow

## Install

```bash
git clone https://github.com/irtazahashmi/ironpet.git
cd ironpet
./scripts/install.sh
```

`install.sh` checks the requirements (and tells you how to fix what's missing), builds the app, installs it to `/Applications/IronPet.app` and starts it. The first time, it also creates a local self-signed `ironpet-dev` code signing identity so macOS keeps Screen Recording and Automation permissions across rebuilds; macOS may ask for your login password to trust it. Run it again any time to update.

On first launch a welcome window asks what Ghost may do: watch the agents it finds on your Mac (hooks merged into each agent's own config, for example `~/.cursor/hooks.json` and `~/.claude/settings.json`, originals backed up next to each file as `*.ironpet-backup`; Codex also needs you to trust the hooks once in its `/hooks` screen), launch at login, break reminders and GitHub alerts. Nothing outside `~/.ironpet` changes until you press **Start**, and every choice can be changed later in Settings.

Ghost's chat can use the MCP servers you have in Cursor (`~/.cursor/mcp.json`). The CLI stores MCP sign-ins per folder, so normally you sign in (`cursor-agent mcp login <name>`) in each project. Turn on right-click → Integrations → **Share MCP sign-ins across folders** to sign in once: Ghost then copies your sign-ins into whichever folder a chat runs in (off by default because it copies OAuth tokens; see [SECURITY.md](SECURITY.md)). Read-only MCP tools (`get…`, `list…`, `search…`, `find…`) run freely; any other MCP tool waits for **Allow / Deny**, and in Auto mode still asks if its input looks destructive.

GitHub alerts are not set up by default; tick them here, or ask your agent for them under ironpet window → Automations → New automation… (needs the `gh` CLI, signed in).

Optional: `./scripts/configure_sentry.sh` turns on Sentry alerts. Alerts use Sentry's REST API (cheap, exact polling); **Ask Ghost** on an alert then investigates through the Sentry MCP. It asks for host, org, projects and an auth token (scopes `event:read`, `project:read`), checks the token, stores it in the Keychain and the rest in `~/.ironpet/sentry.json`.

Ghost speaks in bubbles beside him instead of macOS notifications. Approvals stay until you answer, reminders for 3 minutes, everything else fades after 15 to 45 seconds (not while the pointer is over them). To get macOS notifications as well, turn on right-click → **Also show macOS notifications**; then set ironpet's notification style to **Alerts** in System Settings → Notifications so Allow / Deny buttons stay on screen.

macOS will ask for these permissions as you use the features:

| Permission | Needed for |
| --- | --- |
| Notifications | Only with **Also show macOS notifications** on |
| Automation → iTerm2 | Jumping to the right iTerm tab, reading its folder |
| Screen Recording | Screenshots, and telling Cursor windows apart when several are open |

## Using it

| Action | How |
| --- | --- |
| Chat with Ghost | <kbd>⌥⌘G</kbd> or click Ghost |
| Ask about the front window / a region | <kbd>⇧⌥⌘G</kbd> / <kbd>⌃⌥⌘G</kbd> |
| See watched agents, alerts and tasks | Click Ghost when something needs attention, or right-click → Show agents. One window with a sidebar holds Agents, Alerts, Tasks, Actions, Automations and Settings |
| Allow an action | **Allow** or <kbd>⌘↩</kbd> on the approval card |
| Move Ghost | Drag him; he stays where you leave him |
| Switch section | <kbd>⌘1</kbd> to <kbd>⌘7</kbd> in the ironpet window select the Nth sidebar row (Chat, Agents, Alerts, Tasks, Transcripts, Actions, Automations), also while the chat field has focus |
| Collapse the sidebar | <kbd>⌃⌘S</kbd> or the sidebar button next to the traffic lights shrinks the sidebar to a 72 pt rail of section icons (tooltip with name and ⌘N, count badge on the icon) and back; the choice is remembered |
| Settings | <kbd>⌘,</kbd>, the Settings row in the ironpet window, right-click Ghost → Settings…, or the Dock icon menu. A separate window with General, Integrations, Voice, Meetings and Usage in a sidebar; it reopens on the last page |
| Make Ghost do tricks (wave, dance, zoomies, nap, say something…) | Right-click Ghost → Actions |

When you open the chat from a non-coding app (browser, Slack…), Ghost asks which project the question is about, or you can pick **No project** for a general question.

## How it works

```mermaid
flowchart LR
    Cursor[Cursor IDE / CLI] -- hooks --> Hook[~/.ironpet/bin/ironpet-hook]
    Claude[Claude Code] -- hooks --> Hook
    Hook -- "HTTP 127.0.0.1 + token" --> App[ironpet]
    App -- "ACP over stdio" --> Agent[cursor-agent acp / gemini --acp / adapter + your claude]
    Agent -- "session/request_permission" --> App
```

- Hooks only report status for agents you started yourself. They never block an agent: one-second timeout, always succeed. A chat that ironpet runs over ACP sets `IRONPET_ACP_RUN=1`, and the hook script skips it, so the run is not listed twice.
- Chat approvals are ACP `session/request_permission` requests that ironpet answers. An agent that never sends one runs its tools without asking, and ironpet cannot change that; see SECURITY.md.
- The agent process stays alive between messages. Stop sends `session/cancel`. Reopening a thread from history uses `session/load`.
- `sidecar/` holds the Claude Code, Codex and Pi adapters. `scripts/bundle.sh` bundles each into one `.mjs` file (Bun is needed to build, not to run) and copies them to `IronPet.app/Contents/Resources/acp/`.
- `scripts/gen_agent_catalog.py` regenerates the agent list in `Chat/ACP/AgentCatalogData.swift` from the ACP registry.
- Everything is local. Chat goes through your existing Cursor or Claude Code login; ironpet has no API keys of its own.

See [SPEC.md](SPEC.md) for the full design and the decisions behind it, and [SECURITY.md](SECURITY.md) for everything ironpet reads and writes.

## License

[MIT](LICENSE)

## Third-party software

- [FluidAudio](https://github.com/FluidInference/FluidAudio), Apache-2.0. Runs speaker diarization on this Mac.
- The diarization models FluidAudio downloads on first use: the pyannote speaker-diarization community-1 pipeline and WeSpeaker embeddings, converted to Core ML by FluidInference ([speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml)), CC-BY-4.0.

## Automations

Every reminder and watcher is an automation in `~/.ironpet/automations.json`. On the first launch with this version, the reminders in `config.json` become automations with the same values. GitHub and Sentry alerts are added only if you already had them on (`integrations.githubAlerts`, or a `~/.ironpet/sentry.json`), as script automations. A fresh install starts with the three reminders (`config.json` keeps `idleResetMinutes`, `snoozeMinutes` and `paused`). The file is checked and reloaded within two seconds. An invalid edit leaves the last good list running and shows a bubble that names the problem. `automations.schema.json` next to it describes every field.

A built-in automation, `review-tasks` ("Review tasks"), is added to every install, new or existing. Every 10 minutes of wall clock time it sends `/ironpet-tasks` to your chat, so the agent reviews the task list. It does not run when no task is in backlog, in progress or needs you (the history shows `skipped: no open tasks`), and not while its previous message is still queued or running. When the agent answers exactly `ironpet-tasks: no changes`, the chat removes the prompt and the reply and the history shows `no changes`. Any other reply stays in the chat. Turn it off in Settings or set `"enabled": false`; ironpet keeps your choice and adds the automation again only if it is missing from the file.

```json
{
  "automations": [
    { "id": "stretch", "name": "Stretch", "trigger": { "type": "interval", "minutes": 60, "clock": "active" },
      "action": { "type": "bubble", "title": "Stretch a bit", "body": "Stand up, roll your shoulders." },
      "presentation": { "mood": "stretching", "symbol": "figure.flexibility" } },
    { "id": "standup", "name": "Standup", "trigger": { "type": "daily", "times": ["09:55"], "weekdays": ["mon", "tue", "wed", "thu", "fri"] },
      "action": { "type": "bubble", "title": "Standup in 5" } },
    { "id": "new-prs", "name": "New PRs", "trigger": { "type": "poll", "minutes": 5,
        "source": { "type": "shell", "command": "gh pr list --json number,title,url" }, "items": "[?!isDraft]", "id": "number" },
      "action": { "type": "bubble", "title": "New PR: {{item.title}}", "body": "{{item.url}}" } }
  ]
}
```

- **Triggers.** `interval` (every N minutes, on `active` keyboard time or the `wall` clock), `daily` (times of day, optional weekdays), `once` (an exact date and time; it turns itself off afterwards) and `poll`.
- **Polls.** The source is a shell command, an HTTP GET (header values must be `${ENV_VAR}` references). Items come Items come from a [JMESPath](https://jmespath.org) expression in `items`, with `id` and `version` expressions that run on one item, or from `lines`, `text` or `exit_code` mode. Filters do the filtering, for example `"items": "data.runs[?conclusion=='failure']"` or `[?contains(['open', 'new'], state)]`. JMESPath has no regular expressions. It runs inside ironpet, so nothing like jq has to be installed. The first run only records what exists. After that each new id, or a changed `version`, fires once.
- **Scripts.** A `script` trigger is a small JavaScript function for watchers that need to compare with the last run. A script automation has no `action` field. The script returns its own actions:

  ```js
  function poll(state) {            // state is what the last run returned, null the first time
    const prs = JSON.parse(sh("gh pr list --json number,title,url,statusCheckRollup").stdout);
    const now = Object.fromEntries(prs.map(p => [p.number, p.statusCheckRollup]));
    const actions = [];
    for (const p of prs) {
      if (now[p.number] === "FAILURE")
        actions.push({ type: "alert", id: String(p.number), severity: "bad", label: "CI failed", title: p.title, url: p.url });
      else if (state && state[p.number] === "FAILURE")
        actions.push({ type: "alert", id: String(p.number), resolved: true });
    }
    return { state: now, actions };   // state is kept for the next run
  }
  ```

  The return value is `{state, actions}`. `state` is any JSON, up to 256 KiB. `actions` run in order, up to 20 per run, and each has a `type`:
  - `bubble` shows a short-lived popup: `title`, `body`, `severity` (`info`, `good`, `warn`, `bad`), `url` (adds an Open button), `symbol`, `expiresSeconds`, `notification`. A bubble with the same `id` replaces the old one.
  - `alert` keeps an open item in the alerts list, which also drives Ghost's mood and badge: `id`, `title`, `subtitle`, `label`, `severity`, `url`, `ask` (the prompt for "Ask Ghost"), `version`. A new or changed alert also gets a bubble, except on the first run, which is quiet. An alert listed again unchanged is left alone, even if you dismissed it. `{type: "alert", id, resolved: true}` removes it.
  - `prompt` asks an agent in a background session and shows the answer: `prompt`, `title`, `agent`, `model`.
  - `suggest_task` proposes a task from something a watcher found, such as an email, a Slack message or an issue: `id` (stable for that thing), `title`, `due` (`YYYY-MM-DD`), `notes`, `url`. It only ever becomes a suggestion in the Tasks section, with Add and Skip (see [Tasks](#tasks)). The same `id` from the same automation is suggested once, even after you added or skipped it. Titles are cut at 200 characters and notes at 2000, control characters are removed, and at most 10 are taken per run. The first run adds them quietly; after that each run with something new shows one bubble.

  The script has `sh(command, {timeoutSeconds})`, which returns `{code, stdout, stderr, timedOut}`, and `console.log`. For the network, run `curl` through `sh`. A script gets at most 8 `sh` calls per run and 60 seconds in all, 32 MiB of memory and 256 KiB of state. It runs in QuickJS inside ironpet with no `fetch`, files, modules or timers, and `poll` must be a plain function, not async. A script an agent writes or changes waits for Approve like a shell command. Its state and the alerts it has shown are in `ironpet.db`.
- **Actions.** `bubble` (title, body, mood, SF Symbol, Done and Snooze buttons, optional macOS notification), `prompt` (sends the prompt into the open chat under a header naming the automation, so the chat's agent runs it with its tools, memory and context; it queues behind a running turn, skips a tick while its previous run is still queued or running, and ignores `agent` and `model`. A prompt that uses `{{item.field}}` runs in a read-only background session of its own and shows the answer in a bubble) and `shell` (runs a command with a timeout and shows its output). Text may use `{{item.field}}` from polls, `{{name}}` and `{{now}}`.
- **Approval.** A `shell` action, a `shell` poll source or a `prompt` action that an agent created or changed waits for you to press **Approve** in a bubble before its first run, and asks again whenever its command or prompt changes. Saved approvals live in `~/.ironpet/ironpet.db`. An agent that can write files on your Mac can edit that database too, so treat approval as a guard against mistakes, not against a hostile agent. Secrets do not belong in `automations.json`; use `$ENV_VAR` references.
- **Agents.** Ghost's chat agents get these MCP tools: `automations_list`, `automations_get`, `automations_create`, `automations_update`, `automations_delete`, `automations_pause`, `automations_resume`, `automations_run_now` and `automations_history`. They reach the app through `IronPet mcp`, a stdio MCP server that forwards to the running app. To add it to another agent, for example Claude Code, run `claude mcp add ironpet -- /Applications/IronPet.app/Contents/MacOS/IronPet mcp` (other agents take the same command and argument in their MCP settings). ironpet does not edit their config files. You can also post to `http://127.0.0.1:<port>/mcp` (port in `~/.ironpet/port`, token in `~/.ironpet/token`, header `x-ironpet-token`).
- **Fixing failures.** ironpet window → Automations → **Ask the agent to fix automations that fail** (on by default, `automations.autoFix` in `config.json`). When a poll, script, shell command or prompt fails, ironpet sends it to the current chat in the background and asks your agent to find the cause and fix the automation with the automation tools. The error from the run goes in the message marked as data, not instructions. Ghost says when the agent needs you. It asks once per failing stretch, at most every 6 hours per automation, and not for paused automations or ones still waiting for approval. A changed command, script or prompt still waits for your Approve. If the chat is busy, a bubble offers to send it instead.
- **New automation.** ironpet window → Automations → **New automation…** opens a box that asks what kind of automation you want. What you write goes to your agent in the current chat, which creates it with the automation tools, runs it once and tells you what it made.
- **Skills.** ironpet ships agent skills, folders `skills/<name>/SKILL.md` in the repo. The first one, `ironpet-automations`, shows an agent how to create automations: which trigger to pick, the script format, the safety rules and how to debug a run. `ironpet-tasks` tells an agent how to keep the task list: what to track, how a periodic review (`/ironpet-tasks`) works, and when it may close a task. Manage them in Settings → General → **Skills** (Install, Update, Reinstall and Remove for each skill, and a switch **Install and update skills automatically**, on by default), with `IronPet skills install|status|update|remove|list|agents`. `IronPet skills install ironpet-automations --agent claude-code --copy` picks a skill, agents and copy mode.

  The app and CLI install one real copy in `~/.agents/skills/<name>`, which Codex, Cline, Pi, Warp, Zed and other agents read directly, and a relative symlink from the skills folder of every other agent found on your Mac (`~/.claude/skills`, `~/.cursor/skills`, `~/.gemini/skills`, and so on). A folder with the same name that ironpet did not write is left alone. When an agent is installed and a skill is missing or old, Ghost shows one bubble for all of them with an **Install** (or **Update**) button. **Not now** keeps it quiet until that skill's text changes. With **Install and update skills automatically** on, the skills that are missing or out of date are installed or updated at launch for the agents found on your Mac, and Ghost says so in one bubble. A skill you declined with **Not now** stays out until its text changes. Turn the switch off to be asked instead.

  To add a skill, make `skills/<name>/SKILL.md` (frontmatter with `name`, the same as the folder, and `description`), then run `python3 scripts/gen_skills.py`. It compiles the skills into the app. A test fails if you forget.
- **CLI.** `IronPet automations list`, `get <id>`, `add --name N --every MIN`, `add --json '{...}'`, `update <id> --json '{...}'`, `pause <id>`, `resume <id>`, `delete <id>`, `run <id>` and `history <id>`. The app must be running. The CLI counts as an agent for approval.
- **State.** Definitions stay in `automations.json`. Seen sets, run history, approvals and snoozes live in `~/.ironpet/ironpet.db`, ironpet's common SQLite database (WAL), in `automation_*` tables. Seen items older than 7 days and history older than 30 days are pruned. If the file cannot be opened (for example a newer ironpet build created it), ironpet leaves it untouched, shows an alert with the reason and the path, and runs in memory, so nothing written meanwhile is saved. For a file from a newer build, install that build again to get your data back.
- **Logs.** ironpet window → Automations has a **Show logs** button (and each row's menu has **Show logs…**, and the right-click menu has Automations → Show logs…). It opens a window with every poll and script run, quiet ones included, plus every reminder, shell command and prompt that ran: time, how long it took, the outcome and the output (exit code, stdout and stderr of a poll, `console.log` lines and actions of a script, the error of a failed run). Filter by automation or show only problems. Logs older than a number of days are deleted: set it under ironpet window → Automations → Keep logs for, or `automations.logRetentionDays` in `config.json` (default 14, from 1 to 365). At most 2000 lines are kept per automation.
- **History.** The last 20 runs of each automation (time, outcome, short output) are in `automations_history` and under ironpet window → Automations.

## Tasks

The task list belongs to the agent, not to you, so nothing is lost by moving cards around. You tell Ghost what happened ("I called the doctor, the appointment is Tuesday at 21:00") and the agent closes the task with that note. A task is **backlog**, **in progress**, **needs you** (only you can take the next step) or **done**, and can link to a chat thread, an agent session, a URL or a file. A task can also name who you're **waiting on** (`waiting_on`); those never count as needing you.

- **From the chat, Telegram and voice.** Every chat tells the agent it keeps the list with the `tasks_*` tools: `tasks_list`, `tasks_get`, `tasks_create`, `tasks_update`, `tasks_close` and `tasks_delete`, on the same MCP server as the automation tools. It adds a task when you ask for something later or hand it work that won't finish in the turn, and closes it when you say it's done. It never starts work on a task unless you ask.
- **From meetings.** After a summary, the action items marked `owner: Me` are offered in a bubble with **Add all** and **Review**. Items owned by someone else (`owner: Ana`, `owner: Them`) are offered too, as tasks you're waiting on: they read "Waiting on Ana" and the bubble counts them apart ("2 for you, 1 waiting on others"). Nothing is added until you choose, and items without an owner or that are already tasks are skipped. Turn it off under Settings → Meetings → Suggest action items as tasks (`tasks.meetingSuggestions`).
- **From watchers.** A script automation that watches your mail, Slack or GitHub can return `suggest_task` actions (see [Automations](#automations)). They show up as suggestions marked "From <automation name>", with a link button when the watcher gave a URL, and one bubble per run with **Add all** and **Review**. Adding one makes a backlog task with that URL as a link. The text comes from outside, so it never becomes a task or reaches an agent until you add it.
- **The Tasks section.** Click Ghost, then Tasks in the sidebar: suggestions, needs you, in progress, backlog, waiting on others, and what was done in the last 7 days. Tasks you're waiting on are not in the section's count and don't make a click on Ghost open Tasks. The circle marks a task done, the right-click menu deletes it, and **Tell Ghost…** sends anything else to the chat.
- **Due dates.** When an open task is due (from the start of the day for a plain date such as `2026-11-20`, at the time for one with a time) or overdue, Ghost says so once: "Due today: send the deck", "Due now: …" or "Overdue: …", with **Done**, **Snooze 1 h** (**Remind tomorrow** for plain dates, at 9:00) and **Open**, which opens the Tasks section. Several due at once share one bubble. A task is announced again only when its due date changes or a snooze ends, also after a restart. Tasks you're waiting on are reminded too, so you can follow up. **Pause reminders** holds these too. Turn them off under Settings → General → Remind me when a task is due (`tasks.dueReminders`). A meeting's due that is not a date (such as "Friday") stays in the task's notes and is not reminded.
- **CLI.** Agents outside ironpet (Cursor, Claude Code in a terminal) can use `IronPet tasks list [--all] [--status S]`, `show <id>`, `add <title> [--notes N] [--due D] [--status S] [--url U] [--waiting-on NAME]`, `update <id> --json '{...}'`, `status <id> <status>`, `done <id> [--note N]` and `delete <id>`. The app must be running.
- **State.** Tasks, their links and history, suggestions (plus the ids each automation has suggested, kept for a year), and which due dates were announced or snoozed are in `~/.ironpet/ironpet.db` (`task_*` tables). Done tasks are deleted after `tasks.keepDoneDays` (default 30, from 1 to 365).

## Configuration

Open **Settings** (<kbd>⌘,</kbd> or right-click Ghost → Settings…) to rename the pet, pick another from the pet gallery, change or turn off shortcuts, tune reminders, and turn integrations on. Everything is stored in `~/.ironpet/config.json`, which you can also edit by hand or keep in your dotfiles. Changes apply within a couple of seconds. List only the keys you want to change; anything missing uses the default:

```json
{
  "pet": { "name": "Ghost", "sprite": "~/.ironpet/pet/spritesheet.png" },
  "hotkeys": { "chat": "cmd+opt+g", "captureWindow": "cmd+opt+shift+g", "captureRegion": "" },
  "reminders": { "paused": false, "idleResetMinutes": 5, "snoozeMinutes": 10 },
  "automations": { "logRetentionDays": 14 },
  "tasks": { "meetingSuggestions": true, "dueReminders": true, "keepDoneDays": 30 },
  "integrations": { "shareMCPSignIns": false },
  "voice": { "enabled": false, "baseUrl": "http://localhost:8000/v1", "model": "mlx-community/parakeet-tdt-0.6b-v3" },
  "meetings": { "enabled": false, "lastApp": "", "summaryAgent": "claude", "summaryModel": "sonnet", "autoSummary": true, "offerToRecordCalls": true, "recogniseSpeakers": false },
  "chat": { "background": "paws" },
  "openIn": "auto",
  "editors": [{ "name": "My IDE", "bundleId": "com.x.ide", "urlTemplate": "myide://open?path={cwd}" }]
}
```

- **Shortcuts** combine `cmd`, `opt`, `ctrl` and `shift` with a letter, digit, `space`, an arrow, or `f1`–`f12`. Each needs at least one of `cmd`, `opt` or `ctrl` (function keys can stand alone). An empty string turns a shortcut off.
- **Chat background** (`chat.background`) is `"default"` (plain), one of `"dusk"`, `"paws"`, `"ghosts"`, `"chatter"`, `"leaves"`, or `"custom"` with `chat.customImage` naming a file in `~/.ironpet/backgrounds`. Settings → General → Chat background sets all of this and copies a PNG or JPEG you choose into that folder.
- **Open sessions in** (`openIn`) is `"auto"`, which opens the app that started the agent (found by walking the agent's parent processes), or the bundle id of a fixed app such as `"dev.zed.Zed"`. The picker offers Cursor, VS Code, Zed, Band, Windsurf, Xcode and Finder when installed, plus your `editors` entries. In `urlTemplate`, `{cwd}` becomes the percent-encoded session folder; without a template the folder is opened with the app.
- **Reminders and alerts** moved to `automations.json` (see [Automations](#automations)). Older `reminders.water`, `stretch`, `eyes` and `integrations.githubAlerts` keys still load. They are only read once, on the first launch with automations.
- **Tasks** (`tasks`): `meetingSuggestions` offers a meeting's action items, `dueReminders` says when a task is due, and `keepDoneDays` is how long done tasks are kept. See [Tasks](#tasks).
- **Telegram** (`telegram`) is covered in [Telegram](#telegram). The bot token is not in this file; it is stored in the Keychain.
- **Voice** (`voice`) is covered in [Voice notes](#voice-notes). The API key is not in this file; it is stored in the Keychain.
- **Meetings** (`meetings`, `hotkeys.meeting`) are covered in [Meeting transcripts](#meeting-transcripts).
- If the file doesn't parse, ironpet uses the defaults and shows the error at the bottom of Settings. Saving from Settings then first copies your file to `config.invalid.json`.

## Telegram

Telegram is off by default. With it on, ironpet long-polls the Bot API (`api.telegram.org`) for your own bot, so there is no webhook and no public URL. Only messages from allowed users reach the chat.

1. In Telegram, message @BotFather, send `/newbot` and copy the token.
2. In **Settings → Integrations**, paste the token, press Save, then Test. The token goes to the Keychain (`ironpet.telegram`), never to `~/.ironpet`.
3. Turn on **Chat from Telegram**.
4. Message your bot `/start`. A bubble next to the pet asks Allow or Deny. While nobody is allowed yet, that is the only message anyone can use to ask; you can also add a user id by hand in Settings.

A message from an allowed user goes into the chat that is open on the Mac and does not change its session or folder. If the agent is busy it waits and runs when the current turn ends. The answer to a message sent from Telegram goes back to that Telegram chat, split into messages of at most 4096 characters. Turns you start on the Mac are not sent to Telegram. `/status` shows the chat title and whether the agent is busy. Private chats only.

- **Files.** A photo or document you send is downloaded to `~/.ironpet/telegram/files/<chat id>/` and attached to the message in the chat, like a file you attach on the Mac. The caption is the message text. Telegram lets bots download files up to 20 MB; a larger file gets a reply saying so and nothing reaches the chat. The newest 50 downloads per chat are kept.
- **Voice messages.** With voice notes on (Settings → Voice), a voice message, audio file or video note is sent to your transcription server. Telegram gets the transcript first (`🎙 text`) and the chat gets it as the message text. AVFoundation cannot decode OGG/Opus on macOS, so voice messages are sent to the server as OGG; use a server that accepts it (OpenAI and Whisper-style servers do). With voice off, or when transcription fails, Telegram gets the error and nothing reaches the chat.
- **Approvals.** When a turn started from Telegram needs a tool approval, Telegram gets the same title and detail as the Mac, with Approve and Reject buttons. A tap applies the decision the way the Mac's Allow and Deny buttons do, and the message is edited to show the outcome. If you answer on the Mac first, the message says so and a later tap does nothing. Only allowed users can press the buttons. The Mac offers no "Always", so there is no such button.

The allowed users live in `telegram.allowedUsers` in config.json. A bad token, a lost connection or a second program polling the same bot shows in the status line, and polling retries with a delay that doubles up to 5 minutes.

## Voice notes

Voice notes are off by default. ironpet ships and downloads no speech model; it records the microphone as a 16 kHz mono WAV and posts it to any server that speaks the OpenAI transcription API (`POST {baseUrl}/audio/transcriptions`, with `file`, `model` and `response_format=json`). With the feature off, the microphone is never opened, no permission is requested and nothing is sent.

Turn it on under **Settings → Voice**, then fill in:

| Setting | `config.json` key | Notes |
| --- | --- | --- |
| Base URL | `voice.baseUrl` | Without `/audio/transcriptions` |
| Model | `voice.model` | Sent as the `model` field |
| API key | none | Optional. Stored in the Keychain (`ironpet.voice`), never in `~/.ironpet` |
| Voice shortcut | `hotkeys.voice` | Default <kbd>⌥⌘V</kbd>. Registered only while voice notes are on |
| Hold to talk | `voice.holdToTalk` | Default on: hold the shortcut to record and release to transcribe. Off: press once to start and again to stop |

The transcript goes into the chat input for you to edit, or is sent right away when **Send voice notes automatically** is on in the chat's settings menu (on by default). Pasted, typed and Wispr Flow text is never sent automatically.

**Test connection** sends a one-second tone and shows the server's answer or the error.

| Provider | Base URL | Model |
| --- | --- | --- |
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini-transcribe` |
| Groq | `https://api.groq.com/openai/v1` | `whisper-large-v3-turbo` |
| Local [mlx-audio](https://github.com/Blaizzy/mlx-audio) (Apple Silicon) | `http://localhost:8000/v1` | `mlx-community/parakeet-tdt-0.6b-v3` |

For the local option, start the server yourself with `uvx --from "mlx-audio[server]" mlx_audio.server`. It needs no key.

To record, click the microphone button in the chat input (click again to stop) or use the voice shortcut (hold and release, or press to start and press again to stop, depending on Hold to talk). While recording, Enter stops and transcribes and Esc cancels. While recording, a waveform with the elapsed time replaces the whole input, with only Stop and Cancel left; while transcribing it shows a spinner and Cancel. A note is cut off after 5 minutes. If the server is unreachable or answers with an error, the chat shows the error with a **Retry** button that sends the same recording again. The first recording makes macOS ask for microphone access.

## Your data

All in `~/.ironpet/`:

| Path | Contents |
| --- | --- |
| `memory/` | `me.md` and one file per project; edit freely |
| `threads/` | Saved chats |
| `screenshots/` | Last 30 captures |
| `config.json` | Your settings |
| `ironpet.db` | Tasks, automation state and logs, usage |
| `pets/` | Your pet library: every valid sprite sheet here shows in Settings → Pet |
| `pet/spritesheet.png` | Optional custom pet art (overrides the bundled Ghost) |
| `bin/ironpet-hook`, `port`, `token` | Hook bridge |

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to propose changes.

```bash
swift build                          # debug build
swift test                           # unit tests
./scripts/install.sh                 # release build, install, restart
python3 scripts/e2e.py               # end-to-end tests against real agent runs
./scripts/screenshots.sh             # render the README screenshots from sample data
```

`scripts/e2e.py` relaunches the installed app with `--test-mode`, drives real Cursor, Claude Code, Codex, Gemini and OpenCode turns over ACP through test-only endpoints (Allow/Deny in chat and from notifications, folder picker, Auto mode, iTerm jump, screen capture, agent summaries, GitHub alert rules), checks the results on disk and in iTerm, then relaunches the app normally. Run a subset with e.g. `python3 scripts/e2e.py cursor claude`.

`setup` and `settings` drive the real welcome window, the Settings window and the ironpet window's Automations section through macOS accessibility (System Events): they tick switches, record a shortcut and press it, edit `config.json` by hand, and check `config.json` and the hook files after each step. Your terminal needs Accessibility permission (System Settings → Privacy & Security → Accessibility). They bring ironpet to the front while running, so don't type until they finish. Your `config.json`, hook files and setup state are restored afterwards.

### Changing the pet

Ghost is drawn in code, not from image files; `scripts/bundle.sh` generates the sheet into the app. The same script draws five other pets, with every animation Ghost has:

| Pet | Look |
| --- | --- |
| `ghost` | White direwolf in a Night's Watch cloak (the default) |
| `mochi` | Mint wolf |
| `hamster` | Golden hamster with cheek pouches and buck teeth |
| `panda` | Panda with eye patches and black paws |
| `bunny` | Lilac bunny with long ears and a cotton tail |
| `cat` | Grey tabby with green eyes and a curly tail |

Open Settings → Pet to see every pet as an animated tile and click one to switch. The gallery lists the six bundled pets, every valid PNG or WebP sheet in `~/.ironpet/pets/`, and the current `pet.sprite` if it lives elsewhere. A sheet in `~/.ironpet/pets/` replaces the bundled pet of the same name, and files that are not valid sheets are skipped. New files appear within a couple of seconds while Settings is open. With Reduce Motion on, tiles show one still frame.

Picking a pet also renames it, but only while the name is still a default one (a built-in pet's name or the previous pet's name). A name you typed stays.

- **Add from file…** copies a sheet you choose into `~/.ironpet/pets/` and selects it.
- **Build a new pet** asks for a one-line description, then sends it to your current chat thread as `/ironpet-pets red fox with a scarf`. The `ironpet-pets` skill (`skills/ironpet-pets/SKILL.md`) holds the atlas layout and the steps: copy the generator (`make_pet.swift` in the app's Resources), add a theme, render, check, then move the sheet into `~/.ironpet/pets/`. If no agent on your Mac has the skill, the click installs it first, like Settings → Skills does, and the skill updates there like `ironpet-automations`. An agent session that was already running may need a restart to see a newly installed skill. The chat's session and folder stay as they are. When the agent writes the file, the new pet shows up in the gallery. If the agent is still running, or the chat has no folder yet, the request waits in the input box.

To make a sheet by hand:

```bash
swift tools/make_pet.swift cat ~/.ironpet/pets/cat.png   # joins the gallery
swift tools/make_pet.swift ghost --single build/pet.png && swift tools/make_icon.swift build/pet.png Resources/icon-1024.png
```

Any sprite sheet in the Codex pet v2 layout (1536 px wide, 8 columns of 192×208 cells) works. `pet.sprite` in `config.json` still takes a path, and `~/.ironpet/pet/spritesheet.png` still overrides the default when `pet.sprite` is unset.

## Uninstall

```bash
./scripts/uninstall.sh            # asks before deleting ~/.ironpet and the signing identity
./scripts/uninstall.sh --purge    # deletes everything without asking
```

It removes only ironpet's entries from the agents' configs (your other hooks stay) and deletes the two files ironpet owns (Copilot's `ironpet.json` and Pi's `ironpet.ts`), the login item, the app, the Sentry token in the Keychain and the app's preferences. The `*.ironpet-backup` files are kept, since they're your configs from before ironpet.

## Screen capture

Screen capture is off by default. When on, ironpet reads the text of the window you are using through Accessibility, keeps it in `~/.ironpet/ironpet.db`, filters it with a model on your Mac, and after a quiet period asks your chosen agent to look up your tasks and suggest what needs your action. Suggestions appear as bubbles with Add, Edit and Ignore. Nothing becomes a task until you click. With the switch off nothing is read, no model runs, and macOS shows no permission prompt.

**Redaction.** Every item goes through the rules first: AWS, GitHub, GitLab, Anthropic and other `sk-` keys, Stripe, Slack, Google, npm and SendGrid keys, JWTs, private key blocks, `user:password@` in URLs and secret query parameters, `password=`, `token:` and `.env`-style assignments, card and bank numbers, and long random strings. Each span becomes `[redacted:<kind>]`. The local model scores the redacted text, and an item still flagged stays on your Mac. The unredacted text of an item that had a secret is kept for 24 hours, never sent, and can be seen with **Show captures → Reveal original**. After that only the redacted text remains. The send log and Show captures say what happened, for example "redacted 2 spans (aws-key 1, secret-assignment 1), sent".

Turn it on under **Settings → Screen**. macOS asks for Accessibility then. Screen Recording is optional and only used to read the chat name in Viber's header on the device.

| Setting | Key | Notes |
| --- | --- | --- |
| Screen capture | `screenCapture.enabled` | Default off |
| Decision model | `screenCapture.decision.baseUrl`, `.model`, `.api` | `systemone` (H2O-Lightning-4B) or `openai`. The address must be localhost, or nothing is sent |
| Secret threshold | `screenCapture.decision.secretThreshold` | Default 0.2. The model scores the text after redaction. An item still at or above it stays on the Mac and its text is dropped |
| Calendar threshold | `screenCapture.decision.calendarThreshold` | Default 0.2. Only matters with a skip threshold: an item at or above it is never skipped as a possible calendar event |
| Skip threshold | `screenCapture.decision.skipThreshold` | Default 0, which skips nothing. The follow-up and new-task answers of 4B models were unreliable in the evaluation |
| Agent and model | `screenCapture.agent`, `.model` | An ACP agent id. Its only tools are `tasks_list` and `tasks_get` (read-only), it looks existing tasks up itself, every other permission request is refused, and it runs in `~/.ironpet/capture/agent`, not in your chat folder |
| Delay | `screenCapture.delayMinutes` | Default 3. Quiet time before a batch is sent |
| Apps allowed to send | `screenCapture.sendApps` | Bundle ids. Empty by default: captures stay on this Mac |
| Apps never captured | `screenCapture.excludedApps` | Bundle ids or app names, also under **Never capture** in Settings |
| Retention | `screenCapture.retentionDays` | Default 30 |

Never captured, whatever a rule says: secure text fields, password managers and authenticator apps, the lock screen, private browser windows, and `file:`, `data:`, `javascript:`, `blob:`, `about:` and browser-internal URLs. Secrets in the text are redacted before anything is stored, scored or sent (see below), and secrets in an item's URL (`code`, `token`, `key`, `sig` and others) are stripped. Every send to the agent is listed in Settings with the time, the agent and model, the capture ids and the size. If no local model is set or it does not answer, nothing is sent.

The rules that turn a window into a conversation or a document are lookback's JavaScript rules (`capture-rules/`). A file in `~/.ironpet/capture/rules` replaces the bundled rule of the same name. After editing a bundled rule, run `python3 scripts/gen_capture_rules.py`.

Pause capture from the pet menu or Settings. **Settings → Screen → Show captures…** lists everything stored with the filter's scores, so you can see what was kept. Suggestions you accept become tasks in the Tasks section of the ironpet window (source `capture`, with the capture item ids in the notes). The agent looks up your tasks (open and done) with read-only tools and can suggest updating one, for example a new due date or done.

## Meeting transcripts

Meeting transcripts are off by default. They reuse the server from **Settings → Voice** (`voice.baseUrl`, `voice.model`, the Keychain key), so ironpet still ships no speech model. With the feature off there is no menu item, no shortcut, no panel, and macOS is never asked for microphone or screen access.

Turn it on under **Settings → Meetings**. The switch only turns on after the voice server passes the same test as **Test connection**.

| Setting | `config.json` key | Notes |
| --- | --- | --- |
| Meeting transcripts | `meetings.enabled` | Default off |
| Summary agent | `meetings.summaryAgent` | An ACP agent id such as `"claude"` or `"cursor"`. Settings lists the installed agents |
| Summary model | `meetings.summaryModel` | A model id the agent reported in the chat. Unset uses the agent's default. Settings offers the models the agent listed the last time it ran in the chat |
| Summarize automatically | `meetings.autoSummary` | Default on. Off means no agent runs |
| Offer to record calls | `meetings.offerToRecordCalls` | Default on, and only applies with meetings on. When another app holds the microphone for about 10 seconds, Ghost asks whether to record it. Nothing records until you click Record |
| Recognise speakers in meetings | `meetings.recogniseSpeakers` | Default off. See [Recognising speakers](#recognising-speakers) |
| Start or stop shortcut | `hotkeys.meeting` | No default. Registered only while meetings are on |
| Last recorded app | `meetings.lastApp` | Written by ironpet: a bundle id, or `"all"` |

**Starting.** Choose **Start meeting transcript…** from the pet's menu (or press the shortcut). A small panel asks which app to record. A running Zoom, Teams, Webex, Slack or FaceTime is preselected, then your last choice, then a running browser. **All system audio** is always offered, and ironpet's own sound is always left out. The first start shows a notice about recording consent, and macOS asks for microphone and Screen & System Audio Recording access.

**While recording.** A bubble next to the pet shows a recording dot, the elapsed time, a live level for Me (your microphone) and Them (the app), the last few transcript lines, and **Stop** and **Cancel**. Cancel asks first, then deletes the meeting folder. Closing the bubble (the x on hover) hides it, and the pet shows a red **Recording** button until the meeting ends; click it to show the bubble again.

**Files.** Each meeting gets `~/.ironpet/meetings/<YYYY-MM-DD-HHmm>/` with 16 kHz mono WAV chunks (`mic-001.wav`, `them-001.wav`, ...), `transcript.md` and `summary.md`. A chunk closes at the first silence after about 2 minutes and is cut at 5 minutes. Each chunk is sent to the server as soon as it closes, and `transcript.md` is rewritten after every chunk:

```
# Meeting 2026-11-14 14:00 (Zoom)
[14:02:10] Me: Can we ship the fix today?
[14:02:15] Them: Yes, after the review.
```

The request asks for `response_format=verbose_json` to get timed segments (Whisper `segments`, Parakeet `sentences`). If the server rejects it with a 400 (OpenAI's `gpt-4o-*-transcribe` models do), ironpet retries once with `json`. If the server answers with only text, which is what mlx-audio does for Parakeet, each chunk becomes one line stamped with the chunk's start time.

**Server trouble.** A chunk that fails stays on disk and is retried with a growing delay while recording continues; the panel shows how many are waiting. A chunk that still fails when you stop gets a line like `[14:02:00–14:04:05] (not transcribed: <reason>)`. **Retry** in the panel tries it again.

**Summary.** When the transcript is final, ironpet runs the agent and model from settings and writes its answer to `summary.md`: a short summary, decisions, and open action items as a checklist. A "Meeting summary ready" bubble opens it. **Open in chat** starts a new chat with `transcript.md` and `summary.md` attached.

**Regenerate.** In the Transcripts section, **Regenerate** (the circular arrow next to Ask Ghost) rebuilds a past meeting from its saved audio, for example after you named a voice or changed the transcription model. **Transcript and summary** (the default click) transcribes every `mic-NNN.wav` and `them-NNN.wav` chunk again with the Settings → Voice server and model, names the voices from the voice store when speaker recognition is on, and runs the summary agent and model from Settings → Meetings. **Summary only** skips the audio and summarises the current `transcript.md`, which is what you want after naming a speaker. Nothing in the folder changes until the whole run succeeded. The files it replaces stay as `transcript.prev.md` and `summary.prev.md` (one generation; a second regeneration overwrites them), and a failure leaves the old files and shows the error under the toolbar. The row and the page header show "Transcribing chunk 2 of 5", then "Summarising". One meeting is rebuilt at a time, and the button is disabled, with the reason in its tooltip, while that meeting is recording or summarising and when its audio is gone. A ticked action item (`- [x]`) stays ticked in the new summary when its text matches, ignoring case, spacing and a closing full stop. Task suggestions are only offered for action items the old summary did not have. A name you typed for a voice that is not in the voice store is not kept, because the new transcript is built from the voice store and the audio.

### Recognising speakers

With **Settings → Meetings → Recognise speakers in meetings** on, ironpet splits the Them track into individual speakers on this Mac, after each chunk is transcribed. Lines read `Speaker 1: ...` until you name the voice. The Me track is never split.

- **Models.** The first time you turn the switch on, ironpet downloads about 21 MB of Core ML models from Hugging Face into `~/Library/Application Support/FluidAudio/Models` and compiles them. Settings shows the progress, then "Ready". Turning the switch off and on again does not download them again. A meeting never downloads anything: when the models are missing, the meeting runs as it does with the switch off.
- **Who is this?** When a meeting is done, the bubble says new voices were found, with a **Label speaker voices** button that opens Settings → Meetings. There, each voice that spoke for 3 seconds or more and has no name is listed with its talk time, a clip of up to 5 seconds, one transcript line and a name field. Closing the bubble keeps the list until the next meeting starts. **Ignore** and **Two people mixed** stop ironpet asking and keep the voice out of the store. Naming a voice rewrites `transcript.md`, and the list then offers **Regenerate summary**, which runs the summary again with the new names (nothing runs until you press it, and the old summary is kept as `summary.prev.md`).
- **Next meetings.** A voice that matches a stored voiceprint with a cosine similarity of 0.70 or more, and 0.10 ahead of the second best, gets the name. From 0.55 to 0.70 ironpet suggests the name and asks. Below 0.55 it is `Speaker N`. These numbers are in `SpeakerThresholds` (`Meeting/SpeakerMatcher.swift`) and come from one measured meeting.
- **Voiceprints.** One 256 number centroid per person, their name, seconds of speech and the number of meetings, in `~/Library/Application Support/IronPet/voices.enc`. The file is AES-GCM encrypted with a key in the Keychain item `ironpet.voiceprints`. A voice is added only when you name it and it has 10 seconds of speech or more. No audio is stored in it. **Forget this voice** and **Forget all voices** in Settings delete entries at once.
- **Credits.** Speaker models: [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0), and the Core ML conversion of pyannote community-1 and WeSpeaker published by FluidInference on Hugging Face (CC-BY-4.0). See [Third-party software](#third-party-software).
