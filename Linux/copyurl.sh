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
#   2) Poll the clipboard (xclip via Xwayland; wl-paste fallback) until a youtube.com URL appears, to confirm
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
CONFIG_VERSION="v11 2026-10-27 title-steering"

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
# Where to look for the extension's on-disk `copyurlTrace` when a copy fails.
# content.js records every trigger press there (key, hovered URL, focused,
# element under the cursor), which is the only way to tell "the keystroke never
# reached the page" from "it did, but there was no video under the cursor" --
# both look identical from the clipboard. Space-separated; override to add
# profiles (e.g. a portable Aside install).
COPYURL_PROFILE_ROOTS="${COPYURL_PROFILE_ROOTS-$HOME/.config/BraveSoftware/Brave-Browser $HOME/.config/google-chrome $HOME/Projects/Personal/Aside-Linux/.local/runtime/chrome}"

BROWSER_WMCLASS="${COPYURL_BROWSER_WMCLASS-org.asidelinux.Browser}"
GEMINI_WMCLASS="${COPYURL_GEMINI_WMCLASS-chrome-gdfaincndogidkdcdkhapmbffkckdkhn-Default}"
# Gemini PWA installed in another Chrome profile uses a different window class
# (chrome-<id>-Profile_2); try both so either install works.
GEMINI_WMCLASS2="${COPYURL_GEMINI_WMCLASS2:-chrome-gdfaincndogidkdcdkhapmbffkckdkhn-Profile_2}"

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
  for cmd in ydotool gdbus; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  # Clipboard: xclip OR wl-clipboard, not both. They are alternative backends
  # (see clip_get/clip_set), so requiring both rejected machines that have
  # xclip + Xwayland but no wl-clipboard, for no reason.
  local have_xclip=0 have_wl=0
  command -v xclip   >/dev/null 2>&1 && have_xclip=1
  command -v wl-copy  >/dev/null 2>&1 && command -v wl-paste >/dev/null 2>&1 && have_wl=1

  if (( ${#missing[@]} > 0 )); then
    echo "Missing required commands: ${missing[*]}" >&2
    echo "See Linux/README.md for installation (ydotool, glib2)." >&2
    return 1
  fi
  if (( ! have_xclip && ! have_wl )); then
    echo "Missing a clipboard tool: install xclip (preferred) or wl-clipboard." >&2
    echo "  sudo apt install xclip          # preferred: no window flicker" >&2
    echo "  sudo apt install wl-clipboard   # fallback: steals focus while polling" >&2
    return 1
  fi
  # The wl-* backend maps a toplevel to grab keyboard focus on every call, so
  # polling it makes windows visibly flicker. That still "works", which is why
  # it went unnoticed, so say it out loud instead of degrading silently.
  if [[ "${CLIP_BACKEND:-}" == wl ]] && \
     [[ -n "${WAYLAND_DISPLAY:-}" || "${XDG_SESSION_TYPE:-}" == wayland ]]; then
    local why fix
    if (( have_xclip )); then
      why="xclip is installed but DISPLAY is unset"
      fix="export DISPLAY=:0 in the shortcut (or find out why Xwayland's DISPLAY was lost)"
    else
      why="xclip not installed"
      fix="sudo apt install xclip"
    fi
    echo "WARNING: using the wl-clipboard backend ($why)." >&2
    echo "         wl-paste/wl-copy grab keyboard focus on every poll, so windows" >&2
    echo "         may flicker during a copy. Fix: $fix" >&2
    log "WARN: clipboard backend=wl ($why); fix: $fix"
  fi
  return 0
}

# ----------------------------------------------------------------------------
# Clipboard helpers (xclip, wl-clipboard fallback)
# ----------------------------------------------------------------------------
# GNOME/Mutter has no Wayland data-control protocol, so wl-paste/wl-copy map a
# small xdg_toplevel to get keyboard focus on every call. Polling every 50 ms
# made windows visibly flicker. Mutter mirrors the Wayland clipboard to
# Xwayland in both directions, and xclip reads/writes it through an unmapped X
# window (no focus change), so prefer xclip when Xwayland is available.
if [[ -n "${DISPLAY:-}" ]] && command -v xclip >/dev/null 2>&1; then
  CLIP_BACKEND=xclip
else
  CLIP_BACKEND=wl
fi

clip_get() {
  # Prints current clipboard text; empty string if clipboard is empty.
  if [[ "$CLIP_BACKEND" == xclip ]]; then
    timeout 1 xclip -o -selection clipboard 2>/dev/null || true
  else
    wl-paste --no-newline 2>/dev/null || true
  fi
}

clip_set() {
  if [[ "$CLIP_BACKEND" == xclip ]]; then
    printf '%s' "$1" | xclip -i -selection clipboard 2>/dev/null || log "WARN: xclip -i failed"
  else
    printf '%s' "$1" | wl-copy 2>/dev/null || log "WARN: wl-copy failed"
  fi
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

# Order matters: the Chrome-profile storage that gemini.js reads is per profile,
# so a same-profile window must win before any other-profile window. The
# browser-window fallback (no PWA installed in that profile) still pastes
# correctly because gemini.js consumes the payload in a background tab.
activate_gemini() {
  if { [[ -n "$GEMINI_WMCLASS2" ]] && activate_window_by activateByWmClass "$GEMINI_WMCLASS2"; } \
    || { [[ -n "$GEMINI_WMCLASS" ]] && activate_window_by activateByWmClass "$GEMINI_WMCLASS"; } \
    || activate_window_by_title "$GEMINI_TITLE_NEEDLE"; then
    return 0
  fi
  # No dedicated Gemini PWA window (it only exists in the Default profile).
  # The paste itself still happens: gemini.js consumes the queued payload in any
  # gemini.google.com tab of the same profile (Chrome storage events fire even
  # for background tabs). Bring the browser forward so the user sees the result.
  if [[ -n "$BROWSER_WMCLASS" ]] && activate_window_by activateByWmClass "$BROWSER_WMCLASS"; then
    log "WARN: Gemini PWA window not found; focused the browser instead (payload pasted in its Gemini tab)"
    return 0
  fi
  log "WARN: could not activate Gemini window (extension installed/enabled? title contains '$GEMINI_TITLE_NEEDLE'?)"
  return 1
}

# Bring the Brave/YouTube window forward so the trigger keystroke lands in it
# even when Brave is not the focused window. Non-fatal: if activation fails
# (extension missing, no matching title), we still type the trigger into
# whatever is focused, preserving the old behaviour.
# ----------------------------------------------------------------------------
# Failure diagnosis
# ----------------------------------------------------------------------------
# "timed out" is the only thing a clipboard poll can tell us, but it is the
# symptom, not the cause: the trigger never reaching the page, a press with no
# thumbnail under the cursor, and the extension being disabled all look the
# same. content.js already records which one happened in `copyurlTrace` (its
# chrome.storage.local, on disk), so read it back and say which.
#
# The trace is LevelDB, but the values are plain JSON in the log file, so a
# regex over the raw bytes is enough and needs no python/leveldb dependency.
# Sets DIAGNOSIS_HINT to the action the user should take, so the notification
# can name the real cause instead of always blaming the hover.
DIAGNOSIS_HINT=""
diagnose_copy_failure() {
  local since="$1" file hits line
  DIAGNOSIS_HINT="Hover a YouTube thumbnail and press again."
  # 2s of grace, applied before either comparison: the timestamp is written by
  # the browser process and compared here, and ISO timestamps are truncated to
  # the second, so a trace caused by this very press can be stamped at or just
  # before the press second. Without the slack, both `find -newermt` and the
  # `ts >= since` test intermittently discard the trace that proves what
  # happened. Genuinely stale triggers are minutes old, so 2s costs nothing.
  since=$(( since - 2 ))
  # Only files belonging to THIS extension. Every installed extension gets its
  # own `Local Extension Settings/<id>/` dir, so scanning the whole tree means
  # any other extension writing at press time (a password manager, an ad
  # blocker, AnythingLLM...) looks like "the extension responded but ignored the
  # key" and the diagnosis blames a stale content script. Live log 2026-10-26
  # 13:17:58 hit exactly that: five unrelated extensions wrote within the
  # window while ours wrote nothing.
  #
  # The id is path-derived for an unpacked extension, so it differs per machine
  # and per install location. Rather than hardcode it, match the trace key that
  # only content.js ever writes.
  local -a files=()
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    grep -qa 'copyurlTrace' "$file" 2>/dev/null || continue
    files+=("$file")
  done < <(
    local root
    for root in $COPYURL_PROFILE_ROOTS; do
      [[ -d "$root" ]] || continue
      find "$root" -path '*/Local Extension Settings/*' -name '*.log' \
        -newermt "@$since" 2>/dev/null
    done
  )

  if (( ${#files[@]} == 0 )); then
    log "diagnosis: no extension trace written since the press"
    if (( ${ACTIVATION_OK:-0} )); then
      # The window came forward, so the keystroke had a browser to land in but
      # no page received it. In Aside's split view the window can be raised
      # while its CHATS pane keeps keyboard focus, so the trigger types into
      # that pane instead of the YouTube tab. This is by far the most common
      # real-world failure (75 of 80 in the field log), and calling it "the
      # extension did not respond" sends the reader to reload a tab that was
      # never the problem.
      log "diagnosis: the browser window WAS raised, so the trigger was typed into it but no page saw it"
      log "diagnosis: keyboard focus is on another pane/tab of that window (Aside split view: the Chats pane keeps focus)"
      DIAGNOSIS_HINT="Click the YouTube page itself (so the video page has focus, not a side pane), then press Alt+A again."
      return 0
    fi
    log "diagnosis: the trigger never reached content.js (extension disabled or removed from this profile? wrong browser profile?)"
    DIAGNOSIS_HINT="The extension did not respond. Is it enabled in this browser profile, and is a YouTube tab open?"
    return 0
  fi

  # Only triggers recorded at or after the press count: a file that was touched
  # by an unrelated event (blur/focus) still contains older triggers, and
  # reporting one of those would name the wrong cause.
  local raw ts
  hits=""
  while IFS= read -r raw; do
    ts="$(sed -n 's/.*"ts":"\([^"]*\)".*/\1/p' <<<"$raw")"
    [[ -n "$ts" ]] || continue
    (( $(date -d "$ts" +%s 2>/dev/null || echo 0) >= since )) || continue
    hits+="$raw"$'\n'
  done < <(grep -hao '"event":"trigger"[^}]*}' "${files[@]}" 2>/dev/null)
  if [[ -z "$hits" ]]; then
    # The file changed, but no trigger was recorded for THIS press. Either the
    # key reached the page and content.js ignored it (a stale content script
    # that predates the current listener), or the write is still in flight.
    log "diagnosis: extension storage changed but no trigger was recorded for this press"
    log "diagnosis: the key may have reached the page without content.js handling it (reload the YouTube tab to re-inject it)"
    DIAGNOSIS_HINT="Reload the YouTube tab (the extension's content script looks stale)."
    return 0
  fi

  line="$(printf '%s' "${hits%$'\n'}" | tail -1)"
  local hovered focused key at
  # hovered is either a JSON string ("...") or the bare literal null.
  hovered="$(sed -n 's/.*"hovered":\(null\|"[^"]*"\).*/\1/p' <<<"$line")"
  hovered="${hovered#\"}"; hovered="${hovered%\"}"
  focused="$(sed -n 's/.*"focused":\(true\|false\).*/\1/p' <<<"$line")"
  key="$(sed -n 's/.*"key":"\([^"]*\)".*/\1/p' <<<"$line")"
  at="$(sed -n 's/.*"at":"\([^"]*\)".*/\1/p' <<<"$line")"

  log "diagnosis: extension saw key=$key focused=$focused hovered=${hovered:-unknown} under-cursor=${at:-unknown}"
  if [[ "$hovered" == "null" || -z "$hovered" ]]; then
    log "diagnosis: NO VIDEO UNDER THE CURSOR at press time (hover a thumbnail and press again)"
    if [[ -n "$at" ]]; then
      log "diagnosis: the cursor was over '$at', which is not inside a thumbnail link"
      DIAGNOSIS_HINT="No video under the cursor (it was over '$at'). Hover a thumbnail and press again."
    else
      DIAGNOSIS_HINT="No video under the cursor. Hover a thumbnail and press again."
    fi
  elif [[ "$focused" == "false" ]]; then
    log "diagnosis: a video was hovered but the page did not have focus, so the key went elsewhere"
    DIAGNOSIS_HINT="A video was hovered but the page lost focus. Click the page, then press again."
  else
    log "diagnosis: the extension DID have a hovered video and the page was focused, so the copy failed after the key arrived (clipboard write blocked?)"
    DIAGNOSIS_HINT="The copy failed even though the video was found. Check that xclip/wl-clipboard works, then try again."
  fi
  return 0
}

activate_youtube() {
  # Two windows can share BROWSER_WMCLASS (Aside runs YouTube in one window and
  # Gemini in another: README "separate Aside window"; or a split pane). Raising
  # by class grabs the most recently used of them, which may be the Gemini
  # window — and then the trigger types into a window with no YouTube page.
  # Every field aside-failure (28/28) short-circuited here and never tried the
  # title, so ALWAYS also attempt the title match: it steers focus to a window
  # whose title actually says YouTube. Class first because a title match can hit
  # a Gemini chat whose title mentions YouTube after a summary.
  local class_ok=0
  if [[ -n "$BROWSER_WMCLASS" ]] && activate_window_by activateByWmClass "$BROWSER_WMCLASS"; then
    class_ok=1
  fi
  # " - YouTube" (watch/search pages: "<title> - YouTube ...") avoids windows
  # that merely mention YouTube, e.g. a Gemini chat; fall back to the plain
  # needle for the home page, whose title is just "YouTube".
  if activate_window_by_title " - $YOUTUBE_TITLE_NEEDLE" \
    || activate_window_by_title "$YOUTUBE_TITLE_NEEDLE"; then
    return 0
  fi
  if (( class_ok )); then
    # The window came forward but no YouTube-titled window was focusable: the
    # trigger may land in the wrong pane/tab. Tell the caller (which still types
    # and lets the copy-wait + diagnosis decide) AND remember it for the hint.
    vlog "raised by class, but no window titled '*$YOUTUBE_TITLE_NEEDLE*' is focusable"
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
  # ACTIVATION_OK feeds the failure diagnosis: raising the browser window is
  # NOT the same as giving the YouTube tab keyboard focus, and only the latter
  # lets the trigger keystroke reach content.js. Keeping the two apart stops the
  # diagnosis from blaming the extension when the key went to a different pane.
  ACTIVATION_OK=0
  if activate_youtube; then
    ACTIVATION_OK=1
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
  local original_clip press_epoch
  press_epoch=$(date +%s)
  original_clip="$(clip_get)"

  if ! copy_url_from_browser; then
    # Restore whatever the user had before we wrote the sentinel.
    [[ -n "$original_clip" ]] && clip_set "$original_clip"
    diagnose_copy_failure "$press_epoch"
    die "URL copy failed. $DIAGNOSIS_HINT ($key)"
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
