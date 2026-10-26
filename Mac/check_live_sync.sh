#!/usr/bin/env bash
# Detect drift between the tracked macOS config and the LIVE Hammerspoon file.
#
# Why this exists: ~/.hammerspoon/init.lua is a REAL file (not a symlink to this
# repo) that also holds unrelated personal automation (display layout, zoom,
# uBar nudges), so it evolves independently. It has silently reverted the
# CopyURL fixes at least twice (2026-07-26 and 2026-07-27), each time losing
# work that was already committed here. CONFIG_VERSION alone proves nothing —
# the regressed copy reported a HIGHER version number than the fixed one.
#
# So this checks CONTENT, not version strings:
#   1. Every CopyURL symbol defined in the tracked file must exist in the live
#      file (functions, hotkey bindings, url-event hooks).
#   2. A list of named "fix markers" must be present — one per regression that
#      has actually happened, with the CLAUDE.md date it came from.
#
# Usage:
#   Mac/check_live_sync.sh              # check (exit 1 on drift)
#   Mac/check_live_sync.sh --section-diff   # also print a unified diff of the
#                                           # CopyURL section (repo -> live)
#   COPYURL_LIVE_INIT=/path/to/init.lua Mac/check_live_sync.sh
#
# Exit: 0 = in sync (or not a Mac / no live file: SKIP), 1 = drift found.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
ROOT="$PWD"
REPO_INIT="$ROOT/Mac/hammerspoon/init.lua"
LIVE_INIT="${COPYURL_LIVE_INIT:-$HOME/.hammerspoon/init.lua}"

fail=0
note() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  PASS  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }
skip() { printf '  SKIP  %s\n' "$*"; }

if [[ ! -f "$REPO_INIT" ]]; then
  bad "tracked config missing: Mac/hammerspoon/init.lua"
  exit 1
fi
if [[ ! -f "$LIVE_INIT" ]]; then
  skip "no live config at $LIVE_INIT (not a Mac, or Hammerspoon not installed)"
  echo "  Nothing to compare."
  exit 0
fi

# The CopyURL section is everything up to the first unrelated banner (the zoom
# tap). Everything after that belongs to other automation and is NOT compared.
# Fixed-string match (not a regex) so awk needs no escaping.
SECTION_END='-- Ctrl + mouse wheel'
repo_section="$(awk -v s="$SECTION_END" 'index($0, s) == 1 { exit } { print }' "$REPO_INIT")"
live_section="$(awk -v s="$SECTION_END" 'index($0, s) == 1 { exit } { print }' "$LIVE_INIT")"

# ---------------------------------------------------------------------------
note "version strings (informational — NOT a sync signal)"
repo_ver="$(sed -n 's/^local CONFIG_VERSION = "\(.*\)"/\1/p' "$REPO_INIT" | head -1)"
live_ver="$(sed -n 's/^local CONFIG_VERSION = "\(.*\)"/\1/p' "$LIVE_INIT" | head -1)"
printf '  tracked: %s\n  live:    %s\n' "${repo_ver:-<none>}" "${live_ver:-<none>}"
if [[ "$repo_ver" != "$live_ver" ]]; then
  printf '  NOTE  versions differ; the live file also carries other automation, so this is normal.\n'
fi

# ---------------------------------------------------------------------------
note "CopyURL symbols defined in the tracked file must exist in the live file"
# Auto-derived, so newly added functions are covered without editing this script.
symbols="$(
  {
    grep -oE '^local function [A-Za-z_][A-Za-z0-9_]*' "$REPO_INIT" | awk '{print $3}'
    grep -oE 'hs\.urlevent\.bind\("copyurl-[a-z-]+"' "$REPO_INIT" | grep -oE 'copyurl-[a-z-]+'
    grep -oE 'hs\.hotkey\.bind\([^)]*\)' "$REPO_INIT" | head -1
  } | sort -u
)"
n_sym=0
while IFS= read -r sym; do
  [[ -n "$sym" ]] || continue
  n_sym=$((n_sym + 1))
  if grep -qF -- "$sym" "$LIVE_INIT"; then
    :
  else
    bad "live file is missing '$sym' (present in tracked config)"
  fi
done <<<"$symbols"
if (( fail == 0 )); then ok "all $n_sym CopyURL symbols present in the live file"; fi

# ---------------------------------------------------------------------------
note "fix markers (one per regression that has actually happened)"
# name | regex that must appear in the LIVE file | origin
markers=(
  'native Gemini app target|geminiBundleId = "com\.google\.GeminiMacOS"|2026-07-27 (PWA -> native app)'
  'trigger "]" targeted at the YouTube app|keyStroke\(\{\}, "\]", 0, ytApp\)|2026-07-17 (untargeted keystroke missed Brave)'
  'AX send-button submit|function pressGeminiSendButton|2026-07-17 (Return is ignored by Gemini)'
  'send-button enabled probe|function isGeminiSendEnabled|2026-07-17'
  'generating-state probe|function isGeminiGenerating|2026-07-17 (pre-paste idle wait)'
  'AXValue direct composer set|setAttributeValue\("AXValue"|2026-07-17 (Cmd+V intermittently ignored)'
  'paste verified against the expected URL|urlMatch|2026-07-17 (clipboard snapshot raced)'
  'submit retried until the composer empties|empty composer|2026-07-17'
  'pasteAndSubmitToGemini takes expectedUrl|function pasteAndSubmitToGemini\([^)]*expectedUrl|2026-07-17'
)
for m in "${markers[@]}"; do
  name="${m%%|*}"; rest="${m#*|}"; re="${rest%%|*}"; origin="${rest#*|}"
  in_repo=0; in_live=0
  grep -qE -- "$re" <<<"$repo_section" && in_repo=1
  grep -qE -- "$re" <<<"$live_section" && in_live=1
  if (( in_repo == 1 && in_live == 0 )); then
    bad "$name — MISSING from live file (fix from $origin)"
  elif (( in_repo == 0 && in_live == 1 )); then
    ok "$name (live only — tracked config is behind; port it into the repo)"
  elif (( in_repo == 1 && in_live == 1 )); then
    ok "$name"
  else
    bad "$name — missing from BOTH files (the fix was lost on both sides; see $origin)"
  fi
done

# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--section-diff" ]]; then
  note "CopyURL section diff (tracked -> live; '<' = missing from live)"
  if diff -u <(printf '%s\n' "$repo_section") <(printf '%s\n' "$live_section") >/tmp/cu_mac_diff.txt; then
    ok "sections are byte-identical"
  else
    printf '  %s lines of difference (full diff: /tmp/cu_mac_diff.txt)\n' \
      "$(grep -cE '^[+-]' /tmp/cu_mac_diff.txt)"
    sed -n '1,80p' /tmp/cu_mac_diff.txt | sed 's/^/    /'
    printf '    ... (truncated; see /tmp/cu_mac_diff.txt)\n'
  fi
fi

# ---------------------------------------------------------------------------
note "Summary"
if (( fail == 0 )); then
  echo "  IN SYNC"
else
  cat <<'EOF'
  DRIFT FOUND. The live file has lost CopyURL fixes that are committed here.
  Port the missing pieces from Mac/hammerspoon/init.lua into the live file,
  leaving the unrelated automation (zoom, layout, display) untouched.
  Back up first:  cp ~/.hammerspoon/init.lua ~/.hammerspoon/init.lua.bak_$(date +%Y%m%d_%H%M%S)
  Inspect first:  Mac/check_live_sync.sh --section-diff
EOF
fi
exit "$fail"
