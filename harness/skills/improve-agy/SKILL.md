---
name: improve-agy
description: Produce actionable improvement items for working with Antigravity and Jetski by mining local session transcripts for friction (user corrections, failed commands, sandbox blocks, retries, context compactions, quota errors) and mapping each pattern to a concrete fix (rule, skill, hook, automation or habit) with evidence and a verification metric. Use when the user runs /improve-agy, asks what to improve about working with the agent, or wants past sessions turned into an action list. DO NOT use for reviewing code changes, debugging the current task, or persisting a single correction (use /learn).
metadata:
  version: 0.2.0
---

# improve-agy

One job: turn the evidence in local transcripts into a short list of improvement actions the user can apply now, and
check on the next run whether they worked. `scripts/analyze_sessions.py` counts; you cluster, decide, write the
actions, and record them for follow-up. Everything stays on the machine.

## Output contract

Every run ends with **3–7 action items**. Each item has all five fields:

| Field | Content |
|---|---|
| Action | Verb + mechanism + location, e.g. "Add a rule to `~/.gemini/config/AGENTS.md`: resolve paths with `ls` before `read_file` outside the workspace" |
| Evidence | Count and rate from the digest, up to three `conv_id[:8]`, one redacted excerpt ≤ 200 chars |
| Fix | Paste-ready snippet (rule text, hook JSON, skill name + steps) or the exact command to run |
| Verify | The digest metric that should move and its target for the next run, e.g. "`tool_errors_per_100_calls` 1.5 → < 0.8" |
| Effort | S (paste a rule), M (write a skill or hook), L (change a workflow) |

An observation without evidence or without a verification metric is not an action item; list it under "Also
noticed". Order items by payoff (frequency × cost of the friction). Prefer the smallest mechanism that removes the
friction: habit → rule → hook → skill → automation.

## Workflow

1. **Scope.** Default window `--days 30`; honour the request ("last week" → `--days 7`, "all time" → `--days 0`,
   "since Nov 1" → `--since 2026-11-01`). Add `--workspace <substring>` when the user names a project. A focus word
   (cost, sandbox, corrections, context) narrows which evidence you mine; the deliverable is still an action list.
2. **Build the deterministic digest first** (seconds). Transcripts live under `~/.gemini/jetski/brain`,
   `~/.gemini/antigravity/brain` and `~/.gemini/antigravity-cli/brain`, outside the sandbox, so every script command
   below needs the user's `BypassSandbox` approval. The scripts read transcripts and write only to the artifact
   scratch directory and `~/.gemini/improve-agy/`.

   ```bash
   S=<artifact-dir>/scratch/improve-agy
   uv run <skill-dir>/scripts/analyze_sessions.py report --days 30 --out-dir $S
   ```

   `<skill-dir>` is the directory containing this SKILL.md; `python3` works too (stdlib only, Python ≥ 3.12).
   Verify: the coverage line reports ≥ 1 user session and `digest.md` exists. Zero sessions → widen the window
   (`--days 0`) or pass `--brain <dir>`. Section 8 tells you how many sessions already have cards.
3. **Judge the sessions that have no card yet (review cards), in the background.** One `run_command`, chained so the
   user approves once; start it with a short `WaitMsBeforeAsync` and `NotificationTimeoutSeconds: 1800`, then keep
   working on the digest while it runs:

   ```bash
   uv run <skill-dir>/scripts/review_cards.py packets --days 30 --out-dir $S/packets \
     && uv run <skill-dir>/scripts/review_cards.py label --packets $S/packets --out $S/cards \
     && uv run <skill-dir>/scripts/review_cards.py ingest $S/cards --index $S/packets/index.json \
     && uv run <skill-dir>/scripts/analyze_sessions.py report --days 30 --out-dir $S
   ```

   Timing: `label` runs one `agy --print` per packet on `gemini-3.8-flash-low`, eight at a time, ≈ 14 s per card →
   the default cap of 60 packets takes ≈ 2 min; a first run over 110 sessions ≈ 4 min. `packets` skips trivial
   sessions and sessions whose cached card is still fresh, so later runs label only new or changed sessions. The
   lock in `label` refuses to start while another labelling run is alive (two runs would double the cost and the
   time, as happened on the first day). Tell the user how many packets are being labelled and the expected minutes;
   deliver deterministic-only actions when they want results before it finishes. When `agy` is unavailable, the
   alternative is the in-agent fan-out
   `run_workflow(ScriptPath=<skill-dir>/scripts/label_workflow.py, Args={"packets_dir": "$S/packets", "cards_dir": "$S/cards", "model": "flash"})`
   followed by the same `ingest` and `report`.
