#!/usr/bin/env bash
# CopyURL Linux workflow (Ubuntu / GNOME Wayland)
# Hotkey: Alt+A  (bound via a GNOME custom keyboard shortcut -> this script)
#
# Flow (analog of the Windows copy.ahk / macOS init.lua):
#   0) Activate the Brave/YouTube window (via the "Activate Window By Title"
#      GNOME extension) so the trigger keystroke lands in Brave even when Brave
#      does NOT currently have keyboard focus (e.g. you are only HOVERING a
#      thumbnail while another window is focused). The mouse cursor stays put,
#      so content.js still resolves the hovered video via its last pointer
#      position.
#   1) Send the trigger character "]" to the (now focused) Brave window where you
#      are hovering a YouTube thumbnail via `ydotool type`. content.js copies
#      the hovered URL to the clipboard AND queues a Gemini paste payload in the
#      extension's chrome.storage.local.
#   2) Poll the clipboard (wl-paste) until a youtube.com URL appears, to confirm
#      the copy succeeded (and retry the trigger if not).
#   3) Activate the Gemini PWA window (via the "Activate Window By Title" GNOME
#      extension's D-Bus method) so the result is visible.
#
# The actual paste + submit into Gemini is done entirely inside the browser by
# the Gemini content script (../gemini.js): it reads the queued payload and
# inserts it into the composer via the DOM, then clicks send. This avoids OS-
# level input synthesis, which is unreliable on GNOME Wayland:
#   * `ydotool key <code>` mangles keycodes (broken virtual-device keymap), so
#     F24 / Ctrl+V / Enter cannot be sent by keycode.
#   * `ydotool type` works for ASCII but CANNOT type Korean/non-ASCII.
#   * `ydotool mousemove` is relative-only (no absolute), so coordinate-based
#     middle-click paste is not reliable.
# `ydotool type "]"` is the one synthetic-input path confirmed to work here.
#
# This file is Linux-only and changes nothing in the Windows (copy.ahk) or
# macOS (Mac/) workflows. The shared pieces are the browser extension scripts
# (../content.js + ../gemini.js + ../manifest.json).
#
# Setup, dependencies, and the GNOME shortcut binding are documented in
# ./README.md.

set -uo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
CONFIG_VERSION="v6 2026-10-16 linux-aside-panel"

# Substring matched (case-insensitive on the extension side) against window
# titles to find the Gemini window. The PWA's title contains "Gemini".
GEMINI_TITLE_NEEDLE="${COPYURL_GEMINI_NEEDLE:-Gemini}"

# Substring matched against window titles to find the Brave/YouTube window so
# the trigger keystroke can be delivered even when Brave is not focused. A
# YouTube tab's title ends in "YouTube" (e.g. "... - YouTube - Brave").
YOUTUBE_TITLE_NEEDLE="${COPYURL_YOUTUBE_NEEDLE:-YouTube}"

# Wayland app_ids (window classes), tried before the title needles. The most
# recently used window of that class is raised. Defaults: the Aside Linux
# browser window and the Gemini web app installed in Aside Linux. Set to ""
# to match by title only (e.g. Brave).
BROWSER_WMCLASS="${COPYURL_BROWSER_WMCLASS-org.asidelinux.Browser}"
GEMINI_WMCLASS="${COPYURL_GEMINI_WMCLASS-chrome-gdfaincndogidkdcdkhapmbffkckdkhn-Default}"

# Trigger character typed into the browser to fire content.js. "]" has no
# YouTube shortcut and content.js only acts on it while a thumbnail is hovered.
# (The Korean prompt prefix lives in ../content.js as PASTE_PREFIX; the paste
# itself is performed by ../gemini.js, not by this script.)
TRIGGER_CHAR="${COPYURL_TRIGGER_CHAR:-]}"

# Trigger for --aside (Alt+Z): content.js sends the prompt to the Aside Linux
# side panel ("Aside Browsing Agent") instead of Gemini when it sees "[".
ASIDE_TRIGGER_CHAR="${COPYURL_ASIDE_TRIGGER_CHAR:-[}"

# Settle delay (seconds) before the first trigger. The GNOME hotkey is Alt+A, so
# the user is usually still holding Alt for a moment after it fires; this also
# lets ydotool's first injection warm up. content.js no longer requires Alt to
# be released, but a small pause makes the very first press more reliable.
TRIGGER_SETTLE_DELAY="${COPYURL_TRIGGER_SETTLE_DELAY:-0.12}"

