#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Turn local Antigravity / Jetski transcripts into an evidence digest for action items.

Modes
-----
report   (default) Friction evidence digest + ``summary.json``; stores a snapshot so the next run can show deltas and
         lists the open action items recorded in ``~/.gemini/improve-agy/actions.md``.
session  Deep dive into one conversation (id prefix accepted) to back a specific action item with evidence.
actions  Ledger of recorded action items: ``actions add <text>``, ``actions list``, ``actions done <n> [note]``.

Everything runs locally and reads only ``<brain>/<conversation-id>/.system_generated/logs/transcript.jsonl``.
Nothing is uploaded; transcripts are never modified.

Examples
--------
    uv run analyze_sessions.py report --days 30 --out-dir /tmp/improve-agy
    uv run analyze_sessions.py session d6b91250
    uv run analyze_sessions.py actions add "Rule: ls before read_file · verify tool_errors_per_100_calls 1.5 → <0.8"
"""

from __future__ import annotations

import argparse
import functools
import json
import logging
import re
import shlex
import statistics
import sys
from collections import Counter, defaultdict, deque
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta, timezone
from pathlib import Path
from typing import Any

logger = logging.getLogger("improve_agy")

DEFAULT_BRAINS: tuple[Path, ...] = (
    Path.home() / ".gemini" / "jetski" / "brain",
    Path.home() / ".gemini" / "antigravity" / "brain",
    Path.home() / ".gemini" / "antigravity-cli" / "brain",  # agy CLI sessions, including headless --print runs
)
STATE_DIR = Path.home() / ".gemini" / "improve-agy"
ACTIONS_FILE = STATE_DIR / "actions.md"
TRANSCRIPT_REL = Path(".system_generated") / "logs" / "transcript.jsonl"
TOOLING_MARKER = (
    "Review card for session"  # first line of improve-agy's own labelling prompts; those sessions are skipped
)

IDLE_GAP_SECONDS = 600  # gaps longer than this do not count as active time
RAPID_FOLLOWUP_SECONDS = 90
RAPID_FOLLOWUP_MAX_CHARS = 120
EXCERPT_CHARS = 240
EXAMPLE_SESSIONS = 3
EDIT_TOOLS = frozenset(
    {"edit_file", "write_file", "notebook_edit", "replace_file_content", "multi_replace_file_content"}
)
POLL_TOOLS = frozenset({"manage_task", "swarm_wait", "read_board"})
SUBCOMMAND_BINARIES = frozenset(
    {
        "git", "make", "go", "kubectl", "gcloud", "gsutil", "bq", "npm", "pnpm", "yarn", "uv", "pip", "pip3", "python",
        "python3", "docker", "helm", "terraform", "cargo", "mvn", "gradle", "az", "gh", "brew", "skaffold", "bazel",
        "blaze", "agentapi", "ruff", "pytest", "node", "npx", "santactl", "claat", "skillshare", "mvnw", "gradlew",
    }
)  # fmt: skip
IGNORED_PATH_PREFIXES = (
    "/tmp", "/private", "/opt", "/usr", "/etc", "/bin", "/sbin", "/Library", "/System", "/Applications", "/dev", "/var",
    "/proc", "/nix", "/google/src/files",
)  # fmt: skip
WORKSPACE_MARKERS = (
    "AGENTS.md", "GEMINI.md", ".git", "go.mod", "pyproject.toml", "package.json", "Makefile", "pom.xml"
)  # fmt: skip

STRONG_CORRECTION = re.compile(
    r"^(no[,.!\s]|nope\b|wrong\b|that'?s (not|wrong)|not what i|i (said|asked|meant|told)|don'?t\b|do not\b|stop\b"
    r"|undo\b|revert\b|you (didn'?t|did not|broke|ignored|missed|forgot|skipped)|why did you|again[.!?]?$"
    r"|still (not|doesn'?t|fails|failing|broken|wrong)|incorrect\b|didn'?t work|doesn'?t work|not working|rollback\b)",
    re.IGNORECASE,
)
MEDIUM_CORRECTION = re.compile(
    r"\b(instead|actually|should have|rather than|too (long|verbose|many|much)|simpler|i already|as i said"
    r"|please follow|you must|never|always|re-?do|try again|once more|not (that|this|what)"
    r"|wrong (file|place|branch))\b",
    re.IGNORECASE,
)
REQUEST_RE = re.compile(r"<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>", re.DOTALL)
LOCAL_TIME_RE = re.compile(r"current local time is:\s*\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?([+-]\d{2}:\d{2}|Z)")
SLASH_RE = re.compile(r"(/[a-z][a-z0-9-]*) is a \[Slash Command\]")
SKILL_RE = re.compile(r"explicitly invoked the \(([a-z0-9-]+)\) skill")
EXIT_CODE_RE = re.compile(r"Command exited with code (\d+)")
BACKGROUND_RE = re.compile(r"Tool is running as a background task")
SANDBOX_RE = re.compile(
    r"operation not permitted|permission check failed|Permission denied for (?:read|write)_file|No matching rule",
    re.IGNORECASE,
)
ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
MESSAGE_SENDER_RE = re.compile(r"\[Message\].*?sender=([0-9a-f-]{8,})", re.DOTALL)
API_ERROR_CODE_RE = re.compile(
    r"\b(RESOURCE_EXHAUSTED|UNAVAILABLE|DEADLINE_EXCEEDED|INTERNAL|PERMISSION_DENIED|code \d{3})\b"
)
ENV_PREFIX_RE = re.compile(r"""^(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\$\([^)]*\)|\S+)\s+)+""")
SHELL_KEYWORDS = frozenset(
    {"for", "while", "until", "if", "do", "then", "else", "elif", "fi", "done", "case", "function"}
)
ABS_PATH_RE = re.compile(r"^/[^\s'\"`]+$")
REDACTIONS = (
    re.compile(r"AIza[0-9A-Za-z_\-]{20,}"),
    re.compile(r"gh[pousr]_[0-9A-Za-z]{20,}"),
    re.compile(r"ya29\.[0-9A-Za-z_\-]+"),
    re.compile(r"sk-[0-9A-Za-z\-]{20,}"),
    re.compile(r"xox[baprs]-[0-9A-Za-z\-]+"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"(?i)\b(bearer|token|password|passwd|secret|api[_-]?key)\b(\s*[:=]\s*)\S+"),
    re.compile(r"(?i)\b(bearer)(\s+)[A-Za-z0-9._\-]{16,}"),
)


# --------------------------------------------------------------------------------------------------------------------
# Data model
# --------------------------------------------------------------------------------------------------------------------
@dataclass(slots=True)
class UserMessage:
    """One user turn."""

    step: int
    ts: datetime
    text: str
    slash_commands: list[str]
    skills: list[str]
    correction_score: int = 0
    rapid_followup: bool = False


@dataclass(slots=True)
class ToolCall:
    """One tool invocation requested by the agent."""

    step: int
    ts: datetime
    name: str
    signature: str
    command: str | None
    command_key: str | None
    paths: list[str]
    poll: bool = False


@dataclass(slots=True)
class ToolResult:
    """The step that carried a tool's output, paired with its call when possible."""

    step: int
    ts: datetime
    call: ToolCall | None
    exit_code: int | None
    error: str | None
    background: bool
    sandbox_block: bool
    excerpt: str = ""  # redacted tail of the output, kept only for failures

    @property
    def label(self) -> str:
        """Short name of what ran: command key for shell, tool name otherwise."""
        if self.call is None:
            return "(unpaired)"
        return self.call.command_key or self.call.name

    @property
    def target(self) -> str:
        """What the call acted on: the command line (env prefixes stripped) for shell, the paths for file tools."""
        if self.call is None:
            return "(unpaired result)"
        if self.call.command:
            return display_command(self.call.command)
        return f"{self.call.name} {' '.join(self.call.paths)}".strip()


