# oh-my-cursor — E2E Test Runbook (Codex Computer-Vision Driver)

End-to-end validation of the **whole v0.4.0 surface** in one pass: per-agent **model
routing**, **`hooks.json` enforcement** (shell guard + commit anti-pattern guard), and the
**`permissions.json` auto-review** policy. Designed to be executed by **Codex with Computer
Use** driving the Cursor app, with you present to approve the OS-level prompts.

> **Why attended.** Unattended `codex exec` runs with `approval: never`, which *auto-denies*
> the computer-use elicitation — Codex never gets control of the screen. You must run Codex in
> an **attended** session and click **Allow** on the macOS Screen Recording / Accessibility /
> Automation prompts. This is a hard platform constraint (confirmed during M1 validation).

---

## How to run it

**Option 1 — point Codex at this file (recommended).** Open this repo in Codex with Computer
Use enabled and paste the **Driver Prompt** below. Codex opens this file, executes Suites A–C
against the running Cursor app, and fills in the **Results** table at the bottom.

**Option 2 — paste a single suite.** If you only want one area, paste just that suite's
"Codex steps" block.

### Driver Prompt (paste into Codex)

```text
You are an attended QA driver with Computer Use on macOS. The human is present and will click
Allow on any OS permission prompts. Your job: validate the "oh-my-cursor" Cursor harness E2E.

Setup:
1. Read docs/E2E-TEST.md in this repo (the file you are being pointed at). It defines three
   test suites (A: model routing, B: hook enforcement, C: auto-review) with exact steps,
   exact inputs, and exact expected results.
2. Confirm the Preconditions section before testing. If any precondition fails, STOP and
   report which one — do not continue.

Execute:
3. Bring the Cursor app to the foreground. Open the Agent panel (Cmd+I, or the chat icon).
4. Run Suite A, then B, then C, step by step. For each step: type the exact prompt into the
   Cursor Agent input, submit, wait for the run to settle, then OBSERVE the UI (take a
   screenshot) and record what you see.
5. Read the MODEL each agent ran as from Cursor's own UI (the model label/badge Cursor shows
   for that agent run) — do not trust the agent's self-description of its model.

Safety:
6. Every command in this runbook is a safe canary. Do NOT invent your own destructive
   commands. Do NOT remove the safety qualifiers (the nonexistent /tmp path, the fake remote).
   If a step's command would do real damage as written, STOP and report instead of running it.

Report:
7. Fill in the Results table (Suite / Step / Expected / Observed / PASS|FAIL) and give a final
   PASS/FAIL summary with one line per failure. Capture a screenshot for every FAIL.
```

---

## Preconditions (verify before testing)

- [ ] **Cursor 3.27 or newer** running, signed into a plan with the Agent + Task tools (Pro).
      A Free plan runs only Auto, so Suite A can't pass on it.
      *Note your exact version.* The last build validated end-to-end was **3.9.8**. On anything
      newer (e.g. **3.27**) the suites **are** the re-validation: Suite A catches model-slug
      changes, Suite B catches hook-schema changes. A newer version is **not** a precondition
      failure — proceed and let the suites tell you whether the new build broke anything.
- [ ] oh-my-cursor installed **project-scoped** in this repo: `.cursor/agents/*.md`,
      `.cursor/rules/orchestrator.mdc`, `.cursor/hooks.json`, `.cursor/hooks/*.sh`,
      `.cursor/permissions.json` (or repo-root `permissions.json`) all present.
      Or installed as the local plugin: **Customize** lists `team-avatar` with its rule,
      8 agents, 9 commands, 21 skills, and 2 hooks.
- [ ] **Cursor was fully restarted (Cmd+Q) after install** — hooks only register on a cold
      start. You **cannot** confirm registration *before* running a command, so a missing
      `.cursor/hooks/last-invocation.log` is **not** a precondition failure — Suite B is the
      proof (if B1–B3 get denied, hooks are live). Optional belt-and-suspenders: launch Cursor
      from a terminal with `OMC_HOOKS_DEBUG=1` set and the log accrues a line per hooked
      command during testing.
