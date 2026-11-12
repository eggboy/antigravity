# improve-agy actions — {window, e.g. last 30 days} ({date})

Scope: {N} sessions, {first day} → {last day}, {brains}. Subagent conversations {excluded/included}. Local data
only. Evidence: [digest.md]({path}) · [summary.json]({path}).

## Action items

### 1. {Action: verb + mechanism + location}

| | |
|---|---|
| Evidence | {count} ({rate}) in `{conv}`, `{conv}`, `{conv}` — “{redacted excerpt ≤ 200 chars}” · precision: exact / judged / both |
| Fix | see snippet below |
| Verify | `{metric}` {now} → {target} on the next run |
| Effort | S / M / L |

```markdown
{paste-ready rule / hook JSON / skill outline / exact command}
```

### 2. …

(3–7 items, ordered by payoff. A follow-up on an unresolved previous action comes first.)

## What is working

One or two lines from the cards' `worked_well` and the deterministic metrics (e.g. cache hit ratio, sessions that
delivered without corrections). Keep it factual; it tells the reader what not to change.

## Where the friction sits

| Side | Weighted cost (cards) | Top blocker types | Deterministic signal that agrees |
|---|---|---|---|
| Agent | | | |
| User (thin requests, missing context) | | | |
| Environment (sandbox, Santa, quota, network) | | | |

## Previous actions

| Recorded | Action | Metric | Then → now | Status |
|---|---|---|---|---|
| {date} | {short title} | `{metric}` | {a} → {b} | applied / not applied / improved / no change |

(Omit the section on the first run.)

## Evidence summary

| Signal | Count | Rate | Threshold | Above? |
|---|---|---|---|---|
| User corrections | | | > 10 per 100 user msgs | |
| Failed shell commands | | | > 12% of commands | |
| Tool errors | | | > 2 per 100 calls | |
| Sandbox / permission blocks | | | same target in ≥ 3 sessions | |
| Context compactions | | | ≥ 1 per session | |
| Rapid re-prompts | | | > 15% of user turns | |
| Polling calls | | | > 5 per session | |
| API errors | | | clustered | |

One line each on the top causes behind the signals that are above threshold (from digest section 3).

## Also noticed

Observations without a clear fix or without a verification metric, and the false positives you discarded (so the
next run can tune the heuristics).
