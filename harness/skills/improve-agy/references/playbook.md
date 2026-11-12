# Recommendation playbook

Map each friction pattern from `digest.md` to a concrete, Antigravity/Jetski-native fix. Every action item names the
mechanism (rule, skill, hook, automation, habit), its location, paste-ready text or the exact command, and the digest
metric that should move. The item format itself is defined in SKILL.md ("Output contract").

## Contents

- [Where fixes live](#where-fixes-live)
- [Pattern → fix table](#pattern--fix-table)
- [Rule snippet template](#rule-snippet-template)
- [When the fix is a skill](#when-the-fix-is-a-skill)
- [Escalation when an action did not work](#escalation-when-an-action-did-not-work)

## Where fixes live

| Mechanism | Location | Use for |
|---|---|---|
| Global rule | `~/.gemini/config/AGENTS.md` (or `GEMINI.md`), always loaded | Preferences that hold in every workspace (tone, tooling bans, approval habits) |
| Workspace rule | `<repo>/AGENTS.md`, `<repo>/.agents/rules/*.md` | How to build/test/run this project, naming, review gates |
| Skill | `~/.gemini/skills/<name>/SKILL.md` (user-invokable as `/<name>`), create with `/skill-creator` | Multi-step procedures the user keeps re-explaining |
| `/learn` | Built-in command | Persist a single correction right after it happens |
| Hook | `~/.gemini/config/hooks.json` (`PreToolUse`, `PostToolUse`, `Stop`, `SessionStart`) | Mechanical guards (block a command pattern, inject context at session start, refuse to stop with tests running) |
| Automation | `/automation` → `~/.gemini/jetski/sidecars/<slug>/sidecar.json` with `"builtin": "schedule"` | Work the user requests on a cadence (reports, digests, dependency checks) |
| MCP server | `~/.gemini/config/mcp_config.json` | Repeated web lookups or manual API calls that a tool could answer |
| Workflow habit | Say it in the report, no file change | `/plan`, `/grill-me`, `/compact`, `/goal`, subagents, `/rubber-duck-review` |

## Pattern → fix table

| Pattern in digest | Likely cause | Recommended fix |
|---|---|---|
| Same correction theme in ≥ 3 sessions (e.g. "too verbose", "don't commit", "use uv tool run") | Preference never persisted | Global rule (template below) or `/learn` immediately after the next occurrence |
| Corrections about project conventions in one workspace | Missing project instructions | Workspace `AGENTS.md` section with the exact command/convention; suggest `/agent-instructions` to regenerate |
| Correction after agent edited the wrong file / branch | Underspecified request | Habit: `/plan` for multi-file work; rule "confirm target files before editing when the request names none" |
| High rapid re-prompt rate | Requests too short, agent asks nothing | Habit: `/grill-me` for design decisions; rule to use `ask_question` when acceptance criteria are missing |
| Same multi-step procedure re-explained across sessions (visible in first requests) | No skill | `/skill-creator <name>` with the procedure; list the steps you saw in the transcripts |
| Same command failing ≥ 2× per session (`go test`, `make test`, `pytest`) | Environment or flag knowledge not written down | Workspace rule with the working invocation; optional `PreToolUse` hook that rewrites the bad form |
| Sandbox blocks on the same path/binary in ≥ 3 sessions | Tool needs network or files outside the workspace | Rule describing the one-step `BypassSandbox` pattern for that command, or move data into the workspace; never recommend evading the sandbox |
| `Operation not permitted` on a binary (Santa) | Blocked binary | Rule with the allowed alternative (`uv tool run`, `brew reinstall`), consistent with the user's Santa rules |
| Tool errors `file does not exist` / `path is a directory` | Guessing paths | Habit: list the directory before reading; rule "resolve paths with `ls`/`find` before `read_file` outside the workspace" |
| Retries of `edit_file` with identical args | Target text mismatch | Habit: re-read the target lines before editing; prefer smaller targets |
| Polling > 5 per session | Manual task polling | Habit: `run_command` with `NotificationTimeoutSeconds`, `schedule` with `TimerCondition`, stop calling `manage_task status` in loops |
| Compactions ≥ 1 per session, huge input tokens | Context pressure from large tool outputs | Habits: pipe long outputs through `head`/`tail`/`grep`, write results to scratch files, delegate reading to `research` subagents, `/compact` at milestones, split long sessions by task |
| Low cache hit ratio (< 60%) | Fresh conversations for tiny tasks, rules edited mid-session | Habit: continue the same conversation for follow-ups; batch rule edits |
| Subagent tokens ≫ main-session tokens with little merged output | Over-delegation or oversized swarms | Habit: fewer, better-briefed workers; use `flash` models for read-only research |
| API 429 / RESOURCE_EXHAUSTED clusters | Quota exhaustion, often during fan-out | Habit: avoid parallel subagents when quota is low; `swarm model` to switch; schedule heavy runs off-peak |
| Many sessions ending on a user message | Cancelled or abandoned runs | Habit: `/goal` for long tasks; `Stop` hook that blocks stopping while background tests run; review why runs were cancelled (deep-dive those sessions) |
| Same report/check requested on a cadence | Manual recurring work | `/automation` with a self-contained prompt |
| Heavy `search_web` for the same docs | Missing reference | Add an MCP docs server (`context7`, `google-developer-knowledge`) or a `references/` file in a skill |
| Many `write_file` overwrites of the same file | Regenerating instead of editing | Habit: `edit_file` with a tight target; rule for large files |
| Late-night sessions with high friction | Fatigue | Report it neutrally; suggest scheduling autonomous `/goal` runs instead |

## Rule snippet template

Give rules in this form so the user can paste them unchanged:

```markdown
## <Topic> (added <YYYY-MM-DD> from improve-agy)

- <Imperative instruction, one line, no hedging.>
- <When it applies / exception.>
```

Example derived from a recurring "no, use uv tool run" correction:

```markdown
## Python tooling (added 2026-11-11 from improve-agy)

- Run third-party Python CLIs with `uv tool run <tool>`; never `uvx` or global `pip install`.
- Applies to commands, scripts, MCP configs and docs you write.
```

## When the fix is a skill

A "create a skill" item needs more than a name. Before proposing one:

1. List what exists: `ls ~/.gemini/skills` and the workspace `.agents/skills`; read the closest match's description.
2. Decide `create` / `improve existing` / `merge into existing` / `hold as a habit` — prefer improving over adding.
3. State the trigger phrases (what the user actually typed in the sessions) and the non-trigger cases.
4. Outline the steps as observed in the sessions, including the failure the skill must prevent — a skill written from
   a failed session ("what not to do") is legitimate when the failure recurred.
5. Hand the outline to `/skill-creator` only after the user agrees; record the item in the ledger with the skill name
   as the Verify target ("skill `<name>` invoked in ≥ 1 session" shows in digest section 7).

## Escalation when an action did not work

Digest sections 9–10 show the previous actions and the metric deltas. When a recorded action's metric did not move:

| Previous mechanism | Likely reason | Next step |
|---|---|---|
| Habit (told the user / the agent in chat) | Nothing persisted | Promote to a rule |
| Rule | Rule too vague, wrong scope (workspace vs global), or conflicts with another rule | Rewrite as one imperative line with the exact command; move to the scope where the friction occurs |
| Rule that is followed but friction remains | The cause is mechanical, not behavioural | `PreToolUse` hook that blocks or rewrites the command, or a script that replaces the fragile steps |
| Skill | Not invoked (check slash usage in section 7) | Make the description trigger on the user's actual phrasing; mention the slash command in the rule |
| Hook | Hook errors in section 3 (`JSON hook … failed`) | Fix the hook command and keep it < 150 ms |

Record the escalation as a new action line in `~/.gemini/improve-agy/actions.md` and leave the old one unchecked
with a short note.
