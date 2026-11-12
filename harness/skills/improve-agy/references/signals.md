# Signal definitions and thresholds

How `scripts/analyze_sessions.py` computes each number in `digest.md`, and the default thresholds for deciding
whether a signal deserves an action item. Thresholds are starting points; once two or more snapshots exist, prefer
the trend in digest section 9 over absolute values.

## Contents

- [Source data](#source-data)
- [Session classification](#session-classification)
- [Friction signals (digest sections 2–3)](#friction-signals-digest-sections-23)
- [Correction excerpts (section 4)](#correction-excerpts-section-4)
- [Friction score and deep-dive candidates (section 5)](#friction-score-and-deep-dive-candidates-section-5)
- [Context and cost pressure (section 6)](#context-and-cost-pressure-section-6)
- [Placement context (section 7)](#placement-context-section-7)
- [Judged evidence: review cards (section 8)](#judged-evidence-review-cards-section-8)
- [Known blind spots](#known-blind-spots)

## Source data

- One session = one `<brain>/<conversation-id>/.system_generated/logs/transcript.jsonl` (compact transcript).
  Brains scanned by default: `~/.gemini/jetski/brain`, `~/.gemini/antigravity/brain` and
  `~/.gemini/antigravity-cli/brain` (agy CLI sessions; improve-agy's own headless labelling runs land here and are
  excluded as `tooling` by their first line).
- Step types used: `USER_INPUT` (user turn), `PLANNER_RESPONSE` (agent turn; carries `tool_calls` and
  `input_tokens` / `output_tokens` / `cache_read_tokens`), `GENERIC` from source `MODEL` (tool output),
  `CHECKPOINT` (context compaction), `ERROR_MESSAGE` (API error), `SYSTEM_MESSAGE` (inter-agent messages).
- Tool outputs are paired with tool calls by order within the same agent turn (the queue resets every turn, so a
  background task or a missing output cannot shift later pairings).
- Timezone comes from `The current local time is: …+08:00` in the first user turn; UTC if absent.
- Window: a session is in the window when its **last** step falls inside `--days` / `--since`; a long session that
  started earlier is included whole.

## Session classification

| Kind | Rule | Treatment |
|---|---|---|
| `user` | Has at least one `USER_INPUT` | Analyzed |
| `subagent` | First step is a `SYSTEM_MESSAGE` with `[Message] … sender=<conversation-id>` and no user turn | Excluded from stats, counted under "Subagent tokens"; `--include-subagents` promotes them |
| `empty` | No steps | Dropped |

## Friction signals (digest sections 2–3)

| Signal | Detection | Threshold for an action item | Typical cause → mechanism |
|---|---|---|---|
| User correction | User turn (not the first) scoring ≥ 2: a strong pattern = 3 (`no,` `wrong` `that's not` `I said/asked/meant` `don't` `stop` `undo` `revert` `you didn't/broke/ignored` `still failing` `didn't work`…); medium cues (`instead` `actually` `rather than` `too verbose` `I already` `as I said` `try again`…) add 2 when the turn is short (< 300 chars) or has two cues, else 1. System wake-ups stored as user steps are ignored | > 10 per 100 user messages, or one theme in ≥ 3 sessions | Unpersisted preference → rule or `/learn`; re-explained procedure → skill |
| Rapid re-prompt | User turn < 120 chars sent < 90 s after the previous reply | > 15% of user turns | Underspecified requests → `/plan`, `ask_question` rule |
| Retry | Tool call identical (name + args) to the immediately preceding one within the same user turn; broken down by tool in section 3 | Any `edit_file`/`write_file` retry; > 2 per 100 calls | Stale target text → re-read before editing |
| Polling | `manage_task` status/list, `swarm_wait`, `read_board` | > 5 per session | Manual waiting → `NotificationTimeoutSeconds`, `schedule` with `TimerCondition` |
| Failed command | `run_command` result with `Command exited with code N`, N ≠ 0 (shell results only); grouped by `binary [subcommand]` after unwrapping `cd`, `env`, `VAR=`, `uv run`, `uv tool run` | > 12% of commands; any key failing ≥ 2× in one session | Guessed paths / flags / env → workspace rule with the working invocation |
| Tool error | Tool result step with an `error` field | > 2 per 100 calls | `file does not exist` → list before reading; `target content not found` → smaller edit targets |
| Sandbox / permission block | `error` containing `permission check failed` / `Permission denied for read_file|write_file`, or a **failed shell** result whose output contains `Operation not permitted`; grouped by target command or tool | Same target in ≥ 3 sessions | Data outside the workspace → move it in, or document the one-step unsandboxed pattern; blocked binary → allowed alternative |
| Compaction | `CHECKPOINT` step ("Resuming from a compaction") | ≥ 1 per session on average, or any session with ≥ 3 | Oversized tool outputs → `head`/`tail`/`grep`, scratch files, research subagents, `/compact` at milestones |
| API error | `ERROR_MESSAGE` with an error (`RESOURCE_EXHAUSTED (code 429)`, `UNAVAILABLE`, stream timeouts) | Clustered in specific sessions or during fan-out | Quota pressure → fewer parallel subagents, lighter models for research, retry later |
| Unfinished session | Last step is a user turn, a `RUNNING` tool, an `ask_question`, or a tool error | > 25% of sessions | Abandoned runs → `/goal` for long tasks, `Stop` hook while tests run; cancelled runs → read why |

Rates reported: corrections per 100 user messages, rapid re-prompts % of user messages, failed commands % of
commands, tool errors and retries per 100 calls, sandbox blocks / polls / compactions per session, unfinished
sessions %. All of them are tracked in the snapshot deltas (section 9); snapshots are only written by unfiltered runs.

Every table in section 3 lists up to three example sessions per cause; quote them in the Evidence field and use
`session <id>` only when the cause is still unclear.

## Correction excerpts (section 4)

The regex is deliberately loose. Read every excerpt, cluster by theme, and discard false positives before counting:
a user quoting an error message ("You must enable …"), "don't forget to…" inside a fresh request, or a design opinion
("Plan is not to mimic…") are not corrections of the agent. Score 3+ items are usually real; score 2 items need
judgement.

## Friction score and deep-dive candidates (section 5)

`friction_score = 3·corrections + 2·retries + failed_commands + tool_errors + sandbox_blocks + compactions + rapid_followups`.
It only ranks sessions for deep dives (`session <id>`); never present it as a quality grade. The breakdown column
tells you which signal dominates before you open the session.

## Context and cost pressure (section 6)

| Metric | Reading |
|---|---|
| Prompt cache hit ratio `cache_read / (input + cache_read)` | < 60% suggests churned system context (rules edited mid-session, many fresh conversations for tiny tasks) |
| Compactions per session | Context pressure; the heaviest sessions table shows where |
| Subagent tokens vs main-session tokens | A high share with little merged output suggests over-delegation or oversized swarms |
| Max autonomous streak | Long streaks are fine when the task was well specified; combined with many failed commands they mean the agent kept guessing |

## Placement context (section 7)

Workspaces are inferred from paths in tool args (nearest ancestor with `.git`, `AGENTS.md`, `GEMINI.md`, `go.mod`,
`pyproject.toml`, `package.json`, `Makefile` or `pom.xml`; fallback `~/<a>/<b>`). Use the per-workspace correction
and friction counts to decide between a global rule (`~/.gemini/config/AGENTS.md`) and a workspace `AGENTS.md`.
Slash commands and user-invoked skills show which mechanisms the user already reaches for; a missing `/plan`,
`/learn` or `/automation` despite matching friction is itself an action item.

## Judged evidence: review cards (section 8)

A card is one light-model judgement over an **evidence packet** (request, later user turns with timing, failures
with output tails, repeats, pressure, ending — never the full transcript; `review_cards.py packets`). The model fills
a fixed schema (`scripts/card.schema.json`); the script validates, caches by transcript mtime + size, and counts.
Sessions with ≤ 1 user turn and < 3 active minutes are tagged trivial and never labelled.

| Card field | Counted as | Threshold for an action item |
|---|---|---|
| `blockers[].type` with `cost` | Count and weighted cost (low 1, medium 2, high 3) per type; side = agent / user / environment | Type present in ≥ 2 sessions, or one `high`-cost blocker confirmed by a deterministic metric |
| `standing_instructions[].text` | Clustered by content-word overlap (Jaccard ≥ 0.5, containment counts as a match); support = distinct sessions, mentions = total | **Support ≥ 2** = the user had to say it twice: prime rule candidate. Support 1 with scope `workspace` = candidate for that workspace's `AGENTS.md` only if the deterministic evidence agrees |
| `fix_candidates[]` | Grouped by the blocker type they address; support = sessions proposing a fix for that type; mechanisms tallied | Use the candidate text as the starting point of the item's **Fix**; pick the smallest mechanism that recurs |
| `outcome`, `task.kind`, `user_effort` | Distributions | Context only; `abandoned` sessions are deep-dive candidates |
| `confidence` | Counted; `low` cards are excluded from instruction clustering | A `low` card never carries an item alone |

Blocker taxonomy and default fixes:

| Type | Side | Default mechanism |
|---|---|---|
| `unverified_path` | agent | habit → rule: list or grep before reading/running outside the workspace |
| `repeat_without_change` | agent | rule: after two identical failures change approach or ask |
| `scope_creep` | agent | rule: confirm scope when the request names no files; hook on `git commit` / `git push` |
| `missed_standing_instruction` | agent | rule if absent; hook or skill when the rule exists and was ignored |
| `thin_request` | user | rule: `ask_question` when acceptance criteria are missing; habit: `/plan` for multi-file work |
| `environment_wall` | environment | documented one-step workaround, allowlist, retry policy, fewer parallel workers |
| `context_overflow` | agent | habit: scratch files, `head`/`tail`, research subagents, `/compact` at milestones |
| `output_mismatch` | agent | style rule (global or workspace) |
| `external_fault` | environment | note only |

Reading the two layers together: deterministic counts say *how often*; cards say *why* and *what the user already
asked for*. An item needs both unless the deterministic signal alone is unambiguous (e.g. the same command blocked
by the sandbox in 10 sessions).

## Known blind spots

- Model name, latency and dollar cost are absent from transcripts; reason in tokens only.
- Model-triggered skills and rules are invisible; only user slash invocations are counted.
- Older tool names (`view_file`, `webview_browser`) appear in historical sessions under their own names.
- Tool-output content in `transcript.jsonl` can be truncated (`truncated_fields`); exit codes still parse because
  the header lines survive truncation.
- Commits and pushes are approximated from successful `git commit` / `git push` commands.
- Cards see packets, not transcripts: a blocker that left no failure, user turn or pressure signal is invisible to
  them. Headless labelling sessions are stored in `~/.gemini/antigravity-cli/brain` and excluded as `tooling`; the
  in-agent workflow labellers are excluded the same way.
