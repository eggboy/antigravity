"""run_workflow script: label improve-agy evidence packets with review cards, in parallel, on a light model.

Runs inside the run_workflow tool, which injects ``agent``, ``phase``, ``log``, ``call_tool`` and ``args`` and allows
top-level ``await`` (hence the ruff exemptions below). Every file it touches lives in the packets directory written
by ``review_cards.py packets`` (prompt.md, card.schema.json, index.json, <conv_id>.md), which sits in the
conversation's scratch directory where read_file/write_file need no approval.

Args (JSON object passed as ``Args``):
    packets_dir      directory produced by ``review_cards.py packets``
    cards_dir        where to write <conv_id>.json cards (then run ``review_cards.py ingest <cards_dir>``)
    model            agent tier: flash (default), flash_lite, pro, inherit
    max_concurrency  parallel agents (default 6)
    timeout_seconds  per-card time limit (default 300)
"""

# ruff: noqa: F821, F704

import json
import os

from advanced import parallel, with_timeout

packets_dir = args["packets_dir"]
cards_dir = args["cards_dir"]
model = args.get("model", "flash")
max_concurrency = int(args.get("max_concurrency", 6))
timeout_seconds = int(args.get("timeout_seconds", 300))


async def read_text(path):
    """Plain file read first; read_file tool (pre-authorized under brain/) as the fallback, with its header stripped."""
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError as exc:
        log(f"open() fallback to read_file for {os.path.basename(path)}: {exc}")
        return strip_read_header(await call_tool("read_file", Path=path))


def strip_read_header(text):
    """read_file output carries a header, numbered lines and a no-newline marker; recover the raw content."""
    body = []
    for line in text.splitlines():
        if (
            line.startswith(("Showing lines", "Created At:", "Completed At:"))
            or line.strip() == "(no newline at end of file)"
        ):
            continue
        if ": " in line and line.split(": ", 1)[0].strip().isdigit():
            body.append(line.split(": ", 1)[1])
        else:
            body.append(line)
    return "\n".join(body)


async def write_text(path, content):
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
    except OSError as exc:
        log(f"open() fallback to write_file for {os.path.basename(path)}: {exc}")
        await call_tool("write_file", Path=path, Content=content, Overwrite=True)


def card_file_is_current(path, source):
    """A staged card counts as done only when it came from the same transcript state."""
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh).get("source") == source
    except (OSError, ValueError, AttributeError):
        return False


phase("Load inputs")
prompt = await read_text(os.path.join(packets_dir, "prompt.md"))
schema = json.loads(await read_text(os.path.join(packets_dir, "card.schema.json")))
index = json.loads(await read_text(os.path.join(packets_dir, "index.json")))
os.makedirs(cards_dir, exist_ok=True)
todo = [
    p
    for p in index["packets"]
    if not card_file_is_current(os.path.join(cards_dir, p["conv_id"] + ".json"), p.get("source"))
]
log(f"{len(todo)} packet(s) to label on tier {model}, {max_concurrency} at a time, {timeout_seconds}s each")

phase("Label sessions")


async def label(packet):
    conv_id = packet["conv_id"]
    text = await read_text(os.path.join(packets_dir, packet["file"]))
    card = await with_timeout(
        agent(
            f"Review card for session {conv_id}\n\n{prompt}\n\nThe conv_id for this card is {conv_id}.\n\n"
            f"PACKET:\n{text}",
            schema=schema,
            role=f"card {conv_id[:8]}",
            model=model,
        ),
        timeout_seconds,
    )
    card["conv_id"] = conv_id
    payload = {"card": card, "model": model, "source": packet.get("source")}
    await write_text(os.path.join(cards_dir, conv_id + ".json"), json.dumps(payload, indent=1) + "\n")
    log(f"card {conv_id[:8]} written")
    return conv_id


results = await parallel(todo, label, max_concurrency=max_concurrency, return_exceptions=True)
done = [r for r in results if isinstance(r, str)]
failed = [(p["conv_id"][:8], repr(r)[:160]) for p, r in zip(todo, results, strict=True) if not isinstance(r, str)]
for conv_id, err in failed:
    log(f"failed {conv_id}: {err}")
log(f"labelled {len(done)}, failed {len(failed)}; next: review_cards.py ingest {cards_dir}")
print(json.dumps({"labelled": len(done), "failed": len(failed), "cards_dir": cards_dir}))