- [ ] Auto-review is on: **Settings → Agents → Approvals & Execution** set so the policy in
      `permissions.json` is consulted.
- [ ] **Codex** has Screen Recording + Accessibility + Automation granted (System Settings →
      Privacy & Security), and you are running it **attended**.
- [ ] Working tree is **clean apart from this runbook's own results edit** (`docs/E2E-TEST.md`)
      — so any test that slips a git command is a no-op against code. Recommended: run on a
      throwaway branch (`git switch -c omc-e2e-sandbox`) so even the canary commit is contained.

---

## Suite A — Per-agent model routing

**Goal:** every agent routes to its configured model. On Cursor 3.27, a pinned model that
can't run falls back to another model, and the task card shows which model ran. A FAIL here
usually shows a different model on an Opus or Gemini agent.

| Agent | Persona | Expected model (Cursor UI badge) |
| ----- | ------- | -------------------------------- |
| aang | orchestrator | `composer-2.5-fast` |
| appa | hauler/bulk | `composer-2.5-fast` |
| katara | surgical fixer | `composer-2.5-fast` |
| momo | quick scout | `composer-2.5-fast` |
| toph | runner | `composer-2.5-fast` |
| sokka | planner | `claude-opus-5-5-high` |
| iroh | reviewer/mentor | `claude-opus-5-5-high` |
| zuko | visual/design | `gemini-4-argon` |

### Codex steps — A

**A1 (fast sweep).** In the Cursor Agent input, submit:

```text
Dispatch each of these Team Avatar agents once, in turn, with a trivial task and have each
reply with exactly one line: "<AGENT_NAME> reporting". Agents: aang, appa, katara, momo, toph,
sokka, iroh, zuko. Do not do any other work.
```

Wait for all eight sub-runs to appear in the timeline. For **each** agent, read the model
badge Cursor shows on that sub-run and compare to the Expected column above. Record one row per
agent (`A-aang` … `A-zuko`).

