#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Antigravity ``PostInvocation`` hook that surfaces the model's reasoning in the conversation.

The hook reads the ``PostInvocation`` payload from stdin, finds the reasoning ("thinking") that
produced the step(s) of the invocation that just finished, and injects a UI-only system-message
step whose ``renderInfo`` renders that reasoning as a collapsible block, so the agent's thoughts
are visible like in Claude Code or GitHub Copilot.

Reasoning sources, in order of preference:

1. ``modelThinking`` in the hook payload (populated on internal builds only).
2. The ``thinking`` field of the ``PLANNER_RESPONSE`` steps that the invocation appended to the
   conversation transcript (``transcript_full.jsonl`` next to ``transcriptPath``). This works on
   every build because the transcript is the agent's system of record.

The injected step carries an empty ``systemMessage`` text so the model receives no extra tokens;
only the user-facing markdown is attached.

Usage (``~/.gemini/config/hooks.json`` or ``<workspace>/.agents/hooks.json``)::

    {
      "show-reasoning": {
        "PostInvocation": [
          {"type": "command", "command": "python3 ~/.gemini/config/hooks/show_reasoning.py", "timeout": 10}
        ]
      }
    }

The script carries PEP 723 inline metadata (standard library only, Python 3.12+), so ``python3`` above
can be swapped for ``uv run --script`` when a managed interpreter is preferred.

Surface support (verified on agy 1.4.12): the injected step is persisted on every surface, but only
the App/Jetski UI draws ``renderInfo``; the terminal UI draws nothing for hook system messages. In
``agy`` use the native display instead: ``verbosity: high`` plus ``Ctrl+O`` expands ``Thought for Ns``.

The hook never fails the agent loop: on any error it prints ``{}`` and exits 0, logging the
problem to ``show_reasoning.log`` next to this file when ``--debug`` is set.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

NOOP_OUTPUT = "{}"
PLANNER_RESPONSE = "PLANNER_RESPONSE"
TAIL_BYTES = 4 * 1024 * 1024
STATE_DIR = Path(os.environ.get("TMPDIR", "/tmp")) / "antigravity-show-reasoning"

# Marker fragments of ``transcriptPath`` that identify the Antigravity surface running the hook.
APP_MARKERS: dict[str, str] = {
    "cli": "/antigravity-cli/",
    "app": "/antigravity/",
    "ide": "/antigravity-ide/",
    "jetski": "/jetski/",
}


@dataclass(frozen=True)
class Reasoning:
    """Reasoning text recovered for one model invocation."""

    text: str
    step_indexes: tuple[int, ...]
    source: str


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse command-line options for the hook."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--apps",
        default=os.environ.get("SHOW_REASONING_APPS", "jetski,app,ide,cli"),
        help="Comma-separated surfaces to act on: cli, app, ide, jetski, or all (default: %(default)s).",
    )
    parser.add_argument(
        "--max-chars",
        type=int,
        default=int(os.environ.get("SHOW_REASONING_MAX_CHARS", "8000")),
        help="Truncate reasoning longer than this many characters (default: %(default)s).",
    )
    parser.add_argument(
        "--wait-ms",
        type=int,
        default=int(os.environ.get("SHOW_REASONING_WAIT_MS", "400")),
        help="How long to wait for the transcript to contain the new step before giving up (default: %(default)s).",
    )
    parser.add_argument(
        "--model-visible",
        action="store_true",
        help="Also send the reasoning to the model as system-message text (costs tokens; off by default).",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        default=os.environ.get("SHOW_REASONING_DEBUG") == "1",
        help="Append diagnostics (payload keys, transcript state) to show_reasoning.log next to this script.",
    )
    return parser.parse_args(argv)