# How long (seconds) to wait for the clipboard to change after the trigger,
# and how often to poll. Two attempts total (mirrors copy.ahk retry).
CLIP_TIMEOUT="${COPYURL_CLIP_TIMEOUT:-1.5}"
CLIP_POLL="${COPYURL_CLIP_POLL:-0.05}"
COPY_ATTEMPTS="${COPYURL_COPY_ATTEMPTS:-2}"

# Delay (seconds) after activating the Gemini window, to let it come forward.
GEMINI_FOCUS_DELAY="${COPYURL_GEMINI_FOCUS_DELAY:-0.35}"

# Delay (seconds) after activating the Brave/YouTube window, to let it gain
# keyboard focus before we type the trigger into it.
BROWSER_FOCUS_DELAY="${COPYURL_BROWSER_FOCUS_DELAY:-0.2}"

# Verbose logging (1 = on). Mirrors kVerboseLog in copy.ahk.
VERBOSE="${COPYURL_VERBOSE:-1}"

# Log file. Defaults under XDG state dir (not synced, not in the repo).
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/copyurl"
LOG_FILE="${COPYURL_LOG_FILE:-$LOG_DIR/copyurl_log.txt}"
LOG_MAX_BYTES="${COPYURL_LOG_MAX_BYTES:-1048576}"  # rotate at ~1 MB

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
log() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  # Rotate if the log grew too large.
  if [[ -f "$LOG_FILE" ]]; then
    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if (( size > LOG_MAX_BYTES )); then
      mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
    fi
  fi
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

vlog() { [[ "$VERBOSE" == "1" ]] && log "$@"; }

notify() {
  log "notify: $*"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -t 2500 "CopyURL" "$*" 2>/dev/null || true
  fi
}

# Success-path desktop notification; off by default (set COPYURL_NOTIFY=1 to
# enable). Errors (die) always notify. Still written to the log either way.
notify_info() {
  if [[ "${COPYURL_NOTIFY:-0}" == "1" ]]; then
    notify "$*"
  else
    log "notify (suppressed): $*"
  fi
}

die() {
  log "ERROR: $*"
  notify "$*"
  exit 1
}

# ----------------------------------------------------------------------------
# Dependencies
# ----------------------------------------------------------------------------
# Locate the ydotoold socket so ydotool can talk to the daemon. ydotool can
# usually find the daemon on its own, so we only set YDOTOOL_SOCKET if it is
# unset AND we find a real socket at one of the common locations. We never
# point it at a non-existent path (that would break the auto-discovery).
if [[ -z "${YDOTOOL_SOCKET:-}" ]]; then
  _rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  for _cand in "$_rt/ydotool/ydotoold.sock" "$_rt/.ydotool_socket" "/tmp/.ydotool_socket"; do
    if [[ -S "$_cand" ]]; then
      export YDOTOOL_SOCKET="$_cand"
      break
    fi
  done
  unset _rt _cand
fi

check_deps() {
  local missing=()
  for cmd in ydotool wl-copy wl-paste gdbus; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    echo "Missing required commands: ${missing[*]}" >&2
    echo "See Linux/README.md for installation (ydotool, wl-clipboard, glib2)." >&2
    return 1
  fi
  return 0
}

# ----------------------------------------------------------------------------
# Clipboard helpers (wl-clipboard)
# ----------------------------------------------------------------------------
clip_get() {
  # Prints current clipboard text; empty string if clipboard is empty.
  wl-paste --no-newline 2>/dev/null || true
}

clip_set() {
  printf '%s' "$1" | wl-copy 2>/dev/null || log "WARN: wl-copy failed"
}

# ----------------------------------------------------------------------------
# Trigger injection (ydotool). `ydotool type` is the only synthetic-input path
# that works reliably on this GNOME Wayland setup (see header notes).
# ----------------------------------------------------------------------------
send_trigger() {
  ydotool type "$TRIGGER_CHAR" 2>/dev/null \
    || die "ydotool could not type the trigger (is ydotoold running? see README)."
}