@dataclass(slots=True)
class Session:
    """Everything extracted from a single conversation transcript."""

    conv_id: str
    brain: str
    path: Path
    kind: str = "user"  # user | subagent | tooling | empty
    parent_id: str | None = None
    brief: str = ""
    tz: timezone = UTC
    started: datetime | None = None
    ended: datetime | None = None
    steps: int = 0
    agent_turns: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    compactions: int = 0
    api_errors: list[str] = field(default_factory=list)
    user_messages: list[UserMessage] = field(default_factory=list)
    tool_calls: list[ToolCall] = field(default_factory=list)
    tool_results: list[ToolResult] = field(default_factory=list)
    active_seconds: float = 0.0
    max_streak: int = 0
    retries: int = 0
    retry_tools: Counter[str] = field(default_factory=Counter)
    polls: int = 0
    last_step_type: str = ""
    last_step_status: str = ""
    last_tool: str = ""
    final_reply: str = ""

    @property
    def short_id(self) -> str:
        """First eight characters of the conversation id, used in tables."""
        return self.conv_id[:8]

    @property
    def title(self) -> str:
        """First user request, trimmed for tables."""
        if not self.user_messages:
            return f"[subagent] {_one_line(self.brief, 90)}" if self.brief else "(no user input)"
        text = re.sub(r"^/[a-z0-9-]+\s*", "", self.user_messages[0].text)
        return _one_line(text, 100) or "(empty request)"

    @property
    def duration_seconds(self) -> float:
        """Wall-clock span between first and last step."""
        if self.started and self.ended:
            return (self.ended - self.started).total_seconds()
        return 0.0

    @property
    def corrections(self) -> list[UserMessage]:
        """User turns that read as corrections of the agent."""
        return [m for m in self.user_messages if m.correction_score >= 2]

    @property
    def rapid_followups(self) -> int:
        """Short user turns sent within seconds of the previous reply (re-prompting)."""
        return sum(1 for m in self.user_messages if m.rapid_followup)

    @property
    def tool_errors(self) -> list[ToolResult]:
        """Tool results that carried an error."""
        return [r for r in self.tool_results if r.error]

    @property
    def failed_commands(self) -> list[ToolResult]:
        """run_command results with a non-zero exit code."""
        return [r for r in self.tool_results if r.exit_code not in (None, 0)]

    @property
    def sandbox_blocked(self) -> list[ToolResult]:
        """Tool results that hit a sandbox or permission denial."""
        return [r for r in self.tool_results if r.sandbox_block]

    @property
    def files_edited(self) -> set[str]:
        """Distinct absolute paths touched by editing tools."""
        return {p for c in self.tool_calls if c.name in EDIT_TOOLS for p in c.paths}

    @property
    def commits(self) -> int:
        """Successful ``git commit`` invocations (approximation)."""
        return sum(
            1 for r in self.tool_results if r.exit_code == 0 and r.call and "git commit" in (r.call.command or "")
        )

    @property
    def repeated_failures(self) -> Counter[str]:
        """Command keys that failed at least twice in this session."""
        counts = Counter(r.call.command_key for r in self.failed_commands if r.call and r.call.command_key)
        return Counter({k: v for k, v in counts.items() if v >= 2})

    @property
    def friction_score(self) -> int:
        """Weighted friction score used only to rank sessions for deep dives; higher is worse."""
        return (
            3 * len(self.corrections)
            + 2 * self.retries
            + len(self.failed_commands)
            + len(self.tool_errors)
            + len(self.sandbox_blocked)
            + self.compactions
            + self.rapid_followups
        )

    @property
    def outcome(self) -> str:
        """Best-effort description of how the session ended."""
        if self.last_step_status == "RUNNING":
            return "background task still running"
        if self.last_step_type == "USER_INPUT":
            return "ended on a user message (cancelled or unanswered)"
        if self.last_tool == "ask_question":
            return "waiting on a question to the user"
        if self.last_step_status == "ERROR":
            return "ended on a tool error"
        if self.last_step_type == "PLANNER_RESPONSE":
            return "completed turn"
        return f"ended on {self.last_step_type or 'unknown'}"

    def workspace(self) -> str:
        """Infer the workspace root: the most common project root among paths touched by tool calls."""
        home = str(Path.home())
        roots = Counter(
            _workspace_root(Path(p).parent)
            for c in self.tool_calls
            for p in c.paths
            if not p.startswith(IGNORED_PATH_PREFIXES) and not p.startswith(f"{home}/.gemini")
        )
        if not roots:
            return "(no files touched)"
        return _tilde(roots.most_common(1)[0][0])


@functools.lru_cache(maxsize=4096)
def _workspace_root(directory: Path) -> Path:
    """Walk up from ``directory`` to the nearest ancestor that looks like a project root.

    Falls back to at most two components below ``$HOME`` (e.g. ``~/Develop/project``) when no marker file exists,
    which also covers workspaces that were deleted since the session ran.
    """
    home = Path.home()
    for candidate in (directory, *directory.parents):
        if candidate in (home, home.parent, Path("/")):
            break
        if any((candidate / marker).exists() for marker in WORKSPACE_MARKERS):
            return candidate
    try:
        rel = directory.relative_to(home)
    except ValueError:
        return Path(*directory.parts[:3]) if len(directory.parts) > 3 else directory
    return home.joinpath(*rel.parts[:2]) if rel.parts else directory


# --------------------------------------------------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------------------------------------------------
def _parse_ts(raw: str | None) -> datetime | None:
    if not raw:
        return None
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)


def _unquote(value: Any) -> Any:
    """Transcript tool args are often JSON-encoded strings inside strings; unwrap one level."""
    if isinstance(value, str) and len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value[1:-1]
    return value


def _one_line(text: str, limit: int) -> str:
    collapsed = re.sub(r"\s+", " ", text).strip()
    return collapsed if len(collapsed) <= limit else collapsed[: limit - 1] + "…"


def _redact(text: str) -> str:
    for pattern in REDACTIONS:
        text = pattern.sub(
            lambda m: (m.group(1) + m.group(2) if m.lastindex and m.lastindex >= 2 else "") + "[REDACTED]", text
        )
    return text


def _tilde(path: Path | str) -> str:
    text = str(path)
    home = str(Path.home())
    return "~" + text[len(home) :] if text.startswith(home) else text


def _request_text(content: str) -> str:
    match = REQUEST_RE.search(content)
    return (match.group(1) if match else content).strip()


