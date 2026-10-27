#!/usr/bin/env python3
"""Tests for scripts/rate_guard.py.

The guard is what turns "it broke again" into a CI failure, so these tests pin
the two things that can be wrong:

  1. A genuinely degraded target must FAIL (a regression must not slip under
     a floor because of a sampling/attribution bug).
  2. A clean target must PASS (a healthy log must not false-alarm).

Target attribution (Aside vs PWA vs unknown) is what makes per-target floors
possible; it is exercised explicitly because a wrong browser class silently
flips which floor applies and can either hide a regression or fail a healthy
run.

Every case runs the real guard against a real temp log file — no stubbed
internal helpers — so the file-reading path (including parse_with_target's
session split) is what is under test, not a reimplementation of it.

Usage: python3 tests/test_rate_guard.py   (exit 0 = all pass)
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))

import rate_guard  # noqa: E402
from rate_guard import parse_with_target, evaluate  # noqa: E402

BASELINE = {
    "targets": {
        "aside": {"min_rate": 80.0, "min_samples": 10},
        "pwa": {"min_rate": 90.0, "min_samples": 10},
        "unknown": {"min_rate": 0.0, "min_samples": 10},
    },
    "tolerance": 0.0,
}

FAIL = 0


def check(name, got, want):
    global FAIL
    if got == want:
        print(f"  PASS  {name}")
    else:
        FAIL = 1
        print(f"  FAIL  {name}: got {got!r}, expected {want!r}")


# Verbatim Linux line shapes from copyurl.sh (log() prefix + activation).
# Success/failure markers match analyze_log's SUCCESS_RE / FAILURE_RE.
def linux_session(ok, browser_class="org.asidelinux.Browser", n=1):
    lines = []
    for _ in range(n):
        lines.append("2026-10-26 12:00:00 Alt+A fired (target=gemini, version=v10)")
        lines.append(f"2026-10-26 12:00:00 activateByWmClass('{browser_class}') -> (true,)")
        if ok:
            lines.append("2026-10-26 12:00:01 done; sent url=https://www.youtube.com/watch?v=x")
        else:
            lines.append("2026-10-26 12:00:01 diagnosis: the browser window WAS raised")
            lines.append("2026-10-26 12:00:01 ERROR: URL copy failed. Hover a YouTube thumbnail")
    return lines


def run_guard(log_lines):
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "copyurl_log.txt")
        with open(path, "w") as fh:
            fh.write("\n".join(log_lines) + "\n")
        rc = os.system(
            f"{sys.executable} scripts/rate_guard.py '{path}' "
            f"--baseline tests/baseline.json >/dev/null 2>&1"
        )
        return rc >> 8


# ---- attribution (parse_with_target + _target_from_lines) ------------------
def test_attribution():
    rows = parse_with_target(_tmp_log(linux_session(True, "org.asidelinux.Browser", n=1)))
    check("Aside browser => aside", rows[0]["target"], "aside")

    rows = parse_with_target(_tmp_log(linux_session(True, "chrome-gdfaincndogidkdcdkhapmbffkckdkhn-Default", n=1)))
    check("Chrome-class window => pwa", rows[0]["target"], "pwa")

    win = ["2026-10-26 12:00:00 t=1 | --- Alt+A pressed ---"]
    check("Windows session (no class) => unknown", rate_guard._target_from_lines(win), "unknown")


def _tmp_log(lines):
    f = tempfile.NamedTemporaryFile("w", suffix=".log", delete=False)
    f.write("\n".join(lines) + "\n")
    f.close()
    return f.name


def test_parse_consistency():
    # The inline session split must agree with analyze_log's own on the same
    # stream: one press -> one session, outcome classified, target set.
    rows = parse_with_target(_tmp_log(linux_session(True, "org.asidelinux.Browser", n=2)))
    check("two clean sessions parsed", len(rows), 2)
    check("both ok", all(r["ok"] for r in rows), True)
    check("both aside", all(r["target"] == "aside" for r in rows), True)


# ---- evaluate: floors and sampling -----------------------------------------
def rows(target, n_ok, n_fail):
    out = []
    for _ in range(n_ok):
        out.append({"target": target, "ok": True, "day": "2026-10-26", "mode": None})
    for _ in range(n_fail):
        out.append({"target": target, "ok": False, "day": "2026-10-26", "mode": "timeout"})
    return out


def test_evaluate():
    passed, _ = evaluate(rows("aside", 8, 2), BASELINE, "aside")
    check("aside 80% passes", passed, True)

    passed, _ = evaluate(rows("aside", 7, 3), BASELINE, "aside")
    check("aside 70% fails", passed, False)

    # 9 total < min_samples 10, so unchecked -> passes even at 0% success.
    passed, _ = evaluate(rows("aside", 0, 9), BASELINE, "aside")
    check("aside below min_samples passes (unchecked)", passed, True)

    passed, _ = evaluate(rows("pwa", 8, 2), BASELINE, "pwa")
    check("pwa 80% fails (its floor is 90)", passed, False)


def test_cli_flag():
    rc = run_guard(linux_session(True, "org.asidelinux.Browser", n=8) + linux_session(False, "org.asidelinux.Browser", n=12))
    check("degraded aside log => exit 1", rc, 1)


def test_cli_pass():
    rc = run_guard(linux_session(True, "org.asidelinux.Browser", n=20))
    check("clean aside log => exit 0", rc, 0)


if __name__ == "__main__":
    test_attribution()
    test_parse_consistency()
    test_evaluate()
    test_cli_flag()
    test_cli_pass()
    print("\n  ALL GREEN" if FAIL == 0 else "\n  FAILURES ABOVE")
    sys.exit(FAIL)
