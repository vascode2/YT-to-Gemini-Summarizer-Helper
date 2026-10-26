#!/usr/bin/env python3
"""Tests for scripts/analyze_log.py.

The analyzer exists to answer "what is the failure rate and why", so these
tests pin the classification of every failure mode the two platforms log --
including that Linux's "no extension trace written" and Windows' "beacon=none"
stay separate labels. They were once the same dict key, and the later entry
silently overwrote the earlier one, so every Linux silent-extension failure was
reported as "unclassified".

Usage: python3 tests/test_analyze_log.py   (exit 0 = all pass)
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))

from analyze_log import parse, summarize  # noqa: E402

FAIL = 0


def check(name, got, want):
    global FAIL
    if got == want:
        print(f"  PASS  {name}")
    else:
        FAIL = 1
        print(f"  FAIL  {name}: got {got!r}, expected {want!r}")


LINUX_OK = """\
2026-10-26 10:02:00 Alt+A fired (target=gemini, version=v9)
2026-10-26 10:02:01 done; sent url=https://www.youtube.com/watch?v=x
"""

LINUX_FAIL = """\
2026-10-26 10:00:00 Alt+A fired (target=gemini, version=v9)
2026-10-26 10:00:01 {diagnosis}
2026-10-26 10:00:01 ERROR: URL copy failed. {hint}
"""

# Verbatim line shapes from copy.ahk's DebugLog() calls. The "--- " wrapper and
# the "t=<tick> | " field are real; so is the parenthetical in the Alt+Z form.
AHK_FAIL = """\
2026-10-26 10:06:00 t=999 | --- Alt+A pressed ---
2026-10-26 10:06:01 t=999 | Copy attempt 1 on Brave.exe timed out (beacon={beacon}).
2026-10-26 10:06:02 t=999 | Candidate Brave.exe gave up after 3 attempts — falling through to next candidate.
"""

# diagnosis line -> expected label. Each must classify distinctly.
LINUX_CASES = {
    "diagnosis: no extension trace written since the press": "extension-silent",
    "diagnosis: extension storage changed but no trigger was recorded for this press": "stale-content-script",
    "diagnosis: NO VIDEO UNDER THE CURSOR at press time": "no-hover",
    "diagnosis: a video was hovered but the page did not have focus": "unfocused",
    "diagnosis: the extension DID have a hovered video and the page was focused": "clipboard-write-failed",
}

AHK_CASES = {
    "none": "beacon-none",
    "null": "beacon-null",
    "execfail": "beacon-execfail",
    "asyncfail": "beacon-asyncfail",
}


def write_tmp(text):
    import tempfile

    fd, path = tempfile.mkstemp(suffix=".log")
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
    return path


def test_linux_modes():
    print("\n=== Linux diagnosis lines -> distinct failure modes ===")
    body = ""
    for diag in LINUX_CASES:
        body += LINUX_FAIL.format(diagnosis=diag, hint="hint")
    path = write_tmp(body)
    try:
        rows = parse(path)
    finally:
        os.unlink(path)
    modes = sorted(r["mode"] for r in rows if not r["ok"])
    check("every session is a failure", len(rows), len(LINUX_CASES))
    check("labels are the expected set", modes, sorted(LINUX_CASES.values()))
    check("nothing unclassified", "unclassified" in modes, False)


def test_ahk_modes():
    print("\n=== Windows beacon states -> distinct failure modes ===")
    body = "".join(AHK_FAIL.format(beacon=b) for b in AHK_CASES)
    path = write_tmp(body)
    try:
        rows = parse(path)
    finally:
        os.unlink(path)
    modes = sorted(r["mode"] for r in rows if not r["ok"])
    check("labels are the expected set", modes, sorted(AHK_CASES.values()))


def test_success_and_rate():
    print("\n=== success detection and rate ===")
    body = LINUX_OK + LINUX_FAIL.format(diagnosis="diagnosis: NO VIDEO UNDER THE CURSOR at press time", hint="h")
    path = write_tmp(body)
    try:
        s = summarize(parse(path))
    finally:
        os.unlink(path)
    check("2 sessions", s["total"], 2)
    check("1 ok", s["ok"], 1)
    check("1 failed", s["fail"], 1)
    check("rate is 50%", round(s["rate"], 1), 50.0)


def test_ahk_real_line_shapes():
    print("\n=== Windows: real DebugLog shapes are all detected ===")
    # Regression guards for two real bugs: (1) "--- Alt+Z (Aside) pressed ---"
    # was not counted as a press because the parenthetical broke adjacency, and
    # (2) "Sent Netflix sentence to Aside side panel." was not counted as
    # success because it does not read "Sent to". Either bug silently drops
    # sessions from the denominator and corrupts the rate.
    body = (
        "2026-10-26 10:00:00 t=1 | --- Alt+A pressed ---\n"
        "2026-10-26 10:00:01 t=2 | Copy attempt 1 on Brave.exe succeeded.\n"
        "2026-10-26 10:00:02 t=3 | Sent to Gemini.\n"
        "2026-10-26 10:01:00 t=4 | --- Alt+Z (Aside) pressed ---\n"
        "2026-10-26 10:01:05 t=5 | Netflix sentence len=46\n"
        "2026-10-26 10:01:08 t=6 | Sent Netflix sentence to Aside side panel.\n"
        "2026-10-26 10:02:00 t=7 | --- Alt+A pressed ---\n"
        "2026-10-26 10:02:01 t=8 | Copy attempt 1 on Brave.exe timed out (beacon=none).\n"
        "2026-10-26 10:02:02 t=9 | Candidate Brave.exe fast-failed (beacon=none) — falling through.\n"
    )
    path = write_tmp(body)
    try:
        s = summarize(parse(path))
    finally:
        os.unlink(path)
    check("all 3 presses counted", s["total"], 3)
    check("2 successes", s["ok"], 2)
    check("1 failure", s["fail"], 1)
    check("the failure is beacon-none", list(s["modes"]), ["beacon-none"])


def test_since_filter():
    print("\n=== --since drops older sessions ===")
    body = (
        LINUX_FAIL.format(diagnosis="diagnosis: NO VIDEO UNDER THE CURSOR at press time", hint="h")
        .replace("2026-10-26", "2026-01-01")
        + LINUX_OK
    )
    path = write_tmp(body)
    try:
        check("unfiltered has 2", len(parse(path)), 2)
        check("filtered keeps 1", len(parse(path, since="2026-10-01")), 1)
    finally:
        os.unlink(path)


def test_press_boundaries():
    print("\n=== sessions start at a press, not at an outcome line ===")
    # A failure whose outcome appears BEFORE the next press must not leak into
    # it, or one bad press would mark the next good one as failed too.
    body = (
        LINUX_FAIL.format(diagnosis="diagnosis: NO VIDEO UNDER THE CURSOR at press time", hint="h")
        + LINUX_OK
    )
    path = write_tmp(body)
    try:
        rows = parse(path)
    finally:
        os.unlink(path)
    check("first failed", rows[0]["ok"], False)
    check("second succeeded", rows[1]["ok"], True)


def main():
    test_linux_modes()
    test_ahk_modes()
    test_ahk_real_line_shapes()
    test_success_and_rate()
    test_since_filter()
    test_press_boundaries()
    print("\n=== Summary ===")
    print("  ALL GREEN" if FAIL == 0 else "  FAILURES ABOVE")
    return FAIL


if __name__ == "__main__":
    sys.exit(main())
