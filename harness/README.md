# Antigravity harness

Hooks and agent skills for Antigravity and Jetski. A hook is a shell command the host runs at a lifecycle event such as `Stop` or `PostInvocation`. A skill is a procedure the agent loads when its trigger matches, at zero context cost until then.

```text
hooks/     hooks.json plus one directory per hook
skills/    one directory per skill, each with a SKILL.md
agents/    custom agent personas; empty so far
```

## Hooks

[hooks/hooks.json](hooks/hooks.json) registers three hooks. The host runs each command from the directory that holds `hooks.json`, which is why the commands use relative paths. Each hook prints `{}` and exits 0 on an internal error, so a broken hook cannot stall a turn.

| Hook | Event | What it does | Why you want it |
| :--- | :--- | :--- | :--- |
| `stop-bell` | `Stop` | Plays `Glass.aiff` through `afplay` when the agent ends its turn; falls back to the terminal bell where `afplay` is missing. | You can switch to another window during a long task and hear the moment the agent needs you. |
| [`show-reasoning`](hooks/show-reasoning/show_reasoning.py) | `PostInvocation` | Reads the `thinking` field of the planner steps the last model call appended to the transcript and injects a collapsible "Reasoning" block into the conversation. The injected step carries no text for the model, so it costs zero tokens. | You see why the agent chose an approach before it runs the command, the way Claude Code and Copilot show thoughts. A wrong assumption shows up in the reasoning before it shows up in the diff. |
| [`lint-enforcer`](hooks/lint-enforcer/lint-enforcer.sh) | `Stop` | Detects the toolchains in each workspace (Maven with Spotless or spring-javaformat, Python with ruff, Terraform, Dockerfiles, GitHub Actions), runs the formatter and linter for the ones with dirty files, and answers `{"decision":"continue"}` with the findings when a check fails. The agent then fixes them before it hands the turn back. | Turns end with formatted, lint-clean code without you asking for it. An idle turn costs one `jq` call and one `git status`. Forced re-entries stop after three, so a stubborn finding cannot trap the agent, and a missing linter skips its check. |

### Install

Merge the entries you want from `hooks/hooks.json` into `~/.gemini/config/hooks.json` (all workspaces) or `<workspace>/.agents/hooks.json` (one project), and point each `command` at this checkout with an absolute path, for example `python3 /path/to/harness/hooks/show-reasoning/show_reasoning.py --apps jetski,app,ide,cli`.

> [!NOTE]
> `show-reasoning` renders in the App and Jetski UI. The terminal UI (`agy`) draws nothing for hook messages; use `verbosity: high` and `Ctrl+O` there instead.

`lint-enforcer` runs on the stock macOS bash 3.2 and needs `jq`. Set `LINT_ENFORCER_MODE=warn` to report findings without forcing a continue, or `SKIP_LINT_ENFORCER=true` to turn it off. Run the tests with `bash hooks/lint-enforcer/test-lint-enforcer.sh` (bash 5 and `jq` required).

## Agent skills

Each skill is a directory with a `SKILL.md`. The agent sees the name and description at rest and loads the body when the trigger matches.

| Skill | Trigger | What it does | Why you want it |
| :--- | :--- | :--- | :--- |
| [`improve-agy`](skills/improve-agy/SKILL.md) | `/improve-agy`, or asking what to improve about working with the agent | Mines the transcripts under `~/.gemini/*/brain` for friction: your corrections, failed commands, sandbox denials, retries, context compactions, quota errors. `analyze_sessions.py` counts, `review_cards.py` labels sessions with a flash model, and the skill returns 3 to 7 action items, each with evidence, a paste-ready fix, a metric to verify, and an effort size. A ledger in `~/.gemini/improve-agy/` lets the next run report whether each metric moved. | You stop typing the same correction in session after session. Each friction pattern becomes a rule, hook, or skill with a number attached, so you know whether the fix worked. |
| [`rubber-duck-review`](skills/rubber-duck-review/SKILL.md) | "rubber duck", "second opinion", "critique this", `/rubber-duck-review`; after planning, mid-way through a multi-file change, after writing tests, after two failed attempts | Spawns a single-use critic from the other model family (Gemini 4 Argon when the session runs on Claude, Claude Opus when it runs on Gemini) with an empty context window. The critic reads the files on disk and your verbatim request, posts one critique split into Blocking, Non-blocking and Suggestions, and is killed. | A reviewer that shares none of the session's assumptions finds the ones the author missed. A different model family brings a different set of blind spots, and an empty context means it checks the change against what it finds on disk. |

### Requirements

- `improve-agy`: Python 3.12 or newer (`uv` optional), the `agy` CLI for the labelling step (an in-agent `run_workflow` fallback exists), and your `BypassSandbox` approval, since the transcripts live outside the sandbox. The scripts treat brain directories as read-only.
- `rubber-duck-review`: the `swarm` tool (falls back to `invoke_subagent` with the `rubber-duck` agent type) and the persona file `~/.gemini/config/agents/rubber-duck.md`, which this repo does not ship.

### Install

Copy or symlink `skills/<name>` into `~/.gemini/config/skills/` (all workspaces) or `<workspace>/.agents/skills/` (one project).
