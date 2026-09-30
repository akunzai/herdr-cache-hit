#!/usr/bin/env python3
"""Resolve a Codex pane without a native session ID; never read prompt bodies."""

import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


SESSION_ID = re.compile(r"^[A-Za-z0-9._-]+$")


def process_started(pid):
    if not isinstance(pid, int) or pid <= 0:
        return None
    result = subprocess.run(
        ["ps", "-o", "lstart=", "-p", str(pid)],
        env={**os.environ, "LC_ALL": "C"},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        universal_newlines=True, timeout=5, check=False,
    )
    try:
        return time.mktime(time.strptime(result.stdout.strip(), "%a %b %d %H:%M:%S %Y"))
    except ValueError:
        return None


def timestamp(value):
    if not isinstance(value, str):
        return None
    value = re.sub(r"([+-]\d{2}):(\d{2})$", r"\1\2", value.replace("Z", "+0000"))
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            return datetime.datetime.strptime(value, fmt).timestamp()
        except ValueError:
            pass
    return None


def usage_summary(path, started):
    """Read only usage rows, including totals for matching the pane title."""
    used = False
    totals = None
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            if '"token_usage_record"' not in line and '"token_count"' not in line:
                continue
            try:
                row = json.loads(line)
                payload = row.get("payload") or {}
                if row.get("type") == "token_usage_record":
                    usage = payload.get("usage")
                    cumulative = payload.get("thread_token_usage")
                elif row.get("type") == "event_msg" and payload.get("type") == "token_count":
                    usage = (payload.get("info") or {}).get("last_token_usage")
                    cumulative = (payload.get("info") or {}).get("total_token_usage")
                else:
                    continue
                at = timestamp(row.get("timestamp"))
                if isinstance(usage, dict) and isinstance(usage.get("input_tokens"), (int, float)) and at is not None and at >= started:
                    used = True
                if isinstance(cumulative, dict) and all(isinstance(cumulative.get(k), (int, float)) for k in ("input_tokens", "output_tokens")):
                    totals = cumulative
            except (ValueError, AttributeError, TypeError):
                continue
    return used, totals


def title_counters(title):
    match = re.search(r"\b([0-9]+(?:\.[0-9]+)?)([KkMm]?)\s+in\b.*?\b([0-9]+(?:\.[0-9]+)?)([KkMm]?)\s+out\b", title or "")
    if not match:
        return None
    result = []
    for number, suffix in ((match[1], match[2]), (match[3], match[4])):
        scale = {"": 1, "K": 1000, "M": 1000000}[suffix.upper()]
        decimals = len(number.split(".")[1]) if "." in number else 0
        result.append((float(number) * scale, scale / (10 ** decimals) if suffix else 0))
    return result


def resolve_session(sessions, cwd, pane_id, process, panes, started):
    processes = [p for p in process.get("foreground_processes", [])
                 if p.get("name") == "codex" or Path(p.get("argv0", "")).name == "codex"]
    if len(processes) != 1:
        return None
    argv = processes[0].get("argv") or []
    # Current Codex can put --no-daemon before its resume subcommand.
    argv = [arg for arg in argv if arg != "--no-daemon"]
    # An explicit resume ID is exact even when several panes share one directory.
    if len(argv) >= 3 and argv[1] == "resume" and SESSION_ID.fullmatch(argv[2]) and not argv[2].startswith("-"):
        return argv[2]
    if not cwd or started is None:
        return None
    cwd = os.path.realpath(cwd)
    peers = [p for p in panes if p.get("agent") == "codex" and p.get("pane_id") != pane_id
             and os.path.realpath(p.get("cwd") or p.get("foreground_cwd") or "/") == cwd]
    claimed = {(p.get("agent_session") or {}).get("value") for p in panes
               if p.get("pane_id") != pane_id and (p.get("agent_session") or {}).get("kind") == "id"}
    candidates = {}
    launched = {}
    for path in Path(sessions).rglob("*.jsonl"):
        try:
            # Old inactive rollouts cannot belong to this live process.
            if path.stat().st_mtime < started - 2:
                continue
            with path.open(encoding="utf-8") as handle:
                row = json.loads(handle.readline(1024 * 1024))
            meta = row.get("payload")
            if row.get("type") != "session_meta" or not isinstance(meta, dict):
                continue
            sid = meta.get("id")
            if not isinstance(sid, str) or not SESSION_ID.fullmatch(sid) or sid in claimed:
                continue
            if os.path.realpath(meta.get("cwd") or "/") != cwd:
                continue
            if meta.get("parent_thread_id") or meta.get("thread_source") == "subagent" or isinstance(meta.get("source"), dict):
                continue
            if meta.get("originator") != "codex-tui" and meta.get("source") != "cli":
                continue
            candidates[sid] = path
            created = timestamp(meta.get("timestamp"))
            if created is not None and abs(created - started) <= 5:
                launched[sid] = path
        except (OSError, ValueError, TypeError, AttributeError):
            continue
    summaries = {sid: usage_summary(path, started) for sid, path in candidates.items()}
    pane = next((p for p in panes if p.get("pane_id") == pane_id), {})
    counters = title_counters(pane.get("terminal_title_stripped") or pane.get("terminal_title"))
    if counters:
        matches = [sid for sid, (_, totals) in summaries.items() if totals and
                   all(abs(totals[key] - value) <= tolerance for key, (value, tolerance)
                       in zip(("input_tokens", "output_tokens"), counters))]
        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1:
            return None
    if len(launched) == 1:
        sid = next(iter(launched))
        if not peers and not summaries[sid][0]:
            used = [key for key, (used, _) in summaries.items() if used]
            if len(used) == 1:
                return used[0]
            if len(used) > 1:
                return None
        return sid
    # Interactive /resume can select an older thread without putting its ID in
    # argv. Accept a cwd match only with one pane and one active, unclaimed root.
    if not peers:
        used = [key for key, (used, _) in summaries.items() if used]
        if len(used) == 1:
            return used[0]
        if len(candidates) == 1:
            return next(iter(candidates))
    return None


def main():
    sessions, cwd, pane_id = sys.argv[1:]
    data = json.load(sys.stdin)
    process = data.get("process") or {}
    processes = [p for p in process.get("foreground_processes", []) if p.get("name") == "codex"
                 or Path(p.get("argv0", "")).name == "codex"]
    started = process_started(processes[0].get("pid")) if len(processes) == 1 else None
    sid = resolve_session(sessions, cwd, pane_id, process, data.get("panes") or [], started)
    if sid:
        print(sid)
        return 0
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        sys.exit(1)