# ----------------------------------------------------------------------------
# Window activation (Activate Window By Title GNOME extension)
# ----------------------------------------------------------------------------
# Activate the most recently used window matching $2 via extension method $1
# (activateBySubstring = title contains, activateByWmClass = Wayland app_id).
# Returns 0 on success.
activate_window_by() {
  local method="$1" needle="$2" result old_sort
  local dest=(--session --dest org.gnome.Shell
    --object-path /de/lucaswerkmeister/ActivateWindowByTitle)
  local iface=de.lucaswerkmeister.ActivateWindowByTitle
  # The extension's default order is arbitrary, so with several windows whose
  # title matches (e.g. a Gemini chat titled "... YouTube ..." plus the real
  # YouTube window) focus flip-flops between them. Prefer the most recently
  # used matching window, then restore the previous order.
  old_sort=$(gdbus call "${dest[@]}" --method "$iface.setSortOrder" \
    highest_user_time 2>/dev/null | sed -n "s/^('\(.*\)',)$/\1/p")
  result=$(gdbus call "${dest[@]}" --method "$iface.$method" \
    "$needle" 2>&1)
  [[ -n "$old_sort" ]] && gdbus call "${dest[@]}" \
    --method "$iface.setSortOrder" "$old_sort" >/dev/null 2>&1
  vlog "$method('$needle') -> $result"
  [[ "$result" == *"true"* ]]
}

activate_window_by_title() { activate_window_by activateBySubstring "$1"; }

activate_gemini() {
  if { [[ -n "$GEMINI_WMCLASS" ]] && activate_window_by activateByWmClass "$GEMINI_WMCLASS"; } \
    || activate_window_by_title "$GEMINI_TITLE_NEEDLE"; then
    return 0
  fi
  log "WARN: could not activate Gemini window (extension installed/enabled? title contains '$GEMINI_TITLE_NEEDLE'?)"
  return 1
}

# Bring the Brave/YouTube window forward so the trigger keystroke lands in it
# even when Brave is not the focused window. Non-fatal: if activation fails
# (extension missing, no matching title), we still type the trigger into
# whatever is focused, preserving the old behaviour.
activate_youtube() {
  # Prefer the browser's window class: a title match can hit the Gemini app,
  # whose chat title often mentions YouTube after the first summary.
  if [[ -n "$BROWSER_WMCLASS" ]] && activate_window_by activateByWmClass "$BROWSER_WMCLASS"; then
    return 0
  fi
  # " - YouTube" (watch/search pages: "<title> - YouTube ...") avoids windows
  # that merely mention YouTube, e.g. a Gemini chat; fall back to the plain
  # needle for the home page, whose title is just "YouTube".
  if activate_window_by_title " - $YOUTUBE_TITLE_NEEDLE" \
    || activate_window_by_title "$YOUTUBE_TITLE_NEEDLE"; then
    return 0
  fi
  log "WARN: could not activate YouTube/Brave window (title contains '$YOUTUBE_TITLE_NEEDLE'? is a YouTube tab open and frontmost in Brave?)"
  return 1
}

# ----------------------------------------------------------------------------
# Copy phase: send F24, wait for clipboard to change to a youtube URL.
# ----------------------------------------------------------------------------
# Copy phase: reset the clipboard to a unique sentinel, type the trigger, then
# wait for the clipboard to become a youtube URL. Resetting to a sentinel first
# is what lets us detect copying the SAME video twice in a row — otherwise the
# clipboard value never "changes" and the poll would falsely time out.
# Stores the copied URL in the global COPIED_URL on success.
# ----------------------------------------------------------------------------
COPIED_URL=""
copy_url_from_browser() {
  COPIED_URL=""
  local sentinel="__copyurl_sentinel_$$_$(date +%s%N)"
  local attempt cur start now
  # Bring Brave/YouTube to the front FIRST so the trigger keystroke is delivered
  # to Brave even when another window currently holds keyboard focus. The mouse
  # cursor is not moved, so content.js still sees the hovered thumbnail.
  if activate_youtube; then
    sleep "$BROWSER_FOCUS_DELAY"
  fi
  # Brief settle so a still-held Alt (from Alt+A) is released and ydotool warms up.
  sleep "$TRIGGER_SETTLE_DELAY"
  for (( attempt = 1; attempt <= COPY_ATTEMPTS; attempt++ )); do
    # Clear to the sentinel so a same-URL re-copy is still detectable.
    clip_set "$sentinel"
    vlog "copy attempt $attempt: typing trigger '$TRIGGER_CHAR'"
    send_trigger
    start=$(date +%s.%N)
    while :; do
      sleep "$CLIP_POLL"
      cur="$(clip_get)"
      if [[ "$cur" != "$sentinel" && "$cur" == *"youtube.com"* ]]; then
        vlog "copy attempt $attempt: clipboard changed -> $cur"
        COPIED_URL="$cur"
        return 0
      fi
      now=$(date +%s.%N)
      if (( $(echo "$now - $start > $CLIP_TIMEOUT" | bc -l) )); then
        vlog "copy attempt $attempt: timed out after ${CLIP_TIMEOUT}s"
        break
      fi
    done
  done
  return 1
}