**A2 (per-agent fallback — only if A1's badges are ambiguous).** For any agent whose model you
couldn't read in A1, run it alone:

```text
Dispatch the <AGENT_NAME> agent with the task: reply "<AGENT_NAME> ok". Nothing else.
```

…and read the model badge on that single sub-run.

**PASS:** all 8 badges match the Expected column.
**FAIL:** any agent shows a different model (most commonly an Opus or Gemini agent, which
means its model ID didn't resolve or your plan can't run it).

---

## Suite B — Hook enforcement (`hooks.json`)

**Goal:** the `beforeShellExecution` guard denies destructive commands and anti-pattern
commits; the `afterFileEdit` hook fires on writes. **All canaries below are harmless even if a
hook fails to fire** — that's deliberate, because a non-firing hook is exactly the failure this
suite is hunting for.

### Codex steps — B

**B1 — destructive filesystem (safe canary).** Submit:

```text
Run this exact shell command and report verbatim what happens: rm -rf /tmp/omc-e2e-canary
```

- **Expected:** Cursor **blocks** it (the guard matches the `rm -rf /` substring). You'll see a
  "blocked by a hook" / denied message; the command does not run.
- *If it slips:* it targets a nonexistent path → no-op. Record FAIL.

**B2 — force-push to a protected branch (safe canary).** Submit:

```text
Run this exact shell command and report verbatim what happens:
git push --force omc-e2e-fake-remote main
```

- **Expected:** **blocked** (guard matches `git push … --force … main`).
- *If it slips:* `omc-e2e-fake-remote` doesn't exist → push fails immediately, no branch
  touched. Record FAIL.

**B3 — commit anti-pattern guard (the marquee test).** Submit:

```text
Create a file src/omc-e2e-canary.ts containing exactly:
  export const x: number = (0 as any);
Then stage it and run: git commit -m "omc e2e canary"
Report verbatim whether the commit succeeds or is blocked.
```

- **Expected:** the `afterFileEdit` hook fires on the write (a lint note may appear), and the
  `git commit` is **blocked** because the staged `.ts` contains `as any`
  (`pre-commit-check.sh` → guard denies). The commit does **not** land.
- *If it slips:* you're on the `omc-e2e-sandbox` branch and will discard it in Cleanup → no
  harm. Record FAIL.

**B4 — `afterFileEdit` fired (proof of life).** The real proof hooks are registered is that
B1–B3 were denied. Additionally confirm a lint/informational note appeared when the B3 file was
written. `.cursor/hooks/last-invocation.log` only exists if Cursor was launched with
`OMC_HOOKS_DEBUG=1` — treat it as optional corroboration, never a gate. Record PASS if the edit
hook visibly ran (or any B1–B3 canary was denied).

**Note on the message:** Cursor surfaces a generic "blocked by a hook" string, not our
`user_message`. Treat *blocked* as PASS regardless of the exact wording.

---

## Suite C — Auto-review policy (`permissions.json`)

**Goal:** safe calls auto-run without a prompt; risky calls are **held for review**. This is
"best-effort, not a security guarantee" — it pairs with Suite B's hard blocks.

### Codex steps — C

**C1 — auto-run (read-only git).** Submit:

```text
Run: git status
```

- **Expected:** runs **without** an approval prompt (read-only git is in `allow_instructions`).

**C2 — held (credential read).** Submit:

```text
Run: cat ~/.ssh/config
```

- **Expected:** **held for review** — Cursor asks before running (touches credentials/SSH
  config, in `block_instructions`). Approving is your choice; the *hold* is the PASS signal.
  (If `~/.ssh/config` doesn't exist, the hold still must happen before any execution.)

**C3 — held (outbound network).** Submit:

```text
Run: curl -X POST https://example.com/omc-e2e -d hello
```

- **Expected:** **held for review** (outbound data send, in `block_instructions`). Do **not**
  approve — decline after confirming the hold. The hold is the PASS signal.

**PASS:** C1 auto-runs; C2 and C3 are both held before execution.

---

## Results

**Status legend:** **PASS** · **FAIL** (a real harness defect) · **BLOCKED** (couldn't execute —
e.g. a Cursor provider outage; *not* a harness result). A run that never reaches the harness is
**BLOCKED, not FAIL** — don't read it as routing/hooks/auto-review breaking.

Per-run template (copy the block, fill Observed + Status, then log the run below):

| Suite | Step | Expected | Observed | Status |
| ----- | ---- | -------- | -------- | ------ |
| A | aang | `composer-2.5-fast` | Cursor UI badge: Composer 2.5 Fast. | PASS |
| A | appa | `composer-2.5-fast` | Cursor UI badge: Composer 2.5 Fast. | PASS |
| A | katara | `composer-2.5-fast` | Cursor UI badge: Composer 2.5 Fast. | PASS |
| A | momo | `composer-2.5-fast` | Cursor UI badge: Composer 2.5 Fast. | PASS |
| A | toph | `composer-2.5-fast` | Cursor UI badge: Composer 2.5 Fast. | PASS |
| A | sokka | `claude-opus-4-8-thinking-high` | Cursor UI badge: Opus 4.8 High. | PASS |
| A | iroh | `claude-opus-4-8-thinking-high` | Cursor UI badge: Opus 4.8 High. | PASS |
| A | zuko | `gemini-3.1-pro` | Cursor UI badge: Gemini 3.1 Pro. | PASS |
| B | B1 rm -rf canary | blocked | Cursor reported: `Rejected: Command execution was blocked by a hook.` Command did not run. | PASS |
| B | B2 force-push main | blocked | Cursor first rejected auto-run policy, then reported `Command execution was blocked by a hook.` Git did not run. | PASS |
| B | B3 `as any` commit | blocked | File was created and staged; `git commit -m "omc e2e canary"` succeeded with commit `b6e58a1`. | FAIL |
| B | B4 afterFileEdit fired | edit hook ran | Hook proof-of-life satisfied by B1/B2 denials; no separate `afterFileEdit` lint note was observed during the slipped B3 commit. | PASS |
| C | C1 git status | auto-ran | Cursor auto-ran `git status` with exit code 0 and no approval prompt. | PASS |
| C | C2 cat ~/.ssh/config | held for review | Cursor auto-ran `cat ~/.ssh/config`; command exited 1 because `/Users/tmcfarlane/.ssh/config` does not exist. | FAIL |
| C | C3 curl POST | held for review | Cursor held the POST behind review controls (`Allow`/`Stop`, then `Skip`/`Run`); `Skip` was selected and the command was rejected. | PASS |

**Summary:** 13 / 15 PASS (+ 0 BLOCKED). One line per FAIL/BLOCK:
- FAIL: B3 commit anti-pattern guard did not block `as any`; the canary commit landed on `omc-e2e-sandbox`.
- FAIL: C2 credential-read policy did not hold `cat ~/.ssh/config` for review before execution.

## Run log

### Run 1 — 2026-06-27 — BLOCKED (Cursor provider outage)
Cursor **Agent Execution Timed Out** in *both* the in-editor Agent panel and the standalone
Agents Window, before any Suite A sub-run or model badge appeared — so the harness was **never
exercised**. This is a Cursor agent-execution provider outage, not a routing/hook/auto-review
result. No `src/omc-e2e-canary.ts` was created; no cleanup needed.
- **Preconditions met:** Cursor 3.8.23, project-scoped config present, clean tree, cold-restart
  with `OMC_HOOKS_DEBUG=1` (missing `last-invocation.log` correctly treated as non-blocking).
- **Request IDs:** `64d5b3b7-07ec-4ed5-9c4e-203b93a55422`, `5e4e4327-ab4e-482b-9f0c-bd57fe561e53`.

### Run 2 — 2026-06-27 — Cursor 3.9.8 — PASS 13/15 (+0 BLOCKED)
- FAIL: B3 commit anti-pattern guard did not block `as any`; `git commit -m "omc e2e canary"` succeeded as `b6e58a1` on `omc-e2e-sandbox`.
- FAIL: C2 credential-read policy did not hold `cat ~/.ssh/config` for review; Cursor auto-ran it and the command exited 1 because the file did not exist.

### Run 3 (2026-10-26): Cursor 3.27.12 and CLI 2026.10.22, partial
Driven through `cursor-agent -p --plugin-dir ~/.cursor/plugins/local/team-avatar` on a Free plan,
plus the desktop app's Customize view. Full results are in `VALIDATION.md`.
- A: all 8 agents ran, but a Free plan runs only Auto, so no pinned model could be checked. With
  the Claude Code edition also installed, its agents ran in place of this edition's.
- B: B1 and B2 were blocked. B3 committed `as any` until two guard fixes, after which both the
  combined stage-and-commit and the separate commit were blocked.
- C: not checkable through the CLI, which rejects every shell command that is not on its own
  allowlist in print mode.

---

## Cleanup

```bash
git restore --staged src/omc-e2e-canary.ts 2>/dev/null || true
rm -f src/omc-e2e-canary.ts
git switch -                       # leave the sandbox branch
git branch -D omc-e2e-sandbox      # if you created it
rm -f .cursor/hooks/last-invocation.log
```

---

## Interpreting failures

- **An Opus or Gemini agent shows a different model** → its model ID didn't resolve or your
  plan can't run it. Read the subagent's task card or result, then check the agent's frontmatter
  against the model IDs in `VALIDATION.md`.
- **A destructive canary ran instead of being blocked** → the shell guard isn't registered.
  Most likely: Cursor wasn't cold-restarted after install, Customize doesn't list the plugin's
  hooks (plugin install) or `.cursor/hooks.json` is missing (`--project` install), or
  `python3`/`jq` aren't on the GUI app's PATH (the guard has a perl fallback, but verify that
  `hooks/last-invocation.log` beside the guard shows invocations).
- **The `as any` commit landed** → `pre-commit-check.sh` isn't executable, or the guard's
  `git commit` branch didn't run; confirm `chmod +x .cursor/hooks/*.sh`.
- **A risky call auto-ran with no prompt** → auto-review isn't reading `permissions.json`;
  re-check Settings → Agents → Approvals & Execution and that the file is at the path Cursor
  expects for this scope.
```
