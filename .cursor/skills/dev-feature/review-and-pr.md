# Review and PR

Final phases of `dev-feature`. Start only after the build is complete, the verification gates pass, and the docs are updated.

---

## Review — fresh subagent loop

The reviewer must not share this session's context, so it judges the diff rather than the intentions behind it.

### R.1 Commit the work

Commit everything on the feature branch first. Follow `git log --oneline -10`: a lowercase conventional subject (`feat: …`, `fix: …`, `chore: …`, `docs: …`) that says what the user gets, with a short body when the subject is not enough. Pass the message with a HEREDOC; never `--no-verify`. The reviewer reads branch changes against the base, so uncommitted files would be missed. Check that nothing private (tokens, `~/.ironpet` content, chat transcripts, meeting audio) or build output (`.build/`, `build/`, `sidecar/out/`, `sidecar/node_modules/`) is staged.

### R.2 Launch the reviewer

Launch **one** fresh `generalPurpose` subagent via the `Task` tool (`run_in_background: false`). Prompt:

```text
You are reviewing a feature branch in the ironpet repository with fresh eyes.

Repository: <absolute repo path>
Branch: <feature branch>
Base: <base branch from `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`>
Scope: branch changes (merge-base of <base> to HEAD), including any uncommitted or untracked files.
Intended behavior: <two or three sentences from the approved plan>. Judge the code, not the plan.

Read and follow .cursor/skills/dev-code-review/SKILL.md exactly, including the surface file for every surface the diff touches. Run every applicable gate.
This review is read-only: do not edit tracked files or commit. Never run scripts/install.sh, scripts/uninstall.sh, scripts/configure_sentry.sh or scripts/e2e.py, and never write to ~/.ironpet, the agents' config folders, or the Keychain.
Return the findings and the full "## Code Review Summary" block as defined by the skill.
```

### R.3 Fix and re-review

1. Fix every Critical, High, and Medium finding, plus Low findings that are cheap and safe. A finding you disagree with gets a one-line reason instead of a fix; report it to the user.
2. Re-run the gates the fixes affect and commit.
3. Launch a **new** reviewer subagent with the same prompt (never resume the old one).
4. Stop when the final status is **Approved** or **Approved with minor changes**, or after **3 rounds**. If round 3 still says **Must fix before merging**, stop and show the user the remaining findings instead of opening the PR.

Keep the last reviewer's summary block; the PR's Verification section reuses its gate results.

---

## PR

### P.1 Close out the plan

- Make sure `SPEC.md` holds the decisions from the plan that still matter after merge, and that README and SECURITY match what was built.
- Commit.

### P.2 Open the PR

Read and follow `.cursor/skills/dev-open-pr/SKILL.md`. Additionally:

- **Verification** lists the gates the final reviewer ran (with counts) as checked items, the installed-app walk-through and e2e scenarios that ran, and the ones that did not as `[ ]` with the reason.
- **Safety and privacy** says what the change touches on the user's Mac and points at the `SECURITY.md` lines. Omit it only when the change touches nothing new.
- For UI changes, upload the rendered previews to the `pr-screenshots` branch and show them in a **Screenshots** section, as in `dev-open-pr` › Screenshots.

Return the PR URL to the user, plus anything they still have to do (run the e2e scenarios that were skipped, check the installed app, look at what could not be rendered).