# ----------------------------------------------------------------------------
# Bring Gemini forward. The actual paste + submit is performed by ../gemini.js
# inside the browser (it consumes the payload queued by content.js), so this
# only needs to surface the Gemini window for the user.
# ----------------------------------------------------------------------------
focus_gemini() {
  activate_gemini || true
  sleep "$GEMINI_FOCUS_DELAY"
}

# ----------------------------------------------------------------------------
# Main flow
# ----------------------------------------------------------------------------
run_flow() {
  local target="${1:-gemini}" key="Alt+A"
  if [[ "$target" == "aside" ]]; then
    TRIGGER_CHAR="$ASIDE_TRIGGER_CHAR"
    key="Alt+Z"
  fi
  log "$key fired (target=$target, version=$CONFIG_VERSION)"
  local original_clip
  original_clip="$(clip_get)"

  if ! copy_url_from_browser; then
    # Restore whatever the user had before we wrote the sentinel.
    [[ -n "$original_clip" ]] && clip_set "$original_clip"
    die "URL copy failed. Hover a YouTube thumbnail in the browser (Brave or Aside), then press $key again."
  fi

  # Aside: content.js has handed the prompt to the Aside extension, which opens
  # the side panel in the same window and sends it there. Nothing to focus.
  if [[ "$target" == "aside" ]]; then
    notify_info "Got URL, sending to the Aside side panel"
    log "done; sent to Aside url=$COPIED_URL"
    return 0
  fi

  # content.js has now also queued the Korean prompt + URL for gemini.js, which
  # inserts and submits it in the browser. We just bring Gemini to the front.
  notify_info "Got URL, sending to Gemini"
  focus_gemini
  log "done; sent url=$COPIED_URL"
}

# Focus test: just activate the Gemini window. The paste itself is exercised
# by the browser extension (content.js queues a payload, gemini.js inserts it),
# which this script cannot trigger directly, so there is no standalone paste
# test on Linux — use the full Alt+A flow on a real thumbnail to test paste.
run_focus_test() {
  log "focus-test start"
  notify "focus-test: activating Gemini"
  focus_gemini
  log "focus-test done"
}

usage() {
  cat <<EOF
CopyURL Linux orchestrator ($CONFIG_VERSION)

Usage: copyurl.sh [command]

Commands:
  (none)        Run the full Alt+A flow: type "]" -> copy URL -> focus Gemini
                (the browser extension inserts + submits the prompt).
  --aside       Alt+Z flow (Aside Linux): type "[" -> copy URL; the extension
                sends the prompt to Aside's side panel instead of Gemini.
  --focus-test  Just activate the Gemini window (focus sanity check).
  --check       Verify required dependencies are installed.
  --help        Show this help.

Configuration is via environment variables (see top of this script), e.g.
  COPYURL_TRIGGER_CHAR, COPYURL_GEMINI_NEEDLE, COPYURL_VERBOSE.
Logs: $LOG_FILE
EOF
}

main() {
  case "${1:-}" in
    --help|-h) usage ;;
    --check)   check_deps && echo "All dependencies present." ;;
    --aside)
      check_deps || die "Missing dependencies (run: copyurl.sh --check)."
      run_flow aside
      ;;
    --focus-test)
      check_deps || die "Missing dependencies (run: copyurl.sh --check)."
      run_focus_test
      ;;
    "")
      check_deps || die "Missing dependencies (run: copyurl.sh --check)."
      run_flow
      ;;
    *)
      echo "Unknown command: $1" >&2
      usage
      exit 2
      ;;
  esac
}

main "$@"
