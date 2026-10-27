#!/usr/bin/env python3
"""Turn a copyurl log into a success rate plus a failure-mode histogram.

Why this exists: reliability on every platform is bimodal, not random. Failures
arrive in clusters (whole days at 0%, clean days in between), so "it broke
today" is a different question from "what is the rate". This reads the log the
scripts already write and answers both.

Handles both log formats, because the two scripts write different lines:

  Linux (copyurl.sh)   2026-10-22 19:55:59 ERROR: URL copy failed. ...
  Windows (copy.ahk)   2026-10-22 19:55:59 t=1234567 | Copy attempt 1 ... timed out (beacon=none).

A "session" is one hotkey press and everything logged until the next press.
Each session is classified independently, because the failure mode belongs to
the press, not to the line.

Usage:
  scripts/analyze_log.py                       # ~/.local/state/copyurl/copyurl_log.txt
  scripts/analyze_log.py path/to/copyurl_log.txt
  scripts/analyze_log.py copyurl_log.txt.1 copyurl_log.txt   # include rotated logs
  scripts/analyze_log.py --json                # machine-readable
  scripts/analyze_log.py --since 2026-10-01    # ignore older sessions
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter, OrderedDict
from datetime import datetime

DEFAULT_LOG = os.path.expanduser("~/.local/state/copyurl/copyurl_log.txt")

# A press starts a session. Both platforms log one distinct line at handler
# entry, and nothing else does:
#   Linux    "Alt+A fired (target=gemini, version=v9 ...)"
#   Windows  "--- Alt+A pressed ---" / "--- Alt+Z (Aside) pressed ---"
# The Aside variant has a parenthetical between the chord and "pressed", so it
# must be optional -- requiring them adjacent silently dropped every Alt+Z press.
PRESS_RE = re.compile(r"Alt\+[AZ]\s*(?:\([^)]*\)\s*)?(?:fired|pressed)", re.I)
TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})")
# Every "the flow finished" line across both platforms, verbatim from the
# scripts: Linux "done; sent ...", Windows "Sent to Gemini.", "Sent to Aside
# side panel.", "Sent Netflix sentence to Aside side panel.", "Copy attempt N
# on X succeeded." The Netflix variant does not read "Sent to", so a
# "Sent to ..." pattern alone silently reported it as no-outcome.
SUCCESS_RE = re.compile(
    r"done; sent|\bSent\b.*\b(?:Gemini|Aside)\b|succeeded", re.I
)
FAILURE_RE = re.compile(r"ERROR: URL copy failed|Copy failed|gave up after|fast-failed", re.I)
# "The flow finished but the summary was not delivered": Windows logs these when
# the desktop/PWA/Aside UIA helper couldn't send, and logs "left URL on
# clipboard" when no Gemini target existed. These are failures to a user even
# though the copy leg already logged "succeeded", so they must mask that.
SEND_FAILURE_RE = re.compile(
    r"send failed|helper failed|left URL on clipboard|did not confirm a fresh chat",
    re.I,
)

# Failure-mode classification, most specific first. Each pattern maps to a short
# label; the first match wins so a line cannot be counted twice.
MODES = OrderedDict(
    [
        # Linux v9 diagnosis lines: the exact leg that failed. (Distinct label
        # from Windows' "beacon=none" -- a duplicated dict key would silently
        # overwrite the earlier entry and misclassify every such failure.)
        ("extension-silent", re.compile(r"no extension trace written", re.I)),
        ("stale-content-script", re.compile(r"no trigger was recorded for this press", re.I)),
        ("no-hover", re.compile(r"NO VIDEO UNDER THE CURSOR", re.I)),
        ("unfocused", re.compile(r"page did not have focus|lost focus", re.I)),
        # Matches the first diagnosis line, not the follow-up explanation, so a
        # future reword of the explanation cannot silently unclassify it.
        ("clipboard-write-failed", re.compile(r"DID have a hovered video", re.I)),
        # Windows beacon states (extension reports what it did).
        ("beacon-null", re.compile(r"beacon=null", re.I)),
        ("beacon-execfail", re.compile(r"beacon=execfail", re.I)),
        ("beacon-asyncfail", re.compile(r"beacon=asyncfail", re.I)),
        # Shared / fallback signals.
        ("activation-failed", re.compile(r"could not activate|WinWaitActive timed out", re.I)),
        ("beacon-none", re.compile(r"beacon=none", re.I)),
        ("timeout", re.compile(r"timed out", re.I)),
    ]
)


def classify_session(lines: list[str]) -> str | None:
    """Return the failure mode for a failed session, or None if it succeeded."""
    body = "\n".join(lines)
    # A send/paste failure must beat a copy-leg "succeeded": one Windows line is
    # "Copy attempt 1 on X succeeded." and another is "Gemini desktop send
    # failed: ...", so SUCCESS_RE matches the copy leg while the flow never
    # delivered the summary. Without this check such a session reads as a
    # success and silently inflates the rate.
    if SEND_FAILURE_RE.search(body):
        return "send-failed"
    if SUCCESS_RE.search(body):
        return None
    if not FAILURE_RE.search(body):
        # A press with no outcome line at all (script killed, machine slept).
        return "no-outcome"
    for label, pat in MODES.items():
        if pat.search(body):
            return label
    return "unclassified"


def parse(path: str, since: str | None = None):
    sessions: list[dict] = []
    cur: dict | None = None
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            m = TS_RE.match(line)
            day = m.group(1) if m else None
            if PRESS_RE.search(line) and not line.lstrip().startswith(("[v]",)):
                if cur:
                    sessions.append(cur)
                cur = {"day": day, "lines": [line]}
                continue
            if cur is not None:
                cur["lines"].append(line)
    if cur:
        sessions.append(cur)

    rows = []
    for s in sessions:
        if since and s["day"] and s["day"] < since:
            continue
        mode = classify_session(s["lines"])
        rows.append({"day": s["day"], "ok": mode is None, "mode": mode})
    return rows


def summarize(rows: list[dict]) -> dict:
    total = len(rows)
    ok = sum(1 for r in rows if r["ok"])
    modes = Counter(r["mode"] for r in rows if not r["ok"])

    per_day: dict[str, dict[str, int]] = {}
    for r in rows:
        d = r["day"] or "unknown"
        slot = per_day.setdefault(d, {"total": 0, "ok": 0, "fail": 0})
        slot["total"] += 1
        slot["ok" if r["ok"] else "fail"] += 1

    return {
        "total": total,
        "ok": ok,
        "fail": total - ok,
        "rate": (100.0 * ok / total) if total else 0.0,
        "modes": dict(modes.most_common()),
        "per_day": dict(sorted(per_day.items())),
    }


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument(
        "log",
        nargs="*",
        default=[DEFAULT_LOG],
        help="log file(s); rotation moves the old one to <log>.1, and each file "
        "is parsed separately so a rotated log cannot merge with the current one",
    )
    ap.add_argument("--since", help="only sessions on/after this YYYY-MM-DD")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of a table")
    args = ap.parse_args(argv)

    missing = [p for p in args.log if not os.path.exists(p)]
    for p in missing:
        print(f"no log at {p}", file=sys.stderr)
    if len(missing) == len(args.log):
        return 2

    # Parse each file on its own: a session must never span the seam between a
    # rotated log and the current one, or the last press of the old file would
    # absorb the outcome lines of the first press in the new one.
    rows = []
    for p in args.log:
        if os.path.exists(p):
            rows.extend(parse(p, args.since))
    if not rows:
        print(f"no hotkey presses found in {' '.join(args.log)}", file=sys.stderr)
        return 2
    s = summarize(rows)

    if args.json:
        print(json.dumps(s, indent=2))
        return 0

    print("  ".join(args.log))
    print(f"  sessions: {s['total']}   ok: {s['ok']}   failed: {s['fail']}   rate: {s['rate']:.1f}%")
    if s["modes"]:
        print("\n  failure modes:")
        width = max(len(m) for m in s["modes"])
        for mode, n in s["modes"].items():
            print(f"    {mode:<{width}}  {n:4d}  ({100.0 * n / s['fail']:5.1f}% of failures)")
    print("\n  per day (only days with a failure or <100%):")
    for day, c in s["per_day"].items():
        if c["fail"]:
            print(f"    {day}  {c['ok']:3d}/{c['total']:<3d} ok  {c['fail']:3d} failed")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        # `analyze_log.py | head` closes the pipe early; that is not an error.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        sys.exit(0)
