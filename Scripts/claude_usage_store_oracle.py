#!/usr/bin/env python3
"""Independent count over Claude transcripts, compared against the usage store.

Deliberately does not use any CodexBar code or output: it re-reads the transcripts, redoes the
two reconciliation stages, and sums the tokens itself. The store is only queried for its own
SUM()s and for the set of transcript paths it claims to cover.

Usage: claude_store_oracle.py <sqlite-path> [root ...]
"""

import json
import os
import sqlite3
import sys
import unicodedata
from collections import defaultdict
from datetime import datetime, timezone


def day_key(iso_text):
    """Local-calendar day for an ISO-8601 instant, matching the store's `day` column."""
    text = iso_text.replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone().strftime("%Y-%m-%d")


def backend_of(obj, message):
    """Primary markers only; the recursive Vertex metadata walk is not reproduced here."""
    message_id = (message or {}).get("id")
    request_id = obj.get("requestId")
    model = (message or {}).get("model") or ""
    for value in (message_id, request_id):
        if isinstance(value, str) and "_vrtx_" in value:
            return "vertexAI"
    if model.startswith("claude-") and "@" in model:
        return "vertexAI"
    for value in (message_id, request_id):
        if isinstance(value, str) and "_bdrk_" in value:
            return "bedrock"
    if "anthropic.claude" in model.lower():
        return "bedrock"
    return "firstParty"


def sort_key(path):
    """NFC bytes, the one ordering authority the store's tie-break uses."""
    return unicodedata.normalize("NFC", path).encode("utf-8")


def parse_file(path):
    """Stage 1: collapse streaming chunks sharing messageId:requestId, last one wins."""
    keyed = {}
    unkeyed = []
    is_subagent = "/subagents/" in path
    with open(path, "rb") as handle:
        for raw in handle:
            if b'"type":"assistant"' not in raw or b'"usage"' not in raw:
                continue
            try:
                obj = json.loads(raw)
            except ValueError:
                continue
            if obj.get("type") != "assistant":
                continue
            message = obj.get("message")
            if not isinstance(message, dict):
                continue
            usage = message.get("usage")
            if not isinstance(usage, dict):
                continue
            timestamp = obj.get("timestamp")
            if not isinstance(timestamp, str):
                continue
            day = day_key(timestamp)
            if day is None:
                continue
            if not isinstance(message.get("model"), str):
                continue

            def count(name):
                value = usage.get(name)
                return max(0, int(value)) if isinstance(value, (int, float)) else 0

            row = {
                "day": day,
                "input": count("input_tokens"),
                "cache_create": count("cache_creation_input_tokens"),
                "cache_read": count("cache_read_input_tokens"),
                "output": count("output_tokens"),
                "backend": backend_of(obj, message),
                "sidechain": bool(obj.get("isSidechain")),
                "subagent": is_subagent,
                "path": path,
            }
            if row["input"] == 0 and row["cache_create"] == 0 and row["cache_read"] == 0 and row["output"] == 0:
                continue
            message_id = message.get("id")
            request_id = obj.get("requestId")
            if isinstance(message_id, str) and isinstance(request_id, str):
                keyed[(message_id, request_id)] = row
            else:
                unkeyed.append(row)
    return keyed, unkeyed


def reconcile(paths):
    """Stage 2: one winner per (backend, messageId, requestId) across files."""
    winners = {}
    rows = []
    for path in sorted(paths, key=sort_key):
        keyed, unkeyed = parse_file(path)
        rows.extend(unkeyed)
        for (message_id, request_id), row in keyed.items():
            key = (row["backend"], message_id, request_id)
            rank = (row["sidechain"], row["subagent"], sort_key(path))
            current = winners.get(key)
            if current is None or rank < current[0]:
                winners[key] = (rank, row)
    rows.extend(row for _, row in winners.values())
    return rows


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    database = sys.argv[1]
    roots = sys.argv[2:] or [os.path.expanduser("~/.claude/projects")]

    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    stored_paths = [row[0] for row in connection.execute("SELECT path FROM claude_source_files")]
    window = connection.execute(
        "SELECT MIN(day), MAX(day) FROM claude_usage_events").fetchone()
    print(f"store: {len(stored_paths)} transcripts, day window {window[0]}..{window[1]}")

    transcripts = []
    for root in roots:
        for directory, _, names in os.walk(root):
            transcripts.extend(
                os.path.join(directory, name) for name in names if name.endswith(".jsonl"))
    print(f"disk:  {len(transcripts)} transcripts under {', '.join(roots)}")

    rows = [row for row in reconcile(transcripts) if window[0] <= row["day"] <= window[1]]

    oracle_total = defaultdict(int)
    oracle_days = defaultdict(int)
    for row in rows:
        tokens = row["input"] + row["cache_read"] + row["cache_create"] + row["output"]
        oracle_total[row["backend"]] += tokens
        oracle_days[row["day"]] += tokens

    stored_total = defaultdict(int)
    stored_days = defaultdict(int)
    for backend, day, tokens in connection.execute(
        "SELECT backend, day, SUM(input + cache_read + cache_create + output) "
        "FROM claude_reconciled_events GROUP BY backend, day"
    ):
        stored_total[backend] += tokens
        stored_days[day] += tokens

    stored_rows = connection.execute(
        "SELECT COUNT(*) FROM claude_reconciled_events").fetchone()[0]

    print()
    print(f"rows   oracle={len(rows):>8}  store={stored_rows:>8}  "
          f"{'MATCH' if len(rows) == stored_rows else 'DIFFER'}")
    oracle_sum = sum(oracle_total.values())
    stored_sum = sum(stored_total.values())
    print(f"tokens oracle={oracle_sum:>8}  store={stored_sum:>8}  "
          f"{'MATCH' if oracle_sum == stored_sum else 'DIFFER'}")
    print()
    for backend in sorted(set(oracle_total) | set(stored_total)):
        mark = "MATCH" if oracle_total[backend] == stored_total[backend] else "DIFFER"
        print(f"  {backend:<12} oracle={oracle_total[backend]:>12}  "
              f"store={stored_total[backend]:>12}  {mark}")

    mismatched_days = sorted(
        day for day in set(oracle_days) | set(stored_days)
        if oracle_days[day] != stored_days[day])
    if mismatched_days:
        print(f"\ndays differing: {len(mismatched_days)}")
        for day in mismatched_days[:10]:
            print(f"  {day}: oracle={oracle_days[day]} store={stored_days[day]}")
    else:
        print(f"\nall {len(stored_days)} days match")

    return 0 if oracle_sum == stored_sum and len(rows) == stored_rows else 1


if __name__ == "__main__":
    raise SystemExit(main())
