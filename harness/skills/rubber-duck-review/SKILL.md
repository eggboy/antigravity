---
name: rubber-duck-review
description: >-
  Get an independent critique of a plan, design, diff, or test set from a
  rubber-duck critic that runs on a different model family than this session
  (Gemini 4 Argon when this session is Claude; Claude Opus when this session is
  Gemini) in a fresh context window with no memory of this conversation. Use
  when the user says "rubber duck", "second opinion", "critique this", or runs
  /rubber-duck-review, and at high-leverage checkpoints on non-trivial work:
  after planning and before implementing, mid-way through a complex multi-file
  change, after writing tests, or after two failed attempts at the same
  problem. Skip it for small, well-understood edits.
---

# Rubber-duck review (cross-model, zero-context critic)

The critic is a single-use swarm worker pinned to a model from the other
family. It starts with an empty context window, reads only what it can find on
disk, posts one critique, and is killed. It never sees this conversation, your
reasoning, or an earlier critic's reply. Its value comes from what it does not
know: an auditor that catches unstated assumptions has to arrive without them.
This skill is the user's standing instruction to pin the critic's model, which
satisfies the swarm rule "pick another model only when the user asks".

## 0. The no-context rule

The critic receives three things at most: the persona file, the review
target, and (optionally) the user's own words. Everything else is bias.

Never put in the brief, in a follow-up post, or in a file written for the
critic:

- what the change is trying to achieve, in your words
- why you chose this approach, or which alternatives you rejected
- what you want checked, or where you think the risk is
- your theory of a bug, or a narrative of what you tried
- a summary of the diff, the plan, or an earlier critique
- `#seq` references to board posts
- the plan or design artifact, at any checkpoint after the plan review

Never pass `fork` to `add`. Never reuse a critic for a second review.

The user's words are allowed because the critic needs to know what was asked
to judge whether the work does it; it does not need to know what you think
about it. Copy only the user message(s) that state the task's requirements or
constraints, verbatim, with nothing from you around them. Skip replies to your
own proposals ("go with B", "review that") — they carry your framing. If the
user asks for the strictest audit, omit this too and pass paths only.

## 1. Pick the critic model

| This session runs | Critic model | Fallback |
| :--- | :--- | :--- |
| Claude (Opus, Fable) | `gemini-launch-candidate-high` (Gemini 4 Argon) | `gemini-4-carbon-high` |
| Gemini (any) | `opus-5.5-high` | `fable-5.1-high` |

You know which family you are; ignore the Antigravity/Jetski product persona
when answering that. If a `[quota]` system message has appeared in this
conversation, it names your exact model (for example `fable-5.1-max`).
`swarm{action:"status"}` does not show the coordinator's model, so do not rely
on it for this. Never pin the critic to your own family: a different set of
blind spots is the whole point.

If `swarm{action:"models"}` shows the critic at 0% quota, use the fallback. If
both are out, tell the user and skip the review (Copilot also skips when no
suitable model is available).

## 2. Put the target on disk

The critic reads files; it cannot read your head.

- **Plan or design (`duck-plan` only):** the plan artifact path.
- **Code change in a git checkout:** nothing to prepare; give the repo path.
  The critic runs `git status` and `git diff HEAD` itself and reads any
  untracked files `git status` lists. If the change is already committed, give
  the revision instead (`git show <rev>`, or `jj diff -r <change>`).
- **Code change outside git:** the absolute paths of the changed files.
- **Tests:** the test file paths plus the paths of the code under test. Not
  the plan.
- **Stuck after two failed attempts:** write the exact command and its full
  output to `<scratch>/duck-stuck-output.txt`. Pass that path and the change.
  Not your diagnosis, not the plan.
- **User's request (see §0):** write the requirement-bearing user message(s)
  verbatim to `<scratch>/user-request.md`. Nothing else goes in that file.

