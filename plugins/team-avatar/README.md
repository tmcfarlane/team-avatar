# Team Avatar

Principal-level engineering skills for Claude Code and Codex. Each skill belongs to a character from *Avatar: The Last Airbender*, and each character owns the discipline that fits who they are. Aang routes the work through `avatar-mode`. The rest of the team does the part they are best at. Other harnesses that load Agent Skills can run the skills too, as [Other harnesses](../../README.md#other-harnesses) explains.

The ground rules are the same everywhere. Read before you claim. Name the data shape before you write logic. Ship the smallest change the evidence justifies. Prove it on the real artifact. Team Avatar adapts pstack's poteto mode, and [NOTICE.md](NOTICE.md) credits every upstream source.

## The team

<!-- team:roster:start -->
| Character | Discipline | Skills |
|-----------|------------|--------|
| Aang | Orchestration, history, and the final call | `avatar-mode`, `four-elements`, `past-lives`, `spirit-world`, `iceberg-wake`, `meditation`, `avatar-setup`, `avatar-help` |
| Sokka | Planning, architecture, and inventions | `master-plan`, `war-room`, `day-of-black-sun`, `battle-map`, `war-journal`, `invention-workshop`, `sharpen-the-sword` |
| Toph | Investigation and blunt review | `seismic-sense`, `earth-rumble`, `metalbending`, `lie-detector`, `my-cabbages`, `plain-talk` |
| Katara | Debugging, tests, and code health | `healing-water`, `agent-qa`, `push-and-pull`, `heal-ci`, `purify`, `clear-water`, `vital-signs`, `checkup`, `typescript-forms` |
| Zuko | Performance, forensics, and incidents | `breath-of-fire`, `steady-flame`, `dragon-dance`, `ember-trace`, `twin-flames`, `agni-kai`, `redemption-arc`, `honor-code` |
| Iroh | Writing, teaching, and skill craft | `tea-time`, `white-lotus`, `what-you-seek`, `new-scroll`, `pai-sho` |
| Appa | Execution, shipping, and PR care | `steady-flight`, `yip-yip`, `light-load`, `long-flight`, `safe-landing`, `clear-skies`, `messenger-hawk`, `make-camp`, `break-camp`, `shedding-season` |
| Momo | Throwaway spikes and quick tasks | `scouting-flight` |
| Suki | Parallel squads and long autonomous runs | `kyoshi-formation`, `kyoshi-command`, `night-watch`, `full-patrol`, `shield-wall` |
<!-- team:roster:end -->

## How it fits together

- **`avatar-mode` is the front door.** Ask for it with a task in plain words. Aang picks the character and the skill chain, and holds the rules every skill follows.
- **`four-elements` holds the principles.** Air subtracts, Water adapts, Earth holds, Fire drives. Each principle has its own reference file.
- **The session hook turns avatar mode on for you.** When a session starts, it tells the agent to route nontrivial work through `avatar-mode`. Turn it off with `session hook: off` in the model sheet.
- **`avatar-setup` picks the models.** It writes a small sheet with one model per character, a `panel` of models for multi-model reviews, a default effort, and the hook switch. [Pick the models](#pick-the-models) covers the sheet and its defaults.
- **`avatar-help` is the guide for new users.** It explains all of this, with prompt recipes.

## Install

### Claude Code

```bash
claude plugin marketplace add tmcfarlane/team-avatar
claude plugin install team-avatar@team-avatar
```

Start a session and ask for avatar mode, or call a skill directly, for example `/team-avatar:healing-water`. The characters are available as subagents named `team-avatar:<character>`.

To try a local checkout without installing, run `claude --plugin-dir plugins/team-avatar` from the repository root.

### Codex

```bash
codex plugin marketplace add tmcfarlane/team-avatar
codex plugin add team-avatar@team-avatar
```

Start a session and ask for `$avatar-mode`, or call a skill directly, for example `$earth-rumble`. Codex reads [skills/avatar-mode/references/codex.md](skills/avatar-mode/references/codex.md) for its tool and subagent equivalents. Character subagents need `multi_agent = true` under `[features]` in `~/.codex/config.toml`.

To try a local checkout, pass its path instead of `tmcfarlane/team-avatar`.

## Pick the models

Each character runs on the model its line names in the runtime's sheet. Claude Code reads `~/.claude/team-avatar-models.md`, and Codex reads `~/.codex/team-avatar-models.md`. Run `avatar-setup` (`/team-avatar:avatar-setup` or `$avatar-setup`) to write or change the sheet. To print the lines that apply, run this from the repository root:

```bash
sh plugins/team-avatar/skills/avatar-setup/scripts/show-sheet.sh claude
```

Pass `codex` instead of `claude` for the Codex sheet. A line that the sheet doesn't have takes its default:

| Line | Default | Runs |
|------|---------|------|
| `aang` | `inherit` | Aang as a subagent, on the parent session's model |
| `sokka`, `katara`, `zuko`, `iroh`, `suki`, `toph review` | `opus` | Planning, fixes, performance, prose, squad workers and verification, and Toph's reviews |
| `toph`, `appa` | `sonnet` | Investigation, and feature code that follows a settled plan |
| `momo` | `haiku` | Throwaway spikes and trivial edits |
| `strongest` | `fable` | The hardest changes and the strongest judgment calls |
| `panel` | `opus, fable, sonnet, haiku` | Multi-model reviews, with one runner per entry |
| `default effort` | `session` | The parent session's effort, for every line with no `@level` |
| `session hook` | `on` | The SessionStart hook that routes work into `avatar-mode` |

The defaults name Claude models. On Codex, run `$avatar-setup` once to name your Codex models. Without a Codex sheet, the agent picks Codex substitutes on its own. A line can also carry an effort, as in `sokka: opus @high`.

## Requirements

Most skills need nothing but the agent. A few drive helper tools:

- `long-flight`, `safe-landing`, and `kyoshi-command` run the [bun](https://bun.sh) tools in `tools/` (the PR watcher, the shipping gate, and the orchestration store). The tools install their one dependency on first run.
- `master-plan`, `make-camp`, `shedding-season`, `meditation`, and `avatar-mode` ship small scripts that run with plain `node`, `sh`, or `bash`.
- PR skills use the GitHub CLI (`gh`).

## Develop

Every skill has an owner in [team.json](team.json). The roster tables in this README, in `avatar-mode`, and in each character file are generated from it. To add or move a skill, edit `team.json`, then run both scripts from the repository root:

```bash
node scripts/generate-team-avatar.mjs
```

```bash
node scripts/validate-team-avatar.mjs
```

The validator checks skill and agent frontmatter, that every skill is registered and owned by a real character, that the generated tables are current, that referenced skills and links exist, that all manifests agree on name and version, and that no file uses a long dash or an upstream name. CI runs it, and the `tools/` test suite, on every pull request that touches the plugin. `new-scroll` walks through writing a new skill.

## End-to-end tests

`evals/team-avatar/` runs the same 29 cases against real headless Claude Code and Codex sessions: 18 routing checks, skill discovery, and real tasks on throwaway repos (a planted bug, a planted SQL injection, test-first work, docs, planning, model setup, dispatching Toph, and the session hook). The same deterministic checks grade every run. In the latest run, both Claude Code and Codex passed 29 of 29, as [docs/evidence/team-avatar-evals](../../docs/evidence/team-avatar-evals/README.md) shows.

```bash
node evals/team-avatar/run.mjs --runtime claude --jobs 4
```

```bash
node evals/team-avatar/run.mjs --runtime codex --jobs 4
```
