#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Review cards: the judgement layer of improve-agy.

The script never calls a model. It prepares one evidence packet per session, validates and caches the cards a model
returns, and turns cached cards into recurrence counts that ``analyze_sessions.py report`` merges into the digest.

Modes
-----
packets  Write ``<out-dir>/<conv_id>.md`` for every session in the window that has no fresh card, plus ``index.json``.
ingest   Validate ``<dir>/*.json`` cards against ``card.schema.json`` and store them in ``~/.gemini/improve-agy/cards``.
label    Headless labelling of a packets directory through ``agy --print --json-schema`` (for cron runs).
status   Coverage of cached cards for the window.

Examples
--------
    uv run review_cards.py packets --days 30 --out-dir /tmp/improve-agy/packets
    uv run review_cards.py label --packets /tmp/improve-agy/packets --out /tmp/improve-agy/cards --jobs 6
    uv run review_cards.py ingest /tmp/improve-agy/cards
    uv run review_cards.py status --days 30
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import shutil
import subprocess
import sys
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import analyze_sessions as core

logger = logging.getLogger("improve_agy.cards")

SCRIPT_DIR = Path(__file__).resolve().parent
SCHEMA_PATH = SCRIPT_DIR / "card.schema.json"
PROMPT_PATH = SCRIPT_DIR.parent / "references" / "review-card-prompt.md"
CARDS_DIR = core.STATE_DIR / "cards"
READ_CHURN = core.READ_CHURN_MIN
EDIT_CHURN = core.EDIT_CHURN_MIN

TRIVIAL_MAX_USER_TURNS = 1  # sessions with <= 1 user turn ...
TRIVIAL_MAX_ACTIVE_SECONDS = 180  # ... and under 3 active minutes are not labelled
PACKET_LIMITS = {"request": 600, "turn": 400, "turns": 25, "failures": 12, "output": 200, "reply": 300}
BLOCKER_SIDE = {
    "unverified_path": "agent",
    "repeat_without_change": "agent",
    "scope_creep": "agent",
    "missed_standing_instruction": "agent",
    "thin_request": "user",
    "environment_wall": "environment",
    "context_overflow": "agent",
    "output_mismatch": "agent",
    "external_fault": "environment",
}
COST_WEIGHT = {"low": 1, "medium": 2, "high": 3}
STOPWORDS = frozenset(
    [
        "a",
        "an",
        "the",
        "and",
        "or",
        "of",
        "to",
        "in",
        "on",
        "for",
        "with",
        "without",
        "from",
        "by",
        "at",
        "as",
        "is",
        "are",
        "be",
        "been",
        "do",
        "does",
        "did",
        "not",
        "no",
        "never",
        "always",
        "please",
        "this",
        "that",
        "these",
        "those",
        "it",
        "its",
        "you",
        "your",
        "we",
        "our",
        "i",
        "my",
        "me",
        "use",
        "using",
        "instead",
        "when",
        "if",
        "then",
        "than",
        "into",
        "onto",
    ]
)
CLUSTER_THRESHOLD = 0.5


# --------------------------------------------------------------------------------------------------------------------
# Packets
# --------------------------------------------------------------------------------------------------------------------
def source_stamp(path: Path) -> dict[str, int]:
    """Identity of a transcript file for cache freshness: mtime (ns) and size."""
    stat = path.stat()
    return {"mtime_ns": stat.st_mtime_ns, "size": stat.st_size}


def is_trivial(session: core.Session) -> bool:
    """Chat-like sessions that are not worth a model call (they still count in deterministic metrics)."""
    return len(session.user_messages) <= TRIVIAL_MAX_USER_TURNS and session.active_seconds < TRIVIAL_MAX_ACTIVE_SECONDS


def cached_card(conv_id: str) -> dict[str, Any] | None:
    path = CARDS_DIR / f"{conv_id}.json"
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def card_is_fresh(session: core.Session) -> bool:
    entry = cached_card(session.conv_id)
    return bool(entry) and entry.get("source") == source_stamp(session.path)


def render_packet(s: core.Session) -> str:
    """Compact, redacted evidence packet for one session (never the full transcript)."""
    lim = PACKET_LIMITS
    tz = s.tz
    started = s.started.astimezone(tz).strftime("%Y-%m-%d %H:%M") if s.started else "?"
    out = [
        f"# Session {s.short_id} · {started} · {s.workspace()} · {s.active_seconds / 60:.0f} min active · "
        f"{len(s.user_messages)} user turns / {len(s.tool_calls)} tool calls",
        f"Brain: {s.brain} · ending flag: {s.outcome} · friction score: {s.friction_score}",
        "",
    ]
    first = s.user_messages[0] if s.user_messages else None
    out.append(f"## Request (step {first.step if first else '-'})")
    out.append(core._redact(core._one_line(first.text, lim["request"])) if first else "(no user turn)")
    out.append("")
    out.append("## User turns")
    later = s.user_messages[1:]
    gaps: dict[int, str] = {}
    # gap since the agent last did something before this turn (tool call or result timestamps)
    agent_ts = sorted({c.ts for c in s.tool_calls} | {r.ts for r in s.tool_results})
    for m in later:
        prev = max((t for t in agent_ts if t < m.ts), default=None)
        gaps[m.step] = f"+{int((m.ts - prev).total_seconds())}s after agent activity" if prev else "first turn"
    for m in later[: lim["turns"]]:
        flag = " [correction?]" if m.correction_score >= 2 else ""
        out.append(f'- step {m.step} ({gaps[m.step]}){flag}: "{core._redact(core._one_line(m.text, lim["turn"]))}"')
    if len(later) > lim["turns"]:
        out.append(f"- … {len(later) - lim['turns']} more user turns omitted")
    if not later:
        out.append("- (none after the request)")
    out.append("")
    failures = {r.step: r for r in s.failed_commands + s.tool_errors + s.sandbox_blocked}
    out.append(f"## Failures ({len(failures)} total, showing up to {lim['failures']})")
    for step in sorted(failures)[: lim["failures"]]:
        r = failures[step]
        what = core._redact(core._one_line(r.target, 160))
        detail = f"exit {r.exit_code}" if r.exit_code is not None else ""
        detail += f" error: {core._redact(core._one_line(r.error, 120))}" if r.error else ""
        detail += " [sandbox]" if r.sandbox_block else ""
        line = f"- step {step} · `{what}` · {detail.strip() or '-'}"
        if r.excerpt:
            line += f' · output: "{core._one_line(r.excerpt, lim["output"])}"'
        out.append(line)
    if not failures:
        out.append("- (none)")
    out.append("")
    out.append("## Repeats")
    repeats = [f"`{k}` failed {v}×" for k, v in s.repeated_failures.most_common(8)]
    out.append("- " + ("; ".join(repeats) if repeats else "no command failed twice"))
    retry_desc = ", ".join(f"{k} ×{v}" for k, v in s.retry_tools.most_common()) or "none"
    out.append(f"- identical consecutive calls: {s.retries} ({retry_desc})")
    out.append("")
    out.append("## Pressure")
    dl = s.dev_loop()
    pr = s.pressure()
    out.append(
        f"compactions {s.compactions} · API errors {len(s.api_errors)} · sandbox blocks {len(s.sandbox_blocked)} · "
        f"longest autonomous streak {s.max_streak} tool calls · polling calls {s.polls} · "
        f"tokens in/out {s.input_tokens:,}/{s.output_tokens:,}"
    )
    out.append(
        f"dev loop: {dl['edits']} edits, {dl['checks_run']} verification runs ({dl['checks_failed']} failed), "
        f"{dl['edit_fail_cycles']} edit→fail cycles, longest run of failing fixes {dl['max_fix_attempts']}"
        f"{', ended with a red check' if dl['ended_red'] else ''}"
    )
    out.append(
        f"context: pasted-log user turns {pr['large_user_messages']} · peak context "
        f"{pr['peak_context_tokens']:,} tokens"
        f" · late growth ×{pr['late_growth_ratio'] if pr['late_growth_ratio'] is not None else '-'}"
        f" · files read ≥{READ_CHURN}× {len(pr['read_churn_files'])} · files edited ≥{EDIT_CHURN}× "
        f"{len(pr['edit_churn_files'])} · turn latency median {pr['median_turn_seconds']}s "
        f"p90 {pr['p90_turn_seconds']}s"
    )
    out.append("")
    out.append("## Ending")
    out.append(f"outcome flag: {s.outcome}")
    out.append(f'final reply: "{core._redact(core._one_line(s.final_reply, lim["reply"])) or "(none)"}"')
    out.append("")
    return "\n".join(out)


def write_packets(args: argparse.Namespace) -> str:
    """Write packets for sessions that need a (new or refreshed) card; highest friction first; capped."""
    sessions = [s for s in core.load_sessions(args) if s.kind == "user"]
    out_dir: Path = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    skipped = Counter()
    candidates: list[core.Session] = []
    for s in sessions:
        if is_trivial(s):
            skipped["trivial"] += 1
        elif card_is_fresh(s) and not args.force:
            skipped["cached"] += 1
        else:
            candidates.append(s)
    candidates.sort(key=lambda s: -s.friction_score)
    chosen, capped = candidates[: args.max_label], candidates[args.max_label :]
    skipped["capped"] = len(capped)
    index = {
        "generated_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "window_days": args.days,
        "packets": [],
        "skipped": dict(skipped),
        "eligible": len(sessions) - skipped["trivial"],
    }
    for s in chosen:
        file = f"{s.conv_id}.md"
        (out_dir / file).write_text(render_packet(s), encoding="utf-8")
        index["packets"].append(
            {
                "conv_id": s.conv_id,
                "file": file,
                "friction_score": s.friction_score,
                "workspace": s.workspace(),
                "source": source_stamp(s.path),
            }
        )
    (out_dir / "index.json").write_text(json.dumps(index) + "\n", encoding="utf-8")  # one line: read_file-safe
    # The in-agent workflow reads only from this directory, so give it the prompt and schema too.
    shutil.copyfile(PROMPT_PATH, out_dir / "prompt.md")
    shutil.copyfile(SCHEMA_PATH, out_dir / "card.schema.json")
    return (
        f"{len(chosen)} packets written to {out_dir} "
        f"(eligible {index['eligible']}, cached {skipped['cached']}, trivial {skipped['trivial']}, "
        f"capped {skipped['capped']}; raise --max-label to include capped sessions)\n"
    )


# --------------------------------------------------------------------------------------------------------------------
# Validation and ingest
# --------------------------------------------------------------------------------------------------------------------
def load_schema() -> dict[str, Any]:
    return json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))


def validate(value: Any, schema: dict[str, Any], path: str = "$") -> list[str]:
    """Validate against the subset of JSON Schema used by card.schema.json; return a list of problems."""
    problems: list[str] = []
    expected = schema.get("type")
    checks = {"object": dict, "array": list, "string": str, "integer": int, "boolean": bool}
    if expected and not isinstance(value, checks[expected]) or (expected == "integer" and isinstance(value, bool)):
        return [f"{path}: expected {expected}, got {type(value).__name__}"]
    if "enum" in schema and value not in schema["enum"]:
        problems.append(f"{path}: {value!r} not in {schema['enum']}")
    if isinstance(value, str):
        if len(value) > schema.get("maxLength", 10**9):
            problems.append(f"{path}: longer than {schema['maxLength']} chars")
        if len(value) < schema.get("minLength", 0):
            problems.append(f"{path}: shorter than {schema['minLength']} chars")
    if isinstance(value, int) and not isinstance(value, bool) and value < schema.get("minimum", -(10**9)):
        problems.append(f"{path}: below minimum {schema['minimum']}")
    if isinstance(value, list):
        if len(value) > schema.get("maxItems", 10**9):
            problems.append(f"{path}: more than {schema['maxItems']} items")
        for i, item in enumerate(value):
            problems += validate(item, schema.get("items", {}), f"{path}[{i}]")
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                problems.append(f"{path}: missing {key}")
        if schema.get("additionalProperties") is False:
            problems += [f"{path}: unexpected key {k}" for k in value if k not in props]
        for key, sub in props.items():
            if key in value:
                problems += validate(value[key], sub, f"{path}.{key}")
    return problems


def find_transcript(conv_id: str, brains: list[Path]) -> Path | None:
    for brain in brains:
        candidate = brain / conv_id / core.TRANSCRIPT_REL
        if candidate.is_file():
            return candidate
    return None


def ingest(args: argparse.Namespace) -> str:
    """Validate card files and store them in the cache with their source stamp."""
    schema = load_schema()
    CARDS_DIR.mkdir(parents=True, exist_ok=True)
    index_sources: dict[str, dict[str, int]] = {}
    if args.index and args.index.is_file():
        for p in json.loads(args.index.read_text(encoding="utf-8")).get("packets", []):
            index_sources[p["conv_id"]] = p["source"]
    brains = args.brain or [b for b in core.DEFAULT_BRAINS if b.is_dir()]
    stored, rejected = 0, []
    for file in sorted(args.cards_dir.glob("*.json")):
        try:
            raw = json.loads(file.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            rejected.append(f"{file.name}: invalid JSON ({exc})")
            continue
        card = raw.get("card", raw) if isinstance(raw, dict) else raw
        conv_id = file.stem if len(file.stem) >= 8 else card.get("conv_id", "")
        if isinstance(card, dict):
            card["conv_id"] = conv_id  # the file name is authoritative
        problems = validate(card, schema)
        if problems:
            rejected.append(f"{file.name}: " + "; ".join(problems[:4]))
            continue
        source = (raw.get("source") if isinstance(raw, dict) else None) or index_sources.get(conv_id)
        if not source:
            transcript = find_transcript(conv_id, brains)
            source = source_stamp(transcript) if transcript else {}
        entry = {
            "card": card,
            "source": source,
            "labelled_at": datetime.now(UTC).isoformat(timespec="seconds"),
            "model": (raw.get("model") if isinstance(raw, dict) else None) or args.model,
        }
        (CARDS_DIR / f"{conv_id}.json").write_text(json.dumps(entry, indent=1) + "\n", encoding="utf-8")
        stored += 1
    lines = [f"stored {stored} card(s) in {core._tilde(CARDS_DIR)}; rejected {len(rejected)}"]
    lines += [f"  - {r}" for r in rejected[:20]]
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------------------------------------------------
# Headless labelling (agy --print)
# --------------------------------------------------------------------------------------------------------------------
def _looks_like_card(value: Any) -> bool:
    return isinstance(value, dict) and "blockers" in value and "outcome" in value


def _find_card(value: Any, depth: int = 0) -> dict[str, Any] | None:
    """Depth-first search for the card inside whatever wrapper the runner printed (never the wrapper itself)."""
    if depth > 4:
        return None
    if _looks_like_card(value):
        return value
    if isinstance(value, dict):
        for inner in value.values():
            found = _find_card(inner, depth + 1)
            if found:
                return found
    elif isinstance(value, str) and "{" in value:
        try:
            return _find_card(json.loads(value), depth + 1)
        except json.JSONDecodeError:
            match = re.search(r"\{[\s\S]*\}", value)
            if match and match.group(0) != value:
                return _find_card(match.group(0), depth + 1)
    return None


def _extract_json_object(text: str) -> dict[str, Any] | None:
    """Find the card inside agy's output envelope (``structured_output`` or ``response``) or raw JSON text."""
    return _find_card(text)


def _denied_actions(stdout: str) -> str:
    try:
        return ", ".join(d.get("action", "?") for d in json.loads(stdout).get("denied_actions", []))
    except (json.JSONDecodeError, AttributeError):
        return ""


def label_one(packet: dict[str, Any], packets_dir: Path, out_dir: Path, prompt: str, args: argparse.Namespace) -> str:
    conv_id = packet["conv_id"]
    text = (packets_dir / packet["file"]).read_text(encoding="utf-8")
    full_prompt = f"{core.TOOLING_MARKER} {conv_id}\n\n{prompt}\n\nPACKET:\n{text}"
    retry_suffix = "\n\nYour previous attempt produced no JSON. Do not call tools. Reply with the JSON object only."
    last = ""
    for attempt in (1, 2):
        cmd = [
            args.agy, "--print", full_prompt + (retry_suffix if attempt == 2 else ""), "--output-format", "json",
            "--json-schema", str(SCHEMA_PATH), "--model", args.model, "--disable-slash-commands",
        ]  # fmt: skip
        if args.effort:
            cmd += ["--effort", args.effort]  # not accepted by every model, so opt-in
        if args.print_timeout:
            cmd += ["--print-timeout", args.print_timeout]
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False, timeout=args.timeout)
        if proc.returncode != 0:
            last = f"agy exited {proc.returncode}: {core._one_line(proc.stderr or proc.stdout, 200)}"
            continue
        card = _extract_json_object(proc.stdout)
        if card:
            card["conv_id"] = conv_id
            payload = {"card": card, "model": args.model, "source": packet.get("source")}
            (out_dir / f"{conv_id}.json").write_text(json.dumps(payload, indent=1) + "\n", encoding="utf-8")
            return f"{conv_id[:8]}: ok" + (" (retry)" if attempt == 2 else "")
        denied = _denied_actions(proc.stdout)
        last = "no JSON card in agy output" + (f" (denied tool calls: {denied})" if denied else "")
    return f"{conv_id[:8]}: {last}"


def card_file_is_current(path: Path, source: dict[str, int] | None) -> bool:
    """A staged card file counts as done only when it was produced from the same transcript state."""
    if not path.is_file():
        return False
    try:
        return json.loads(path.read_text(encoding="utf-8")).get("source") == source
    except (OSError, json.JSONDecodeError, AttributeError):
        return False


LOCK_FILE = core.STATE_DIR / "label.lock"


def _acquire_lock() -> str | None:
    """Refuse to start a second labelling run while another is alive; return a message when blocked."""
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    if LOCK_FILE.is_file():
        try:
            other = int(LOCK_FILE.read_text().strip() or 0)
            os.kill(other, 0)  # raises when the process is gone
            return f"another labelling run (pid {other}) is active; wait for it or remove {core._tilde(LOCK_FILE)}\n"
        except (ValueError, ProcessLookupError, PermissionError):
            pass  # stale lock
    LOCK_FILE.write_text(str(os.getpid()), encoding="utf-8")
    return None


def label(args: argparse.Namespace) -> str:
    """Label every packet in the index with ``agy --print`` (parallel), writing cards to ``--out``."""
    if shutil.which(args.agy) is None:
        return f"{args.agy} not found on PATH; label inside the agent with the run_workflow fan-out instead\n"
    blocked = _acquire_lock()
    if blocked:
        return blocked
    try:
        return _label_all(args)
    finally:
        LOCK_FILE.unlink(missing_ok=True)


def _label_all(args: argparse.Namespace) -> str:
    index = json.loads((args.packets / "index.json").read_text(encoding="utf-8"))
    prompt = PROMPT_PATH.read_text(encoding="utf-8")
    args.out.mkdir(parents=True, exist_ok=True)
    todo = [
        p
        for p in index["packets"]
        if args.force or not card_file_is_current(args.out / f"{p['conv_id']}.json", p.get("source"))
    ]
    lines = [f"labelling {len(todo)} packet(s) with {args.agy} --print, {args.jobs} in parallel, model {args.model}"]
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(label_one, p, args.packets, args.out, prompt, args) for p in todo]
        for future in as_completed(futures):
            try:
                lines.append(future.result())
            except (subprocess.TimeoutExpired, OSError) as exc:
                lines.append(f"labelling failed: {exc}")
    lines.append(f"done; now run: review_cards.py ingest {args.out} --index {args.packets / 'index.json'}")
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------------------------------------------------
# Recurrence engine
# --------------------------------------------------------------------------------------------------------------------
def content_tokens(text: str) -> frozenset[str]:
    words = re.findall(r"[a-z0-9][a-z0-9_./-]*", text.lower())
    return frozenset(w for w in words if w not in STOPWORDS and len(w) > 1)


def similarity(a: frozenset[str], b: frozenset[str]) -> float:
    if not a or not b:
        return 0.0
    inter = len(a & b)
    if min(len(a), len(b)) >= 3 and (a <= b or b <= a):
        return 1.0  # one phrasing contains the other
    return inter / len(a | b)


class Cluster:
    """Group of near-identical texts across sessions (single linkage against members, never against a union)."""

    def __init__(self, text: str, conv_id: str, meta: dict[str, Any]) -> None:
        self.label = text
        self.member_tokens: list[frozenset[str]] = [content_tokens(text)]
        self.sessions: set[str] = {conv_id}
        self.count = 1
        self.meta: list[dict[str, Any]] = [meta]

    def add(self, text: str, conv_id: str, meta: dict[str, Any]) -> None:
        self.sessions.add(conv_id)
        self.count += 1
        self.meta.append(meta)
        if len(text) < len(self.label):
            self.label = text  # shortest phrasing is the cleanest label
        self.member_tokens.append(content_tokens(text))

    def score(self, tokens: frozenset[str]) -> float:
        """Best similarity to any member; a growing cluster cannot drift beyond what one member supports."""
        return max(similarity(tokens, member) for member in self.member_tokens)

    @property
    def support(self) -> int:
        return len(self.sessions)


def cluster_texts(items: list[tuple[str, str, dict[str, Any]]]) -> list[Cluster]:
    """Greedy clustering on content-word overlap; items are (text, conv_id, meta)."""
    clusters: list[Cluster] = []
    for text, conv_id, meta in sorted(items, key=lambda t: len(t[0])):
        tokens = content_tokens(text)
        best, best_score = None, 0.0
        for c in clusters:
            score = c.score(tokens)
            if score > best_score:
                best, best_score = c, score
        if best is not None and best_score >= CLUSTER_THRESHOLD:
            best.add(text, conv_id, meta)
        else:
            clusters.append(Cluster(text, conv_id, meta))
    return sorted(clusters, key=lambda c: (-c.support, -c.count, c.label))


def _majority(values: list[str]) -> str:
    return Counter(values).most_common(1)[0][0] if values else ""


def summarize_cards(sessions: list[core.Session]) -> dict[str, Any] | None:
    """Aggregate cached cards for the given sessions; None when no valid card exists yet."""
    users = [s for s in sessions if s.kind == "user"]
    schema = load_schema()
    cards: dict[str, dict[str, Any]] = {}
    stale = invalid = 0
    for s in users:
        entry = cached_card(s.conv_id)
        if not entry or not isinstance(entry.get("card"), dict):
            continue
        if validate(entry["card"], schema):
            invalid += 1  # a malformed cached card is skipped, never allowed to break the digest
            continue
        cards[s.conv_id] = entry["card"]
        if entry.get("source") != source_stamp(s.path):
            stale += 1
    if not cards:
        return None
    trivial = sum(1 for s in users if is_trivial(s))
    outcomes, kinds, confidence = Counter(), Counter(), Counter()
    effort = Counter()
    blockers: dict[str, dict[str, Any]] = defaultdict(
        lambda: {"count": 0, "weighted": 0, "sessions": [], "details": []}
    )
    instructions: list[tuple[str, str, dict[str, Any]]] = []
    fixes_by_type: dict[str, dict[str, Any]] = defaultdict(
        lambda: {"sessions": set(), "mechanisms": Counter(), "candidates": []}
    )
    worked_well = []
    for conv_id, card in cards.items():
        outcomes[card["outcome"]] += 1
        kinds[card["task"]["kind"]] += 1
        confidence[card["confidence"]] += 1
        effort.update(card["user_effort"])
        if card.get("worked_well"):
            worked_well.append((conv_id[:8], card["worked_well"]))
        for b in card["blockers"]:
            slot = blockers[b["type"]]
            slot["count"] += 1
            slot["weighted"] += COST_WEIGHT[b["cost"]]
            if conv_id[:8] not in slot["sessions"]:
                slot["sessions"].append(conv_id[:8])
            if len(slot["details"]) < 3:
                slot["details"].append(f"{conv_id[:8]}#{b['step']}: {b['detail']}")
        for ins in card["standing_instructions"]:
            if card["confidence"] != "low":
                instructions.append((ins["text"], conv_id, {"scope": ins["scope"]}))
        for fx in card["fix_candidates"]:
            types = {card["blockers"][i]["type"] for i in fx["blockers"] if 0 <= i < len(card["blockers"])} or {
                "unlinked"
            }
            for btype in types:
                slot = fixes_by_type[btype]
                slot["sessions"].add(conv_id[:8])
                slot["mechanisms"][fx["mechanism"]] += 1
                if len(slot["candidates"]) < 3:
                    slot["candidates"].append(f"[{fx['mechanism']}/{fx['scope']}] {fx['text']}")
    sides = Counter()
    for btype, slot in blockers.items():
        sides[BLOCKER_SIDE.get(btype, "agent")] += slot["weighted"]
    ins_clusters = cluster_texts(instructions)
    return {
        "coverage": {
            "labelled": len(cards),
            "eligible": len(users) - trivial,
            "trivial": trivial,
            "stale": stale,
            "invalid_cached": invalid,
            "low_confidence": confidence["low"],
        },
        "outcomes": dict(outcomes),
        "task_kinds": dict(kinds.most_common()),
        "user_effort": dict(effort),
        "blockers": [
            {"type": t, "side": BLOCKER_SIDE.get(t, "agent"), **slot}
            for t, slot in sorted(blockers.items(), key=lambda kv: -kv[1]["weighted"])
        ],
        "sides": dict(sides),
        "standing_instructions": [
            {
                "text": c.label,
                "support": c.support,
                "mentions": c.count,
                "sessions": sorted(x[:8] for x in c.sessions)[:5],
                "scope": _majority([m["scope"] for m in c.meta]),
            }
            for c in ins_clusters[:15]
        ],
        "fix_candidates": [
            {
                "blocker_type": btype,
                "support": len(slot["sessions"]),
                "sessions": sorted(slot["sessions"])[:5],
                "mechanisms": dict(slot["mechanisms"].most_common()),
                "candidates": slot["candidates"],
            }
            for btype, slot in sorted(fixes_by_type.items(), key=lambda kv: -len(kv[1]["sessions"]))
        ],
        "worked_well": worked_well[:5],
    }


def render_sections(summary: dict[str, Any]) -> str:
    """Markdown for the digest's judged-evidence section."""
    cov = summary["coverage"]
    out = [
        f"Cards: **{cov['labelled']} of {cov['eligible']} eligible sessions labelled** "
        f"({cov['trivial']} trivial sessions skipped, {cov['stale']} cards stale, "
        f"{cov['low_confidence']} low confidence). "
        "Cards are model judgements over evidence packets; counts below are deterministic over those cards.\n",
        "Outcomes: " + ", ".join(f"{k} {v}" for k, v in summary["outcomes"].items()) + " · "
        "Task kinds: " + ", ".join(f"{k} {v}" for k, v in summary["task_kinds"].items()) + " · "
        "User effort: " + ", ".join(f"{k} {v}" for k, v in summary["user_effort"].items()) + "\n",
        "Blockers by type (weighted cost: low 1 · medium 2 · high 3):\n",
        core._table(
            ["Type", "Side", "Count", "Weighted", "Sessions", "Examples"],
            [
                [
                    b["type"],
                    b["side"],
                    b["count"],
                    b["weighted"],
                    ", ".join(f"`{x}`" for x in b["sessions"][:5]),
                    " / ".join(core._redact(d) for d in b["details"][:2]),
                ]
                for b in summary["blockers"]
            ],
        ),  # fmt: skip
        "\nWeighted cost by side: " + ", ".join(f"{k} {v}" for k, v in summary["sides"].items()) + "\n",
        "\nStanding instructions you gave (clustered; support = distinct sessions):\n",
        core._table(
            ["Support", "Mentions", "Scope", "Instruction", "Sessions"],
            [
                [
                    c["support"],
                    c["mentions"],
                    c["scope"],
                    core._redact(c["text"]),
                    ", ".join(f"`{x}`" for x in c["sessions"]),
                ]
                for c in summary["standing_instructions"]
            ],
        ),  # fmt: skip
        "\nFix candidates proposed by the cards, grouped by the blocker type they address "
        "(support = sessions proposing a fix for that type):\n",
        core._table(
            ["Blocker type", "Support", "Mechanisms", "Sample candidates", "Sessions"],
            [
                [
                    c["blocker_type"],
                    c["support"],
                    ", ".join(f"{k} {v}" for k, v in c["mechanisms"].items()),
                    " / ".join(core._redact(core._one_line(t, 160)) for t in c["candidates"][:2]),
                    ", ".join(f"`{x}`" for x in c["sessions"]),
                ]
                for c in summary["fix_candidates"]
            ],
        ),  # fmt: skip
    ]
    if summary["worked_well"]:
        out.append(
            "\nWorked well: "
            + "; ".join(f"`{cid}` {core._redact(text)}" for cid, text in summary["worked_well"])
            + "\n"
        )
    return "\n".join(out)


def status(args: argparse.Namespace) -> str:
    sessions = core.load_sessions(args)
    summary = summarize_cards(sessions)
    if summary is None:
        users = [s for s in sessions if s.kind == "user"]
        trivial = sum(1 for s in users if is_trivial(s))
        return f"no cards yet; {len(users) - trivial} eligible sessions in the window ({trivial} trivial)\n"
    return json.dumps(summary["coverage"], indent=2) + "\n"


# --------------------------------------------------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--days", type=int, default=30, help="look-back window in days (0 = all time)")
    common.add_argument("--since", help="start date YYYY-MM-DD (overrides --days)")
    common.add_argument("--until", help="end date YYYY-MM-DD (inclusive)")
    common.add_argument("--brain", type=Path, action="append", help="brain directory to scan (repeatable)")
    common.add_argument("--workspace", help="only sessions whose inferred workspace contains this text")
    common.add_argument("--include-subagents", action="store_true")
    common.add_argument("-v", "--verbose", action="store_true")

    sub = parser.add_subparsers(dest="mode", required=True)
    packets = sub.add_parser("packets", parents=[common], help="write evidence packets for sessions needing a card")
    packets.add_argument("--out-dir", type=Path, required=True)
    packets.add_argument("--max-label", type=int, default=60, help="cap per run, highest friction first")
    packets.add_argument("--force", action="store_true", help="re-label sessions that already have a fresh card")

    ing = sub.add_parser("ingest", help="validate and cache card files")
    ing.add_argument("cards_dir", type=Path)
    ing.add_argument("--index", type=Path, help="packets/index.json (source stamps); found automatically if omitted")
    ing.add_argument("--model", default=None, help="model name to record when the card file does not say")
    ing.add_argument("--brain", type=Path, action="append")

    lab = sub.add_parser("label", help="headless labelling with agy --print (cron use)")
    lab.add_argument("--packets", type=Path, required=True)
    lab.add_argument("--out", type=Path, required=True)
    lab.add_argument("--runner", choices=["agy"], default="agy")
    lab.add_argument("--agy", default="agy", help="agy binary")
    lab.add_argument("--model", default="gemini-3.8-flash-low", help="measured: ~14 s/card, same depth as flash-next")
    lab.add_argument("--effort", default=None, help="reasoning effort flag, only for models that accept it")
    lab.add_argument("--jobs", type=int, default=8)
    lab.add_argument("--timeout", type=int, default=600, help="seconds per packet")
    lab.add_argument("--print-timeout", default="5m", help="agy --print-timeout value")
    lab.add_argument("--force", action="store_true")

    sub.add_parser("status", parents=[common], help="card coverage for the window")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if getattr(args, "verbose", False) else logging.WARNING)
    if hasattr(args, "brain"):
        args.brain = args.brain or [b for b in core.DEFAULT_BRAINS if b.is_dir()] or list(core.DEFAULT_BRAINS)
    if args.mode == "packets":
        text = write_packets(args)
    elif args.mode == "ingest":
        if args.index is None:
            guess = args.cards_dir.parent / "packets" / "index.json"
            args.index = guess if guess.is_file() else None
        text = ingest(args)
    elif args.mode == "label":
        text = label(args)
    else:
        text = status(args)
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