def configure_logging(debug: bool) -> None:
    """Send diagnostics to a log file next to the script; stderr stays clean for the host."""
    if not debug:
        logging.disable(logging.CRITICAL)
        return
    log_path = Path(__file__).with_suffix(".log")
    logging.basicConfig(
        filename=log_path,
        level=logging.DEBUG,
        format="%(asctime)s %(levelname)s %(message)s",
    )


def detect_app(transcript_path: str) -> str:
    """Return the Antigravity surface (``cli``, ``app``, ``ide``, ``jetski``) that owns ``transcript_path``."""
    for app, marker in APP_MARKERS.items():
        if marker in transcript_path:
            return app
    return "unknown"


def wanted_apps(spec: str) -> set[str]:
    """Normalize the ``--apps`` option into a set of surface names (``all`` expands to every surface)."""
    apps = {part.strip().lower() for part in spec.split(",") if part.strip()}
    return set(APP_MARKERS) | {"unknown"} if "all" in apps else apps


def tail_lines(path: Path, max_bytes: int = TAIL_BYTES) -> Iterator[str]:
    """Yield the complete lines contained in the last ``max_bytes`` of ``path``."""
    size = path.stat().st_size
    offset = max(0, size - max_bytes)
    with path.open("rb") as handle:
        handle.seek(offset)
        data = handle.read()
    if offset:
        data = data.split(b"\n", 1)[1] if b"\n" in data else b""
    for raw in data.split(b"\n"):
        if raw.strip():
            yield raw.decode("utf-8", errors="replace")


def read_planner_steps(transcript_path: str) -> list[dict[str, Any]]:
    """Return the ``PLANNER_RESPONSE`` steps found in the tail of the transcript (full version preferred)."""
    compact = Path(transcript_path).expanduser()
    candidates = [compact.with_name("transcript_full.jsonl"), compact]
    for candidate in candidates:
        if not candidate.is_file():
            continue
        steps: list[dict[str, Any]] = []
        for line in tail_lines(candidate):
            try:
                step = json.loads(line)
            except json.JSONDecodeError:
                continue
            if step.get("type") == PLANNER_RESPONSE:
                steps.append(step)
        logger.debug("transcript %s: %d planner steps in tail", candidate, len(steps))
        return steps
    logger.debug("no transcript found for %s", transcript_path)
    return []


def state_file(conversation_id: str) -> Path:
    """Path of the per-conversation file remembering the last step index already rendered."""
    safe_id = "".join(ch for ch in conversation_id if ch.isalnum() or ch in "-_") or "unknown"
    return STATE_DIR / f"{safe_id}.last_step"


def load_last_rendered(conversation_id: str) -> int:
    """Return the highest step index already rendered for the conversation (``-1`` when none)."""
    try:
        return int(state_file(conversation_id).read_text().strip())
    except (OSError, ValueError):
        return -1


def save_last_rendered(conversation_id: str, step_index: int) -> None:
    """Persist the highest step index rendered for the conversation."""
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        state_file(conversation_id).write_text(str(step_index))
    except OSError:
        logger.exception("cannot persist state for %s", conversation_id)


def reasoning_from_payload(payload: dict[str, Any]) -> Reasoning | None:
    """Use ``modelThinking`` from the payload when the host provides it (internal builds)."""
    thinking = payload.get("modelThinking")
    if isinstance(thinking, str) and thinking.strip():
        return Reasoning(text=thinking.strip(), step_indexes=(), source="payload")
    return None


def reasoning_from_transcript(payload: dict[str, Any], wait_ms: int) -> Reasoning | None:
    """Collect the ``thinking`` of planner steps added by this invocation, waiting briefly for the transcript."""
    transcript_path = payload.get("transcriptPath", "")
    if not transcript_path:
        return None
    conversation_id = str(payload.get("conversationId", ""))
    floor = max(int(payload.get("initialNumSteps", 0) or 0), load_last_rendered(conversation_id) + 1)
    deadline = time.monotonic() + wait_ms / 1000
    while True:
        new_steps = [
            step for step in read_planner_steps(transcript_path) if int(step.get("step_index", -1)) >= floor
        ]
        if new_steps or time.monotonic() >= deadline:
            break
        time.sleep(0.05)
    chunks = [str(step.get("thinking") or "").strip() for step in new_steps]
    chunks = [chunk for chunk in chunks if chunk]
    if not chunks:
        logger.debug("no new planner thinking at or after step %d", floor)
        return None
    indexes = tuple(int(step["step_index"]) for step in new_steps)
    save_last_rendered(conversation_id, max(indexes))
    return Reasoning(text="\n\n".join(chunks), step_indexes=indexes, source="transcript")