def _tz_from_content(content: str) -> timezone | None:
    match = LOCAL_TIME_RE.search(content)
    if not match:
        return None
    offset = match.group(1)
    if offset == "Z":
        return UTC
    sign = 1 if offset[0] == "+" else -1
    hours, minutes = int(offset[1:3]), int(offset[4:6])
    return timezone(sign * timedelta(hours=hours, minutes=minutes))


SUBST_RE = re.compile(r"\$\([^()]*\)")
PLACEHOLDER_RE = re.compile(r"\x00(\d+)\x00")


def _mask_substitutions(command: str) -> tuple[str, list[str]]:
    """Replace ``$(...)`` groups (three nesting levels) with placeholders so separators inside them are ignored."""
    groups: list[str] = []
    masked = command
    for _ in range(3):
        updated = SUBST_RE.sub(lambda m: (groups.append(m.group(0)), f"\x00{len(groups) - 1}\x00")[1], masked)
        if updated == masked:
            break
        masked = updated
    return masked, groups


def _unmask(text: str, groups: list[str]) -> str:
    for _ in range(3):
        text = PLACEHOLDER_RE.sub(lambda m: groups[int(m.group(1))], text)
    return text


def display_command(command: str) -> str:
    """Command line for humans: drop leading ``VAR=value`` assignments from every segment so the binary is visible."""
    masked, groups = _mask_substitutions(command)
    segments = re.split(r"(\s*&&\s*|\s*;\s*|\s*\|\s*)", masked)
    stripped = "".join(ENV_PREFIX_RE.sub("", seg) if i % 2 == 0 else seg for i, seg in enumerate(segments))
    return _unmask(stripped, groups).strip()


def command_key(command: str) -> str:
    """Normalize a shell command line to ``binary [subcommand]`` for grouping.

    Skips leading ``cd``/``export``/``VAR=value`` segments and wrapper tokens (``time``, ``sudo``, ``env``,
    ``uv run``, ``uv tool run``) so the key names the program that did the work.
    """
    masked, groups = _mask_substitutions(command)
    segments = [s.strip() for s in re.split(r"&&|\|\||;|\|", masked) if s.strip()]
    for segment in segments:
        segment = ENV_PREFIX_RE.sub("", segment)
        try:
            tokens = shlex.split(_unmask(segment, groups))
        except ValueError:
            tokens = _unmask(segment, groups).split()
        tokens = _unwrap(tokens)
        if not tokens or tokens[0] in {"cd", "export", "set", "source", ".", "pushd", "popd", "unset"}:
            continue
        if ASSIGNMENT_RE.match(tokens[0]):
            continue
        if tokens[0] in SHELL_KEYWORDS:
            return "(shell control flow)"  # for/while/if blocks: the work happens inside, keyed separately
        binary = Path(tokens[0]).name
        if binary in {"python", "python3"} and len(tokens) > 1 and tokens[1] in {"-", "-c"}:
            return f"{binary} (inline)"
        if binary in SUBCOMMAND_BINARIES and len(tokens) > 1 and not tokens[1].startswith(("/", "-")):
            return f"{binary} {tokens[1]}"
        return binary
    return "(shell only)"


def _unwrap(tokens: list[str]) -> list[str]:
    """Drop wrapper programs so ``uv tool run ruff check`` is keyed as ``ruff check``."""
    while tokens:
        head = Path(tokens[0]).name
        if head in {"time", "sudo", "nohup", "exec", "command", "env", "uvx"} or ASSIGNMENT_RE.match(tokens[0]):
            tokens = tokens[1:]
        elif head == "uv" and len(tokens) > 1 and tokens[1] == "run":
            tokens = tokens[2:]
        elif head == "uv" and len(tokens) > 2 and tokens[1] == "tool" and tokens[2] == "run":
            tokens = tokens[3:]
        else:
            return tokens
    return tokens


def _extract_tool_call(step: int, ts: datetime, raw: dict[str, Any]) -> ToolCall:
    name = str(raw.get("name") or "unknown")
    args = {k: _unquote(v) for k, v in (raw.get("args") or {}).items()}
    command = None
    paths: list[str] = []
    for key, value in args.items():
        if key == "CommandLine" and isinstance(value, str):
            command = value
        elif isinstance(value, str) and ABS_PATH_RE.match(value) and len(value) < 400:
            paths.append(value)
    signature = f"{name}:{json.dumps(args, sort_keys=True, default=str)[:2000]}"
    poll = name in POLL_TOOLS and str(args.get("Action", "status")).lower() in {"status", "list"}
    return ToolCall(step, ts, name, signature, command, command_key(command) if command else None, paths, poll)


def _score_correction(text: str) -> int:
    """Score a user turn as a correction: strong cue = 3; medium cues = 2 when short or repeated, else 1.

    A single soft word ("instead", "always") buried in a long request is not evidence of a correction.
    """
    score = 3 if STRONG_CORRECTION.search(text) else 0
    medium_hits = len(MEDIUM_CORRECTION.findall(text))
    if medium_hits:
        score += 2 if (medium_hits >= 2 or len(text) < 300) else 1
    return score


def parse_session(transcript: Path, brain_label: str) -> Session:
    """Parse one transcript.jsonl into a Session."""
    session = Session(conv_id=transcript.parents[2].name, brain=brain_label, path=transcript)
    pending: deque[ToolCall] = deque()
    prev_ts: datetime | None = None
    last_model_ts: datetime | None = None
    streak = 0
    prev_signature: str | None = None
    with transcript.open(encoding="utf-8") as handle:
        for line in handle:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = _parse_ts(row.get("created_at")) or prev_ts or datetime.now(UTC)
            step = int(row.get("step_index", session.steps))
            kind = str(row.get("type", ""))
            status = str(row.get("status", ""))
            content = row.get("content") or ""
            session.steps += 1
            session.started = session.started or ts
            session.ended = ts
            if prev_ts is not None:
                gap = (ts - prev_ts).total_seconds()
                if 0 <= gap <= IDLE_GAP_SECONDS:
                    session.active_seconds += gap
            prev_ts = ts
            is_wakeup = kind == "USER_INPUT" and "<USER_REQUEST>" not in content and "<SYSTEM_MESSAGE>" in content
            if is_wakeup:
                kind = "SYSTEM_MESSAGE"  # a system message delivered through a user step: treat it as one
            session.last_step_type, session.last_step_status = kind, status

            if kind == "USER_INPUT":
                text = _request_text(content)
                tz = _tz_from_content(content)
                if tz is not None and not session.user_messages:
                    session.tz = tz
                message = UserMessage(step, ts, text, SLASH_RE.findall(content), SKILL_RE.findall(content))
                if session.user_messages:
                    message.correction_score = _score_correction(text)
                    if last_model_ts and (ts - last_model_ts).total_seconds() < RAPID_FOLLOWUP_SECONDS:
                        message.rapid_followup = len(text) < RAPID_FOLLOWUP_MAX_CHARS
                session.user_messages.append(message)
                session.max_streak = max(session.max_streak, streak)
                streak = 0
                prev_signature = None  # a re-run the user asked for is not an agent retry
                session.last_tool = ""
                pending.clear()
            elif kind == "PLANNER_RESPONSE":
                session.agent_turns += 1
                session.input_tokens += int(row.get("input_tokens") or 0)
                session.output_tokens += int(row.get("output_tokens") or 0)
                session.cache_read_tokens += int(row.get("cache_read_tokens") or 0)
                last_model_ts = ts
                if content:
                    session.final_reply = content
                calls = [_extract_tool_call(step, ts, tc) for tc in row.get("tool_calls") or []]
                for call in calls:
                    if call.signature == prev_signature:
                        session.retries += 1
                        session.retry_tools[call.name] += 1
                    prev_signature = call.signature
                    session.polls += int(call.poll)
                session.last_tool = calls[-1].name if calls else ""
                session.tool_calls.extend(calls)
                streak += len(calls)
                pending = deque(calls)
            elif kind == "GENERIC" and row.get("source") == "MODEL":
                session.tool_results.append(
                    _tool_result(step, ts, pending.popleft() if pending else None, row, content)
                )
            elif kind == "CHECKPOINT":
                session.compactions += 1
            elif kind == "ERROR_MESSAGE" and row.get("error"):
                session.api_errors.append(str(row["error"])[:200])
            elif kind == "SYSTEM_MESSAGE" and session.agent_turns == 0 and not session.user_messages:
                sender = MESSAGE_SENDER_RE.search(content)
                brief = content.split("content=", 1)[-1] if "content=" in content else ""
                if sender and (session.kind != "subagent" or session.brief.startswith("[swarm] new board message")):
                    session.kind = "subagent"
                    session.parent_id = sender.group(1)
                    session.brief = brief
    session.max_streak = max(session.max_streak, streak)
    if session.steps == 0:
        session.kind = "empty"
    elif session.user_messages and session.user_messages[0].text.startswith(TOOLING_MARKER):
        session.kind = "tooling"  # improve-agy's own labelling runs must not analyze themselves
    elif not session.user_messages and session.kind != "subagent":
        session.kind = "subagent"
    return session