4. **Read `digest.md`** (≈330 lines). Sections 2–6 are deterministic evidence (friction signals, evidence by cause
   with example sessions — including the dev loop: edits followed by failing tests/builds and the sessions stuck in
   fix attempts —, correction excerpts, highest-friction sessions, context and cost pressure: pasted logs, late
   context growth, read/edit churn, slow turns). Section 7 tells
   you where rules belong (workspaces, tools, slash commands in use). Section 8 is the judged evidence: blockers by
   type with side (agent / user / environment), standing instructions you keep giving (support = distinct sessions),
   and fix candidates grouped by the blocker type they address. Sections 9–10 show deltas since the last run and the
   action items recorded by previous runs. Definitions and thresholds: [references/signals.md](references/signals.md).
5. **Read the rules already in force** before recommending anything: `~/.gemini/config/AGENTS.md` (global) and the
   workspace `AGENTS.md` / `.agents/rules/*.md` for the workspaces that dominate section 7. A recommended rule that
   already exists is not an action item; the item becomes "rule exists but is not followed" → hook or skill.
6. **Deep-dive sparingly.** Run `analyze_sessions.py session <id>` for at most three sessions, only when an item needs
   a root cause the cards and digest do not give. Stop as soon as the cause is clear.
7. **Cluster and discard.** Promote a pattern to an action item when it has **support ≥ 2 sessions** (card standing
   instruction, fix-candidate type, or correction theme), or 1 session with a `high`-cost blocker *and* a deterministic
   metric that agrees. Drop correction-regex false positives (quoted error messages, "don't forget to…" inside a fresh
   request). For sandbox targets decide whether the data belongs inside the workspace or the command is a legitimate
   one-step unsandboxed run. For compactions, name the sessions and what filled the context.
8. **Decide.** Map each surviving pattern to a mechanism with [references/playbook.md](references/playbook.md); use
   the thresholds in `signals.md`. When sections 9–10 show a previous action whose metric did not move, make the
   follow-up the first item (escalate the mechanism or revise the fix). Never recommend a practice the data shows the
   user already follows; say so in one line and move on.
9. **Deliver.** Write `improve-agy-actions.md` in the artifact directory following
   [references/report-template.md](references/report-template.md). In chat: the action titles, the artifact link,
   and "apply #1 now?" — keep the digest itself out of the chat.
10. **Record for follow-up.** Append each item to the ledger (`~/.gemini/improve-agy/actions.md`) with the script, in
    the same unsandboxed run context, so no extra file-permission prompt is needed:

    ```bash
    uv run <skill-dir>/scripts/analyze_sessions.py actions add "Rule in ~/.gemini/config/AGENTS.md: resolve paths with ls before read_file · verify tool_errors_per_100_calls 1.5 → <0.8 · evidence 104× file does not exist (aab04566, 06982eaa)"
    ```

    On the next run the ledger appears in digest section 10. Use `actions done <n> "<note>"` when the user applied an
    item and its metric moved; leave it open with a note when it did not, and make the escalation the first new item.