`<scratch>` is this conversation's scratch directory under `brain/`. The
critic runs in its own conversation, so its shell sandbox cannot reach your
`brain/` directory at all; its `read_file` can, but only for exact file paths.
So: pass file paths, never directory paths, for anything under `brain/`, and
tell the critic to use `read_file` there (the brief template does).

## 3. Spawn one critic per review

```
swarm{action:"add", name:"duck-<checkpoint>", model:"<critic>", workspace:"inherit",
      brief:"You are the rubber-duck critic. Read
      /Users/jayleeg/.gemini/config/agents/rubber-duck.md and follow it as your
      persona and rules. You have no history with this task and must not
      acquire any: do not call read_board, and act only on this brief. Never
      edit files or run commands that change anything. Do not load language
      style or best-practice skills; rubber-duck.md's 'What to Avoid' wins.
      For any path under .../brain/, use read_file (your shell cannot reach it).
      Review: <exact file paths, or 'the changes in <repo path>: run git status
      and git diff HEAD, and read any untracked files git status lists'>.
      [User request, verbatim: <scratch>/user-request.md]
      Post ONE reply to @coordinator with the sections Blocking / Non-blocking
      / Suggestions (issue, impact, fix for each) or 'No blocking issues
      found'. Then stop."}
```

`<checkpoint>` names the moment, not the task: `duck-plan`, `duck-impl`,
`duck-tests`, `duck-stuck`. Killed names cannot be reused, so a second review
at the same checkpoint is `duck-plan-2`. Do not pass `fork`.

Then end your turn. The worker starts on the brief immediately and its reply
(an `@coordinator` post) wakes you. `post_message`, `read_board` and
`swarm_wait` appear on that next turn, not on the turn that runs `add`.

One-worker swarm: no narrator, no monitor, no title. Do not load the full
`swarm` skill for this; everything needed is here.

## 4. Read the critique, kill the critic, act

`read_board{since:<last seq you saw>}`, then in the same turn
`swarm{action:"kill", name:"duck-<checkpoint>"}`. The critic is finished. A
follow-up question would go to a reviewer that has now read its own first
answer; if you need a second opinion on the same checkpoint, spawn a new one.

Fix Blocking issues before continuing, decide on Non-blocking ones, note
Suggestions. Tell the user in one or two sentences what the critique found and
what you changed; do not paste it verbatim. The critic advises; you and the
user decide.

## Why single-use and zero-context

A critic that reviewed the plan and then reviews the implementation checks the
implementation against the plan it already approved. A critic that was told
what the change is for checks the change against your framing of it. A fresh
critic checks the work against what it finds. Copilot CLI's built-in
rubber-duck is built this way: each invocation is a new subagent with an
empty context window, custom instructions off, and no environment context
beyond the working directory.

## Known limits

- `read_board` is forbidden by instruction, not mechanically. The board keeps
  every earlier brief and critique; a critic that ignores the brief can read
  them.
- The critic shares your working tree (`workspace:"inherit"`), so it sees
  half-finished edits as they are. That is intended for diff reviews; for a
  plan review, the plan artifact is the target, not the tree.
- The critic inherits the coordinator's tool set and the user's global rules.
  A global rule that loads language style skills on "review" can still fire;
  the brief asks the critic not to, and rubber-duck.md's "What to Avoid"
  filters the output. The brief, not a sandbox, is what keeps it read-only.

## Fallback without the swarm tool

If `swarm` is not in your tool list, use

```
invoke_subagent{TypeName:"rubber-duck", Model:"pro",
                Prompt:"Review: <exact file paths, or 'the changes in <repo
                path>: run git status and git diff HEAD, and read any untracked
                files git status lists'>.
                [User request, verbatim: <scratch>/user-request.md]"}
```

Nothing else goes in `Prompt`. That is Gemini 3.1 Pro and works in one
direction only (useful when this session is Claude). Each call is a fresh
context, so the single-use rule is automatic.