def _tool_result(step: int, ts: datetime, call: ToolCall | None, row: dict[str, Any], content: str) -> ToolResult:
    """Build a ToolResult; exit codes and sandbox text are only trusted on shell results, errors on any tool."""
    is_shell = call is not None and call.name == "run_command"
    exit_match = EXIT_CODE_RE.search(content) if is_shell else None
    exit_code = int(exit_match.group(1)) if exit_match else None
    error = str(row["error"])[:300] if row.get("error") else None
    sandbox = bool(error and SANDBOX_RE.search(error)) or bool(
        is_shell and exit_code not in (None, 0) and SANDBOX_RE.search(content)
    )
    excerpt = _output_excerpt(content) if (exit_code not in (None, 0) or error or sandbox) else ""
    return ToolResult(step, ts, call, exit_code, error, bool(BACKGROUND_RE.search(content)), sandbox, excerpt)


def _output_excerpt(content: str, limit: int = 320) -> str:
    """Keep the informative tail of a tool output: drop timing boilerplate and the sandbox hint."""
    kept = [
        line
        for line in content.splitlines()
        if line.strip()
        and not line.startswith(("Created At:", "Completed At:", "Command exited with code", "Command output:"))
        and "sandbox errors that may or may not" not in line
        and "BypassSandbox" not in line
    ]
    return _redact(_one_line(" ⏎ ".join(kept[-6:]), limit))


def discover_transcripts(brains: list[Path]) -> list[tuple[Path, str]]:
    """Return (transcript path, brain label) pairs for every conversation under the given brain directories."""
    found: list[tuple[Path, str]] = []
    for brain in brains:
        if not brain.is_dir():
            logger.warning("brain directory not found: %s", brain)
            continue
        label = brain.parent.name  # jetski | antigravity
        for conv_dir in brain.iterdir():
            transcript = conv_dir / TRANSCRIPT_REL
            if transcript.is_file():
                found.append((transcript, label))
    return found


def load_sessions(args: argparse.Namespace) -> list[Session]:
    """Parse all transcripts and apply window / workspace / kind filters."""
    sessions: list[Session] = []
    since, until = _window(args)
    for transcript, label in discover_transcripts(args.brain):
        try:
            session = parse_session(transcript, label)
        except OSError as exc:
            logger.warning("skipping %s: %s", transcript, exc)
            continue
        if session.kind == "empty" or not session.ended:
            continue
        if session.kind == "tooling":
            continue
        if since and session.ended < since:
            continue
        if until and session.started and session.started > until:
            continue
        if session.kind == "subagent" and args.include_subagents:
            session.kind = "user"  # promote: analyze worker conversations like any other session
        sessions.append(session)  # subagents stay flagged by kind so cost accounting can still see them
    if args.workspace:
        needle = args.workspace.lower()
        kept = {s.conv_id for s in sessions if s.kind == "user" and needle in s.workspace().lower()}
        sessions = [
            s
            for s in sessions
            if s.conv_id in kept or (s.kind == "subagent" and (s.parent_id or "").split("/")[0] in kept)
        ]
    sessions.sort(key=lambda s: s.started or datetime.min.replace(tzinfo=UTC))
    return sessions


def _window(args: argparse.Namespace) -> tuple[datetime | None, datetime | None]:
    until = datetime.fromisoformat(args.until).replace(tzinfo=UTC) + timedelta(days=1) if args.until else None
    if args.since:
        return datetime.fromisoformat(args.since).replace(tzinfo=UTC), until
    if args.days and args.days > 0:
        return datetime.now(UTC) - timedelta(days=args.days), until
    return None, until


# --------------------------------------------------------------------------------------------------------------------
# Aggregation
# --------------------------------------------------------------------------------------------------------------------
def _fmt_hours(seconds: float) -> str:
    return f"{seconds / 3600:.1f}h"


def _fmt_int(value: int | float) -> str:
    return f"{int(value):,}"


def _pct(numerator: float, denominator: float) -> str:
    return f"{100 * numerator / denominator:.0f}%" if denominator else "n/a"


