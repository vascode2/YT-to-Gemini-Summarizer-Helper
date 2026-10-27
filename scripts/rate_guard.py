#!/usr/bin/env python3
"""Fail when the hotkey's measured success rate drops below a baseline.

`analyze_log.py` answers "what is the rate and why". This answers "has the rate
regressed". It reuses analyze_log's parse/classify so the two can never disagree
about what counts as success, and adds the one thing the analyzer does not do:
attribute each session to the browser the flow actually raised, then require a
per-target floor.

Why per-target: the field log is dominated by one failure mode that is specific
to a browser. Aside's split view keeps focus in a pane the trigger never
reaches, so Alt+A succeeding 95% of the time on the Gemini PWA coexists with
22% on Aside. A single blended rate hides that (and a regression in judging the
blend would look fine). Per-target floors keep each browser honest.

Baseline schema (tests/baseline.json):
    {
      "targets": {
        "aside":    {"min_rate": 80.0, "min_samples": 10},
        "pwa":      {"min_rate": 90.0, "min_samples": 10},
        "unknown":  {"min_rate": 80.0, "min_samples": 10}
      },
      "tolerance": 0.0
    }
A target is only checked once it has >= min_samples sessions, so a one-off press
to a rare browser cannot flake the guard. tolerance is subtracted from min_rate
so the floor can be loosened across environments without editing every target.

Determining the target: a session is "aside"/"pwa" when any of its lines shows
copyurl.sh activating that window class (Linux logs `activateByWmClass('...')`).
Windows logs neither, so its sessions classify as "unknown" and are held to the
"unknown" floor. This means the same file has no ambiguity: Linux carries the
class, Windows does not.

Usage:
    scripts/rate_guard.py LOG... [--baseline path] [--since YYYY-MM-DD]
Exit codes:
    0  all sampled targets are at/above their floor (or nothing to check)
    1  at least one target is below its floor
    2  no presses found / baseline unusable
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from analyze_log import parse, classify_session  # noqa: E402

DEFAULT_BASELINE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "tests", "baseline.json"
)

# A session's target, derived from the Linux activation lines. We match the
# browser the YouTube tab lives in (org.asidelinux.Browser), not the Gemini PWA
# class that appears later in a gemini flow, because it is the browser pane that
# decides whether the trigger keystroke reached the page.
def _target_from_lines(lines: list[str]) -> str:
    # Linux logs the window class it activates; Windows never does. The browser
    # (where the YouTube tab lives) is org.asidelinux.Browser on this setup.
    for line in lines:
        if "activateByWmClass('org.asidelinux.Browser')" in line:
            return "aside"
        if "activateByWmClass('chrome-" in line:
            # A Chrome-class window. In the gemini flow this is the Gemini PWA.
            return "pwa"
    return "unknown"


def parse_with_target(path: str, since: str | None = None):
    """Like analyze_log.parse, but each row also carries its target."""
    from analyze_log import PRESS_RE, TS_RE  # local re-import of the session split

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
        rows.append(
            {
                "day": s["day"],
                "ok": mode is None,
                "mode": mode,
                "target": _target_from_lines(s["lines"]),
            }
        )
    return rows


def rate_for(rows: list[dict], target: str) -> tuple[int, int, float]:
    """Return (ok, total, rate_pct) for one target, (0,0,0.0) if unmeasured."""
    sub = [r for r in rows if r["target"] == target]
    if not sub:
        return 0, 0, 0.0
    ok = sum(1 for r in sub if r["ok"])
    return ok, len(sub), 100.0 * ok / len(sub)


def evaluate(
    rows: list[dict], baseline: dict, target: str
) -> tuple[bool, str]:
    """Return (passed, detail) for one target against the baseline."""
    spec = baseline["targets"].get(target)
    tol = baseline.get("tolerance", 0.0)
    ok, total, rate = rate_for(rows, target)
    if spec is None:
        return True, f"{target}: {ok}/{total} ({rate:.1f}%) — not in baseline, unchecked"
    if total < spec.get("min_samples", 0):
        return (
            True,
            f"{target}: {ok}/{total} ({rate:.1f}%) — below min_samples "
            f"{spec['min_samples']}, unchecked",
        )
    floor = spec["min_rate"] - tol
    passed = rate >= floor
    verdict = "PASS" if passed else "FAIL"
    return (
        passed,
        f"{verdict}  {target}: {ok}/{total} ({rate:.1f}%) vs floor {floor:.1f}%",
    )


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument(
        "log", nargs="*", help="log file(s); pass the rotated .1/.2 too when present"
    )
    ap.add_argument("--baseline", default=DEFAULT_BASELINE, help="baseline JSON path")
    ap.add_argument("--since", help="only sessions on/after this YYYY-MM-DD")
    args = ap.parse_args(argv)

    if not os.path.exists(args.baseline):
        print(f"baseline not found: {args.baseline}", file=sys.stderr)
        return 2
    try:
        baseline = json.load(open(args.baseline))
    except (ValueError, OSError) as e:
        print(f"baseline unusable: {e}", file=sys.stderr)
        return 2
    if "targets" not in baseline or not baseline["targets"]:
        print("baseline has no 'targets' map", file=sys.stderr)
        return 2

    missing = [p for p in args.log if not os.path.exists(p)]
    for p in missing:
        print(f"no log at {p}", file=sys.stderr)
    if len(missing) == len(args.log):
        return 2

    rows = []
    for p in args.log:
        if os.path.exists(p):
            rows.extend(parse_with_target(p, args.since))
    if not rows:
        print(f"no hotkey presses found in {' '.join(args.log)}", file=sys.stderr)
        return 2

    fail = False
    for target in sorted(set(r["target"] for r in rows)):
        passed, detail = evaluate(rows, baseline, target)
        print(f"  {detail}")
        if not passed:
            fail = True

    if fail:
        print("\n  RATE REGRESSION DETECTED (see targets above)")
        return 1
    print("\n  rate guard: no regression")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        sys.exit(0)