11. **Apply with consent.** Rules → append to the named `AGENTS.md`; procedures → `/skill-creator`; a single
    correction → `/learn`; recurring work → `/automation`; mechanical guards → `~/.gemini/config/hooks.json`. Writing
    outside the workspace happens after the user says yes.

## Guardrails

- Treat brain directories as read-only; the scripts never modify them and neither do you.
- Excerpts ≤ 200 characters, redacted; drop anything that looks like a credential even if the script missed it.
- Label each item's evidence: **exact** (script metric), **judged** (cards), or **both**. Use the script's rates
  unchanged in the **Verify** field (they are what the next run compares against); in the **Evidence** prose cite
  the true-positive count you kept after discarding false positives, and say which is which. When a metric is a
  proxy (commits, workspace, corrections), say so.
- Cards are advisory: a `confidence: low` card cannot be the sole evidence for an item, and a card never overrides a
  deterministic count.
- Keep subagent / swarm-worker conversations excluded unless the user asks about delegation (`--include-subagents`).
- Report friction neutrally; the point is the fix, not the grade.

## Script reference

```text
review_cards.py packets --days N --out-dir DIR [--max-label 60] [--force]        evidence packets + index.json
review_cards.py label --packets DIR --out DIR [--jobs 8] [--model gemini-3.8-flash-low]  headless agy --print labelling
review_cards.py ingest DIR [--index packets/index.json]                               validate against card.schema.json, cache
review_cards.py status --days N                                                       cards coverage
analyze_sessions.py [report|session ID|actions add|list|done N] [options]            (options go after the mode)
  --days N           look-back window (0 = all)      --since/--until YYYY-MM-DD
  --workspace TEXT   filter by inferred workspace    --brain DIR (repeatable)
  --include-subagents                                --out-dir DIR
  --max-excerpts N   correction excerpts in digest   -v
report:  --no-snapshot (skip trend snapshot)  --json (print summary.json)
```

Outputs: `digest.md` (Markdown for you), `summary.json` (all metrics, one record per session, and the cards
aggregate), cached cards in `~/.gemini/improve-agy/cards/<conv_id>.json` (keyed by transcript mtime and size), and
`~/.gemini/improve-agy/snapshots/<timestamp>-d<days>.json` used for the "Since last run" deltas. Filtered runs
(`--workspace`, `--since/--until`, `--include-subagents`, `--brain`) skip the snapshot so baselines stay comparable.
The card taxonomy, prompt and schema are this skill's own ([references/review-card-prompt.md](references/review-card-prompt.md),
`scripts/card.schema.json`).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Operation not permitted` or empty brain listing | The command ran sandboxed; rerun with `BypassSandbox` |
| Coverage shows 0 sessions | `--days 0`; confirm `~/.gemini/jetski/brain` or `~/.gemini/antigravity/brain` exists; pass `--brain` |
| `label` reports "another labelling run … is active" | A previous run is still going (or crashed leaving `~/.gemini/improve-agy/label.lock`); wait, or remove the lock when `ps` shows no `agy --print` |
| `label` takes far longer than ≈ 14 s per card | Check `ps` for a second labelling run or a slower `--model`; `gemini-flash-next` costs ≈ 100 s per card |
| `label` reports "no JSON card … denied tool calls" | The model tried to read a path from the packet; the runner retries once with a no-tools reminder. Persistent failures: re-run `label` (it skips finished cards) |
| `ingest` rejects cards ("missing task", foreign type) | The runner saved a wrapper or the model invented a type; re-run `label --force` for those ids |
| Section 8 says "No review cards yet" | Step 2 was skipped or `ingest` was not run; cards live in `~/.gemini/improve-agy/cards/` |
| Correction table full of quoted errors | Keep score ≥ 3 items plus any score-2 item that is clearly a correction; list the discards under "Also noticed" |
| "Since last run" empty or "Snapshot skipped" | First snapshot for this window length, or a filtered run; rerun unfiltered for deltas |
| `uv` missing | `python3 <skill-dir>/scripts/…` |