def _normalize_error(text: str) -> str:
    text = re.sub(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", "<uuid>", text)
    text = re.sub(r"/[^\s'\"]+", "<path>", text)
    text = re.sub(r"\d+", "<n>", text)
    return _one_line(text, 110)


def _local_date(ts: datetime, tz: timezone) -> str:
    return ts.astimezone(tz).strftime("%Y-%m-%d")


class Evidence:
    """Counter that also remembers a few example sessions per key."""

    def __init__(self) -> None:
        self.counts: Counter[str] = Counter()
        self.examples: dict[str, list[str]] = defaultdict(list)

    def add(self, key: str, session: Session) -> None:
        self.counts[key] += 1
        if session.short_id not in self.examples[key] and len(self.examples[key]) < EXAMPLE_SESSIONS:
            self.examples[key].append(session.short_id)

    def top(self, n: int) -> list[dict[str, Any]]:
        return [{"key": k, "count": c, "sessions": self.examples[k]} for k, c in self.counts.most_common(n)]


def aggregate(sessions: list[Session]) -> dict[str, Any]:
    """Compute the cross-session summary used by both the digest and summary.json."""
    users = [s for s in sessions if s.kind == "user"]
    subagents = [s for s in sessions if s.kind == "subagent"]
    tz = next((s.tz for s in users), UTC)

    by_workspace: dict[str, Counter[str]] = defaultdict(Counter)
    tools: Counter[str] = Counter()
    commands: Counter[str] = Counter()
    slash: Counter[str] = Counter()
    skills: Counter[str] = Counter()
    errors, failed_cmds, sandbox_targets, repeated, retried = (Evidence() for _ in range(5))
    api_codes: Counter[str] = Counter()
    days: set[str] = set()
    for s in users:
        days.add(_local_date(s.started or s.ended or datetime.now(UTC), tz))
        for m in s.user_messages:
            slash.update(m.slash_commands)
            skills.update(m.skills)
        by_workspace[s.workspace()].update(
            sessions=1,
            user_messages=len(s.user_messages),
            tool_calls=len(s.tool_calls),
            tokens=s.input_tokens + s.output_tokens,
            friction=s.friction_score,
            active_seconds=int(s.active_seconds),
            corrections=len(s.corrections),
        )
        tools.update(c.name for c in s.tool_calls)
        commands.update(c.command_key for c in s.tool_calls if c.command_key)
        for r in s.tool_errors:
            errors.add(_normalize_error(r.error or ""), s)
        for r in s.failed_commands:
            if r.call and r.call.command_key:
                failed_cmds.add(r.call.command_key, s)
        for r in s.sandbox_blocked:
            sandbox_targets.add(r.label, s)
        for key in s.repeated_failures:
            repeated.add(key, s)
        for tool, n in s.retry_tools.items():
            for _ in range(n):
                retried.add(tool, s)
        for err in s.api_errors:
            match = API_ERROR_CODE_RE.search(err)
            api_codes[match.group(1) if match else _normalize_error(re.sub(r"\(attempt \d+\):?", "", err))[:60]] += 1

    total_tool_calls = sum(len(s.tool_calls) for s in users)
    total_user_msgs = sum(len(s.user_messages) for s in users)
    total_commands = sum(1 for s in users for c in s.tool_calls if c.command_key)
    total_input = sum(s.input_tokens for s in users)
    total_cache = sum(s.cache_read_tokens for s in users)
    friction_totals = {
        "corrections": sum(len(s.corrections) for s in users),
        "rapid_followups": sum(s.rapid_followups for s in users),
        "retries": sum(s.retries for s in users),
        "polls": sum(s.polls for s in users),
        "failed_commands": sum(len(s.failed_commands) for s in users),
        "tool_errors": sum(len(s.tool_errors) for s in users),
        "sandbox_blocks": sum(len(s.sandbox_blocked) for s in users),
        "compactions": sum(s.compactions for s in users),
        "api_errors": sum(len(s.api_errors) for s in users),
        "unfinished_sessions": sum(1 for s in users if s.outcome != "completed turn"),
    }
    ordered_days = sorted(days)
    return {
        "generated_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "timezone": str(tz),
        "coverage": {
            "sessions": len(users),
            "subagent_sessions": len(subagents),
            "first_day": ordered_days[0] if ordered_days else None,
            "last_day": ordered_days[-1] if ordered_days else None,
            "active_days": len(ordered_days),
        },
        "totals": {
            "user_messages": total_user_msgs,
            "agent_turns": sum(s.agent_turns for s in users),
            "tool_calls": total_tool_calls,
            "commands": total_commands,
            "active_seconds": int(sum(s.active_seconds for s in users)),
            "input_tokens": total_input,
            "output_tokens": sum(s.output_tokens for s in users),
            "cache_read_tokens": total_cache,
            "cache_ratio": round(total_cache / (total_input + total_cache), 3) if total_input + total_cache else None,
            "subagent_input_tokens": sum(s.input_tokens + s.cache_read_tokens for s in subagents),
            "subagent_output_tokens": sum(s.output_tokens for s in subagents),
            "files_edited": len({p for s in users for p in s.files_edited}),
            "commits": sum(s.commits for s in users),
            "median_session_minutes": round(statistics.median(s.active_seconds for s in users) / 60, 1) if users else 0,
            "median_user_messages": statistics.median(len(s.user_messages) for s in users) if users else 0,
            "max_autonomous_streak": max((s.max_streak for s in users), default=0),
        },
        "friction": friction_totals,
        "friction_rates": {
            "corrections_per_100_user_msgs": _rate(friction_totals["corrections"], total_user_msgs, 100),
            "rapid_followups_pct": _rate(friction_totals["rapid_followups"], total_user_msgs, 100),
            "failed_commands_pct": _rate(friction_totals["failed_commands"], total_commands, 100),
            "tool_errors_per_100_calls": _rate(friction_totals["tool_errors"], total_tool_calls, 100),
            "retries_per_100_calls": _rate(friction_totals["retries"], total_tool_calls, 100),
            "sandbox_blocks_per_session": _rate(friction_totals["sandbox_blocks"], len(users), 1, 2),
            "polls_per_session": _rate(friction_totals["polls"], len(users), 1, 2),
            "compactions_per_session": _rate(friction_totals["compactions"], len(users), 1, 2),
            "unfinished_sessions_pct": _rate(friction_totals["unfinished_sessions"], len(users), 100),
        },
        "by_workspace": {w: dict(c) for w, c in sorted(by_workspace.items(), key=lambda kv: -kv[1]["friction"])},
        "tools": dict(tools.most_common(20)),
        "commands": dict(commands.most_common(25)),
        "slash_commands": dict(slash.most_common()),
        "skills": dict(skills.most_common()),
        "top_errors": errors.top(15),
        "top_failed_commands": failed_cmds.top(15),
        "repeated_failures": repeated.top(10),
        "retries_by_tool": retried.top(10),
        "sandbox_targets": sandbox_targets.top(10),
        "api_error_codes": dict(api_codes.most_common(10)),
    }


def _rate(numerator: float, denominator: float, scale: float, digits: int = 1) -> float:
    return round(scale * numerator / denominator, digits) if denominator else 0.0


def session_record(s: Session) -> dict[str, Any]:
    """Compact per-session record for summary.json and ranking tables."""
    return {
        "conv_id": s.conv_id,
        "brain": s.brain,
        "kind": s.kind,
        "parent_id": s.parent_id,
        "date": _local_date(s.started, s.tz) if s.started else None,
        "start_local": s.started.astimezone(s.tz).strftime("%Y-%m-%d %H:%M") if s.started else None,
        "workspace": s.workspace(),
        "title": _redact(s.title),
        "user_messages": len(s.user_messages),
        "agent_turns": s.agent_turns,
        "tool_calls": len(s.tool_calls),
        "active_minutes": round(s.active_seconds / 60, 1),
        "input_tokens": s.input_tokens,
        "output_tokens": s.output_tokens,
        "cache_read_tokens": s.cache_read_tokens,
        "files_edited": len(s.files_edited),
        "commits": s.commits,
        "slash_commands": sorted({c for m in s.user_messages for c in m.slash_commands}),
        "friction_score": s.friction_score,
        "friction": {
            "corrections": len(s.corrections),
            "rapid_followups": s.rapid_followups,
            "retries": s.retries,
            "polls": s.polls,
            "failed_commands": len(s.failed_commands),
            "tool_errors": len(s.tool_errors),
            "sandbox_blocks": len(s.sandbox_blocked),
            "compactions": s.compactions,
            "api_errors": len(s.api_errors),
        },
        "repeated_failures": dict(s.repeated_failures),
        "max_autonomous_streak": s.max_streak,
        "outcome": s.outcome,
    }


# --------------------------------------------------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------------------------------------------------
def _table(headers: list[str], rows: list[list[Any]]) -> str:
    if not rows:
        return "_none_\n"
    lines = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    lines += ["| " + " | ".join(str(c).replace("|", "\\|") for c in row) + " |" for row in rows]
    return "\n".join(lines) + "\n"


def _evidence_rows(items: list[dict[str, Any]]) -> list[list[Any]]:
    return [[item["key"], item["count"], ", ".join(f"`{x}`" for x in item["sessions"])] for item in items]


def render_digest(
    summary: dict[str, Any], sessions: list[Session], args: argparse.Namespace, deltas: dict[str, Any]
) -> str:
    """Render the Markdown evidence digest consumed by the agent."""
    users = [s for s in sessions if s.kind == "user"]
    cov, tot, fr, rates = summary["coverage"], summary["totals"], summary["friction"], summary["friction_rates"]
    out: list[str] = []
    counter = iter(range(1, 20))

    def heading(title: str) -> str:
        return f"\n## {next(counter)}. {title}\n"

    window = f"last {args.days} days" if args.days and not args.since else f"since {args.since or 'the beginning'}"
    out.append(f"# improve-agy evidence digest ({window})\n")
    out.append(
        f"Generated {summary['generated_at']} · timezone {summary['timezone']} · brains: "
        f"{', '.join(_tilde(b) for b in args.brain)}\n"
    )
    out.append(
        f"Coverage: **{cov['sessions']} user sessions** ({cov['subagent_sessions']} subagent/worker sessions "
        f"{'included' if args.include_subagents else 'excluded from stats, counted in cost'}), "
        f"{cov['first_day']} → {cov['last_day']}, {cov['active_days']} active days.\n"
    )

    out.append(heading("At a glance"))
    out.append(
        _table(
            ["Metric", "Value"],
            [
                [
                    "Sessions / user messages / agent turns",
                    f"{cov['sessions']} / {tot['user_messages']} / {tot['agent_turns']}",
                ],
                ["Tool calls (shell commands)", f"{_fmt_int(tot['tool_calls'])} ({_fmt_int(tot['commands'])})"],
                ["Active time", _fmt_hours(tot["active_seconds"])],
                [
                    "Median session (active min / user msgs)",
                    f"{tot['median_session_minutes']} / {tot['median_user_messages']}",
                ],
                [
                    "Tokens in / out / cache-read (cache hit)",
                    f"{_fmt_int(tot['input_tokens'])} / {_fmt_int(tot['output_tokens'])} / "
                    f"{_fmt_int(tot['cache_read_tokens'])} "
                    f"({_pct(tot['cache_read_tokens'], tot['input_tokens'] + tot['cache_read_tokens'])})",
                ],
                [
                    "Subagent tokens in(+cache) / out",
                    f"{_fmt_int(tot['subagent_input_tokens'])} / {_fmt_int(tot['subagent_output_tokens'])}",
                ],
                ["Files edited / commits", f"{tot['files_edited']} / {tot['commits']}"],
                ["Longest autonomous streak (tool calls between user turns)", tot["max_autonomous_streak"]],
            ],
        )
    )

    out.append(heading("Friction signals"))
    out.append(
        _table(
            ["Signal", "Count", "Rate"],
            [
                ["User corrections", fr["corrections"], f"{rates['corrections_per_100_user_msgs']} per 100 user msgs"],
                [
                    "Rapid re-prompts (<90s, short)",
                    fr["rapid_followups"],
                    f"{rates['rapid_followups_pct']}% of user msgs",
                ],
                [
                    "Identical consecutive tool calls (retries)",
                    fr["retries"],
                    f"{rates['retries_per_100_calls']} per 100 calls",
                ],
                [
                    "Polling calls (manage_task/swarm_wait/read_board)",
                    fr["polls"],
                    f"{rates['polls_per_session']} per session",
                ],
                [
                    "Failed shell commands (exit != 0)",
                    fr["failed_commands"],
                    f"{rates['failed_commands_pct']}% of commands",
                ],
                ["Tool errors", fr["tool_errors"], f"{rates['tool_errors_per_100_calls']} per 100 calls"],
                [
                    "Sandbox / permission blocks",
                    fr["sandbox_blocks"],
                    f"{rates['sandbox_blocks_per_session']} per session",
                ],
                ["Context compactions", fr["compactions"], f"{rates['compactions_per_session']} per session"],
                ["API errors (429 etc.)", fr["api_errors"], ""],
                [
                    "Sessions not ending in a completed turn",
                    fr["unfinished_sessions"],
                    f"{rates['unfinished_sessions_pct']}%",
                ],
            ],
        )
    )

    out.append(heading("Evidence by cause"))
    out.append(
        "Tool errors (normalized):\n\n"
        + _table(["Error", "Count", "Example sessions"], _evidence_rows(summary["top_errors"]))
    )
    out.append(
        "\nFailing commands:\n\n"
        + _table(["Command", "Failures", "Example sessions"], _evidence_rows(summary["top_failed_commands"]))
    )
    out.append(
        "\nCommands failing ≥2× inside one session:\n\n"
        + _table(["Command", "Sessions", "Example sessions"], _evidence_rows(summary["repeated_failures"]))
    )
    out.append(
        "\nIdentical consecutive calls (retries) by tool:\n\n"
        + _table(["Tool", "Retries", "Example sessions"], _evidence_rows(summary["retries_by_tool"]))
    )
    out.append(
        "\nSandbox / permission blocks by target:\n\n"
        + _table(["Target", "Blocks", "Example sessions"], _evidence_rows(summary["sandbox_targets"]))
    )
    if summary["api_error_codes"]:
        out.append(
            "\nAPI errors by code:\n\n"
            + _table(["Code", "Count"], [[c, n] for c, n in summary["api_error_codes"].items()])
        )

    out.append(heading("Correction excerpts (user turns that read as corrections)"))
    corrections = sorted(
        ((m, s) for s in users for m in s.corrections),
        key=lambda pair: (-pair[0].correction_score, pair[0].ts),
    )[: args.max_excerpts]
    out.append(
        _table(
            ["When", "Session", "Workspace", "Score", "User said"],
            [
                [
                    m.ts.astimezone(s.tz).strftime("%m-%d %H:%M"),
                    f"`{s.short_id}`",
                    s.workspace(),
                    m.correction_score,
                    _redact(_one_line(m.text, EXCERPT_CHARS)),
                ]
                for m, s in corrections
            ],
        )
    )

    out.append(heading("Highest-friction sessions (deep-dive candidates)"))
    ranked = [s for s in sorted(users, key=lambda s: -s.friction_score) if s.friction_score][:10]
    out.append(
        _table(
            ["Session", "Date", "Workspace", "Title", "Score", "Breakdown", "Outcome"],
            [
                [
                    f"`{s.short_id}`",
                    _local_date(s.started, s.tz) if s.started else "",
                    s.workspace(),
                    _redact(s.title),
                    s.friction_score,
                    f"corr {len(s.corrections)} · retry {s.retries} · fail {len(s.failed_commands)} · "
                    f"err {len(s.tool_errors)} · sbx {len(s.sandbox_blocked)} · cmp {s.compactions} · poll {s.polls}",
                    s.outcome,
                ]
                for s in ranked
            ],
        )
    )

    out.append(heading("Context and cost pressure"))
    heavy = sorted(users, key=lambda s: -(s.input_tokens + s.output_tokens))[:8]
    out.append(
        _table(
            ["Session", "Date", "Title", "In", "Out", "Cache", "Compactions", "Turns", "Max streak"],
            [
                [
                    f"`{s.short_id}`",
                    _local_date(s.started, s.tz) if s.started else "",
                    _redact(s.title),
                    _fmt_int(s.input_tokens),
                    _fmt_int(s.output_tokens),
                    _fmt_int(s.cache_read_tokens),
                    s.compactions,
                    s.agent_turns,
                    s.max_streak,
                ]
                for s in heavy
            ],
        )
    )

    out.append(heading("Where the work happens (for placing rules)"))
    out.append(
        _table(
            ["Workspace", "Sessions", "User msgs", "Tool calls", "Active", "Corrections", "Friction"],
            [
                [
                    w,
                    c.get("sessions", 0),
                    c.get("user_messages", 0),
                    c.get("tool_calls", 0),
                    _fmt_hours(c.get("active_seconds", 0)),
                    c.get("corrections", 0),
                    c.get("friction", 0),
                ]
                for w, c in list(summary["by_workspace"].items())[:12]
            ],
        )
    )
    out.append("\nTools:\n\n" + _table(["Tool", "Calls"], [[t, n] for t, n in list(summary["tools"].items())[:12]]))
    out.append(
        "\nShell commands:\n\n"
        + _table(["Command", "Runs"], [[c, n] for c, n in list(summary["commands"].items())[:15]])
    )
    slash_rows = [[c, n] for c, n in list(summary["slash_commands"].items())[:12]]
    slash_names = {c.lstrip("/") for c in summary["slash_commands"]}
    slash_rows += [[f"skill {k}", n] for k, n in summary["skills"].items() if k not in slash_names][:8]
    out.append("\nSlash commands / user-invoked skills:\n\n" + _table(["Invocation", "Uses"], slash_rows))

    out.append(heading("Judged evidence (review cards)"))
    if summary.get("cards"):
        import review_cards  # local sibling module; imported lazily to avoid a cycle

        out.append(review_cards.render_sections(summary["cards"]))
    else:
        out.append(
            "No review cards yet. Run `review_cards.py packets`, label them (run_workflow fan-out or "
            "`review_cards.py label`), then `review_cards.py ingest` and re-run this report.\n"
        )

    out.append(heading("Since last run"))
    if deltas.get("metrics"):
        out.append(f"Previous snapshot: {deltas['previous_generated_at']} (same window length).\n")
        out.append(
            _table(
                ["Metric", "Previous", "Now", "Δ"],
                [[k, v["previous"], v["now"], v["delta"]] for k, v in deltas["metrics"].items()],
            )
        )
    else:
        out.append(
            deltas.get("note", "No earlier snapshot with this window length; trends start with the next run.") + "\n"
        )

    out.append(heading("Action items recorded by previous runs"))
    out.append(_actions_tail() or f"None yet (file: {_tilde(ACTIONS_FILE)}).\n")
    out.append("")
    return "\n".join(out)


def _actions_tail(max_lines: int = 60) -> str:
    """Return the most recent lines of the persisted action list, if any."""
    if not ACTIONS_FILE.is_file():
        return ""
    lines = ACTIONS_FILE.read_text(encoding="utf-8").splitlines()
    tail = lines[-max_lines:]
    prefix = f"_(showing last {max_lines} of {len(lines)} lines)_\n\n" if len(lines) > max_lines else ""
    return prefix + "\n".join(tail) + "\n"


def render_session(sessions: list[Session], args: argparse.Namespace) -> str:
    """Render a deep-dive digest for one conversation: user turns, every failure with its output tail, files."""
    matches = [s for s in sessions if s.conv_id.startswith(args.conv_id)]
    if not matches:
        return f"No session matching '{args.conv_id}' in the selected window (try --days 0).\n"
    s = matches[0]
    out = [f"# Session {s.conv_id} ({s.brain})\n", "```json", json.dumps(session_record(s), indent=2), "```\n"]
    out.append("## User turns\n")
    for m in s.user_messages:
        flag = " **[correction]**" if m.correction_score >= 2 else (" _[rapid]_" if m.rapid_followup else "")
        out.append(
            f"- step {m.step} {m.ts.astimezone(s.tz).strftime('%H:%M')}{flag}: {_redact(_one_line(m.text, 300))}"
        )
    out.append("\n## Failed commands, tool errors and sandbox blocks (chronological)\n")
    failures = {r.step: r for r in s.failed_commands + s.tool_errors + s.sandbox_blocked}
    for step in sorted(failures):
        r = failures[step]
        detail = f"exit={r.exit_code}" if r.exit_code is not None else ""
        detail += f" error={_redact(_one_line(r.error, 160))}" if r.error else ""
        detail += " [sandbox]" if r.sandbox_block else ""
        out.append(f"- step {step}: {detail.strip() or '-'} ← `{_redact(_one_line(r.target, 160))}`")
        if r.excerpt:
            out.append(f"  - output: {r.excerpt}")
    if not failures:
        out.append("_none_")
    if s.api_errors:
        out.append("\n## API errors\n")
        out += [f"- {_one_line(e, 160)}" for e in s.api_errors[:10]]
    out.append("\n## Files edited\n")
    out += [f"- {_tilde(p)}" for p in sorted(s.files_edited)[:40]] or ["_none_"]
    out.append("\n## Final reply\n")
    out.append(_redact(_one_line(s.final_reply, 600)) or "_none_")
    out.append("")
    return "\n".join(out)


# --------------------------------------------------------------------------------------------------------------------
# Snapshots
# --------------------------------------------------------------------------------------------------------------------
TRACKED_METRICS = {
    "sessions": ("coverage", "sessions"),
    "user_messages": ("totals", "user_messages"),
    "tool_calls": ("totals", "tool_calls"),
    "output_tokens": ("totals", "output_tokens"),
    "cache_ratio": ("totals", "cache_ratio"),
    "corrections_per_100_user_msgs": ("friction_rates", "corrections_per_100_user_msgs"),
    "rapid_followups_pct": ("friction_rates", "rapid_followups_pct"),
    "failed_commands_pct": ("friction_rates", "failed_commands_pct"),
    "tool_errors_per_100_calls": ("friction_rates", "tool_errors_per_100_calls"),
    "retries_per_100_calls": ("friction_rates", "retries_per_100_calls"),
    "sandbox_blocks_per_session": ("friction_rates", "sandbox_blocks_per_session"),
    "polls_per_session": ("friction_rates", "polls_per_session"),
    "compactions_per_session": ("friction_rates", "compactions_per_session"),
    "unfinished_sessions_pct": ("friction_rates", "unfinished_sessions_pct"),
}


def save_snapshot(summary: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    """Persist this run's summary and compute deltas against the previous snapshot with the same window.

    Snapshots are only comparable when they cover the same population, so filtered runs (``--workspace``,
    ``--since``/``--until``, ``--include-subagents``, custom ``--brain``) neither write nor read a baseline.
    """
    filters = [
        name
        for name, active in (
            ("--workspace", args.workspace),
            ("--since/--until", args.since or args.until),
            ("--include-subagents", args.include_subagents),
            ("--brain", args.brain_overridden),
        )
        if active
    ]
    if filters:
        return {
            "note": f"Snapshot skipped: {', '.join(filters)} changes the population; deltas need an unfiltered run."
        }
    snap_dir = STATE_DIR / "snapshots"
    snap_dir.mkdir(parents=True, exist_ok=True)
    tag = f"d{args.days}"
    previous = sorted(snap_dir.glob(f"*-{tag}.json"))
    stamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    (snap_dir / f"{stamp}-{tag}.json").write_text(json.dumps(summary, indent=1, default=str), encoding="utf-8")
    if not previous:
        return {}
    try:
        old = json.loads(previous[-1].read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    metrics: dict[str, Any] = {}
    for name, (section, key) in TRACKED_METRICS.items():
        before, now = old.get(section, {}).get(key), summary.get(section, {}).get(key)
        numeric = isinstance(before, int | float) and isinstance(now, int | float)
        metrics[name] = {"previous": before, "now": now, "delta": round(now - before, 3) if numeric else "n/a"}
    return {"previous_generated_at": old.get("generated_at"), "metrics": metrics}


# --------------------------------------------------------------------------------------------------------------------
# Action-item ledger
# --------------------------------------------------------------------------------------------------------------------
def actions_command(args: argparse.Namespace) -> str:
    """Append, list, or check off action items in ``~/.gemini/improve-agy/actions.md``."""
    ACTIONS_FILE.parent.mkdir(parents=True, exist_ok=True)
    lines = ACTIONS_FILE.read_text(encoding="utf-8").splitlines() if ACTIONS_FILE.is_file() else []
    if args.verb == "add":
        text = " ".join(args.words).strip()
        if not text:
            return "nothing to add: pass the item text\n"
        line = f"- [ ] {datetime.now().strftime('%Y-%m-%d')} · {text}"
        lines.append(line)
        ACTIONS_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return f"recorded as item {sum(1 for ln in lines if ln.startswith('- ['))}: {line}\n"
    if args.verb == "done":
        items = [i for i, ln in enumerate(lines) if ln.startswith("- [")]
        number = int(args.words[0]) if args.words and args.words[0].isdigit() else 0
        if not 1 <= number <= len(items):
            return f"usage: actions done <n> [note]; {len(items)} items recorded\n"
        idx = items[number - 1]
        note = " ".join(args.words[1:]).strip()
        lines[idx] = lines[idx].replace("- [ ]", "- [x]", 1) + (f" · {note}" if note else "")
        ACTIONS_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return f"checked off item {number}: {lines[idx]}\n"
    numbered = [f"{n}. {ln}" for n, ln in enumerate((ln for ln in lines if ln.startswith("- [")), start=1)]
    return ("\n".join(numbered) + "\n") if numbered else f"no action items recorded yet ({_tilde(ACTIONS_FILE)})\n"


# --------------------------------------------------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    """Build the argparse CLI."""
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--days", type=int, default=None, help="look-back window in days (0 = all time; default 30)")
    common.add_argument("--since", help="start date YYYY-MM-DD (overrides --days)")
    common.add_argument("--until", help="end date YYYY-MM-DD (inclusive)")
    common.add_argument("--brain", type=Path, action="append", help="brain directory to scan (repeatable)")
    common.add_argument("--workspace", help="only sessions whose inferred workspace contains this text")
    common.add_argument(
        "--include-subagents", action="store_true", help="treat subagent/worker conversations as sessions"
    )
    common.add_argument(
        "--out-dir", type=Path, default=STATE_DIR / "out", help="where digest.md / summary.json are written"
    )
    common.add_argument("--max-excerpts", type=int, default=20, help="max correction excerpts in the digest")
    common.add_argument("-v", "--verbose", action="store_true")

    sub = parser.add_subparsers(dest="mode")
    report = sub.add_parser("report", parents=[common], help="evidence digest (default; options go after the mode)")
    report.add_argument("--no-snapshot", action="store_true", help="skip writing a snapshot / trend deltas")
    report.add_argument("--json", action="store_true", help="print summary.json to stdout instead of the digest")
    session = sub.add_parser("session", parents=[common], help="deep dive into one conversation (all time by default)")
    session.add_argument("conv_id", help="conversation id or unique prefix")
    actions = sub.add_parser("actions", help="record or check off action items in the ledger")
    actions.add_argument("verb", choices=["add", "list", "done"])
    actions.add_argument("words", nargs="*", help="'add': item text; 'done': item number then an optional note")
    return parser


def _cards_summary(sessions: list[Session]) -> dict[str, Any] | None:
    """Aggregate cached review cards when the sibling module is available; never fails the report."""
    try:
        import review_cards  # local sibling module; imported lazily to avoid a cycle
    except ImportError:
        return None
    try:
        return review_cards.summarize_cards(sessions)
    except (OSError, KeyError, ValueError) as exc:  # a malformed cached card must not break the digest
        logger.warning("review cards skipped: %s", exc)
        return None


def main(argv: list[str] | None = None) -> int:
    """Entry point."""
    parser = build_parser()
    raw = list(sys.argv[1:] if argv is None else argv)
    if not raw or (raw[0].startswith("-") and raw[0] not in ("-h", "--help")):
        raw.insert(0, "report")  # bare options mean 'report'; use -h for the mode list
    args = parser.parse_args(raw)
    if args.mode == "actions":
        sys.stdout.write(actions_command(args))
        return 0
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.WARNING, format="%(levelname)s %(message)s")
    if args.days is None:
        args.days = 0 if args.mode == "session" else 30  # per-mode defaults; parents=[common] share one Action
    args.brain_overridden = bool(args.brain)
    args.brain = args.brain or [b for b in DEFAULT_BRAINS if b.is_dir()] or list(DEFAULT_BRAINS)

    sessions = load_sessions(args)
    if args.mode == "session":
        sys.stdout.write(render_session(sessions, args))
        return 0
    summary = aggregate(sessions)
    summary["sessions"] = [session_record(s) for s in sessions]
    summary["cards"] = _cards_summary(sessions)
    deltas = {"note": "Snapshot skipped (--no-snapshot)."} if args.no_snapshot else save_snapshot(summary, args)
    digest = render_digest(summary, sessions, args, deltas)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir / "summary.json").write_text(json.dumps(summary, indent=1, default=str), encoding="utf-8")
    (args.out_dir / "digest.md").write_text(digest, encoding="utf-8")
    text = json.dumps(summary, indent=2, default=str) if args.json else digest
    sys.stdout.write(text + f"\n\n_written: {args.out_dir / 'digest.md'} and {args.out_dir / 'summary.json'}_\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