def truncate(text: str, max_chars: int) -> str:
    """Cut ``text`` to ``max_chars`` while saying how much was dropped."""
    if max_chars <= 0 or len(text) <= max_chars:
        return text
    dropped = len(text) - max_chars
    return f"{text[:max_chars].rstrip()}\n\n_… {dropped:,} more characters truncated_"


def render_title(reasoning: Reasoning, payload: dict[str, Any]) -> str:
    """Build the one-line header shown for the injected step."""
    bits = ["Reasoning"]
    invocation = payload.get("invocationNum")
    if invocation is not None:
        bits.append(f"invocation {invocation}")
    if reasoning.step_indexes:
        first, last = min(reasoning.step_indexes), max(reasoning.step_indexes)
        bits.append(f"step {first}" if first == last else f"steps {first}–{last}")
    bits.append(f"{len(reasoning.text):,} chars")
    return " · ".join(bits)


def render_markdown(reasoning: Reasoning, max_chars: int) -> str:
    """Format the reasoning as a quoted markdown block."""
    body = truncate(reasoning.text, max_chars)
    return "\n".join(f"> {line}" if line else ">" for line in body.splitlines())


def build_output(title: str, markdown: str, model_visible: bool) -> dict[str, Any]:
    """Build the ``injectSteps`` response that renders ``markdown`` for the user.

    ``renderInfo`` makes the step a UI-only header plus collapsible body. With an empty
    ``systemMessage`` the step is persisted without content, so the model never sees it.
    (``metadata.user_markdown`` is documented too, but agy 1.4.5's JSON-to-proto converter
    panics on the map field - ``type mismatch: cannot convert string to message`` - so avoid it.)
    """
    return {
        "injectSteps": [
            {
                "systemMessage": {
                    "systemMessage": markdown if model_visible else "",
                    "renderInfo": {"title": title, "titlePrefix": "💭", "markdown": markdown},
                }
            }
        ]
    }


def run(args: argparse.Namespace, raw_payload: str) -> str:
    """Compute the hook's stdout for ``raw_payload``; returns ``{}`` whenever nothing should be injected."""
    payload = json.loads(raw_payload) if raw_payload.strip() else {}
    logger.debug("payload keys=%s", sorted(payload))
    app = detect_app(str(payload.get("transcriptPath", "")))
    if app not in wanted_apps(args.apps):
        logger.debug("skipping surface %s (wanted %s)", app, args.apps)
        return NOOP_OUTPUT
    reasoning = reasoning_from_payload(payload) or reasoning_from_transcript(payload, args.wait_ms)
    if reasoning is None:
        return NOOP_OUTPUT
    logger.debug("reasoning from %s, steps=%s, %d chars", reasoning.source, reasoning.step_indexes, len(reasoning.text))
    title = render_title(reasoning, payload)
    markdown = render_markdown(reasoning, args.max_chars)
    return json.dumps(build_output(title, markdown, args.model_visible), ensure_ascii=False)


def main() -> int:
    """Entry point: never raise, always print valid JSON."""
    args = parse_args()
    configure_logging(args.debug)
    try:
        print(run(args, sys.stdin.read()))
    except Exception:  # noqa: BLE001 - a hook must never break the agent loop.
        logger.exception("show_reasoning failed")
        print(NOOP_OUTPUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
