#!/usr/bin/env bash
# Hermetic unit tests for the Linux orchestrator (Linux/copyurl.sh).
#
# The other Linux tests need a real desktop: run_e2e.mjs needs a browser,
# run_full_system.mjs needs Wayland + ydotoold. This one needs nothing but bash.
# It runs the GENUINE copyurl.sh with every external program replaced by a PATH
# shim (ydotool, xclip, wl-copy, wl-paste, gdbus, notify-send) and a clipboard
# that is just a file, then asserts on the script's exit code, log lines, and
# the exact clipboard writes it performed.
#
# Covered (all of these have broken in the field at least once):
#   - success path: sentinel reset -> trigger -> youtube URL detected -> Gemini focused
#   - retry: first trigger ignored, second succeeds
#   - total failure: exit 1, "URL copy failed", user's clipboard restored
#   - same video twice in a row (the sentinel's whole reason to exist)
#   - --aside: trigger "[" instead of "]", no Gemini focus
#   - clipboard backend selection: xclip when DISPLAY+xclip, wl-* otherwise
#   - dependency checking: xclip alone is enough, wl-clipboard alone is enough,
#     neither is an error, and choosing the wl backend warns about flicker
#   - failure diagnosis: distinguishes "key never arrived", "no video hovered"
#     and "hovered but unfocused" using the extension's on-disk trace
#
# Usage: tests/linux/run_copyurl_unit.sh        (exit 0 = all pass)

set -uo pipefail

cd "$(dirname "$0")/../.." || exit 2
ROOT="$PWD"
SCRIPT="$ROOT/Linux/copyurl.sh"
URL_A="https://www.youtube.com/watch?v=dQw4w9WgXcQ"
URL_B="https://www.youtube.com/watch?v=aaaaaaaaaaa"

fail=0
note() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  PASS  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }

[[ -f "$SCRIPT" ]] || { bad "missing $SCRIPT"; exit 1; }

# ---------------------------------------------------------------------------
# Sandbox: shims + a file-backed clipboard, one directory per scenario.
# ---------------------------------------------------------------------------
new_sandbox() {
  SB="$(mktemp -d "${TMPDIR:-/tmp}/cu_unit.XXXXXX")"
  mkdir -p "$SB/bin" "$SB/state"
  : >"$SB/clip"          # current clipboard contents
  : >"$SB/clip_writes"   # every payload written by clip_set, one per line
  : >"$SB/shim_calls"    # every shim invocation
  : >"$SB/triggers"      # every character ydotool was asked to type
  : >"$SB/responses"     # one line per trigger: "-" = ignore, else the URL to copy
  echo 0 >"$SB/trigger_count"

  # gdbus: Activate Window By Title. Report success and a sort order.
  cat >"$SB/bin/gdbus" <<'SH'
#!/usr/bin/env bash
echo "gdbus $*" >>"$CU_SB/shim_calls"
# CU_ACTIVATION_FAILS=1 makes every activation report not-found, so the
# "browser window never came forward" branch of the diagnosis can be tested.
# CU_TITLE_FAILS=1 makes only the *title* (activateBySubstring) activations
# fail while class (activateByWmClass) activations still succeed — the case
# where class raised a window but no YouTube-titled window is focusable.
case "$*" in
  *setSortOrder*) echo "('highest_user_time',)" ;;
  *activateBySubstring*)
    [[ "${CU_ACTIVATION_FAILS:-0}${CU_TITLE_FAILS:-0}" == "00" ]] && echo "(true,)" || echo "(false,)" ;;
  *) [[ "${CU_ACTIVATION_FAILS:-0}" == "1" ]] && echo "(false,)" || echo "(true,)" ;;
esac
SH

  # ydotool: record the typed char, then play the next scripted response.
  cat >"$SB/bin/ydotool" <<'SH'
#!/usr/bin/env bash
echo "ydotool $*" >>"$CU_SB/shim_calls"
[[ "${1:-}" == "type" ]] || exit 0
printf '%s' "${2:-}" >>"$CU_SB/triggers"
n=$(( $(cat "$CU_SB/trigger_count") + 1 ))
echo "$n" >"$CU_SB/trigger_count"
resp="$(sed -n "${n}p" "$CU_SB/responses" 2>/dev/null)"
if [[ -n "$resp" && "$resp" != "-" ]]; then printf '%s' "$resp" >"$CU_SB/clip"; fi
exit 0
SH

  # xclip: -o prints the clipboard, -i stores stdin (recording each write).
  cat >"$SB/bin/xclip" <<'SH'
#!/usr/bin/env bash
echo "xclip $*" >>"$CU_SB/shim_calls"
case "${1:-}" in
  -o) cat "$CU_SB/clip" 2>/dev/null; exit 0 ;;
  -i) payload="$(cat)"
      printf '%s' "$payload" >"$CU_SB/clip"
      printf '%s\n' "$payload" >>"$CU_SB/clip_writes"
      exit 0 ;;
esac
exit 0
SH

  # wl-clipboard fallback backend.
  cat >"$SB/bin/wl-paste" <<'SH'
#!/usr/bin/env bash
echo "wl-paste $*" >>"$CU_SB/shim_calls"
cat "$CU_SB/clip" 2>/dev/null
exit 0
SH
  cat >"$SB/bin/wl-copy" <<'SH'
#!/usr/bin/env bash
echo "wl-copy $*" >>"$CU_SB/shim_calls"
payload="$(cat)"
printf '%s' "$payload" >"$CU_SB/clip"
printf '%s\n' "$payload" >>"$CU_SB/clip_writes"
exit 0
SH

  cat >"$SB/bin/notify-send" <<'SH'
#!/usr/bin/env bash
echo "notify-send $*" >>"$CU_SB/shim_calls"
exit 0
SH

  chmod +x "$SB"/bin/*

  # Restricted coreutils PATH: only the utilities copyurl.sh actually calls.
  # Without this, "xclip is absent" can't be simulated — the real /usr/bin/xclip
  # would be found and the wl-clipboard fallback would never be exercised.
  mkdir -p "$SB/core"
  for u in bash date stat mkdir mv sed cat grep id sleep timeout bc dirname \
           basename uname mktemp tail head awk tr sort find; do
    src="$(command -v "$u" 2>/dev/null)" && ln -s "$src" "$SB/core/$u"
  done
  # Deterministic backend selection: copyurl.sh prefers xclip only when DISPLAY
  # is set, so pin it here instead of inheriting the caller's environment (CI
  # has no DISPLAY, which silently switched every scenario to the wl backend).
  export DISPLAY=:0
  export CU_SB="$SB"
  export XDG_STATE_HOME="$SB/state"
  export COPYURL_LOG_FILE="$SB/copyurl_log.txt"
  export COPYURL_VERBOSE=1
  # Collapse the real-time waits; the logic under test is the loop, not the clock.
  export COPYURL_TRIGGER_SETTLE_DELAY=0
  export COPYURL_BROWSER_FOCUS_DELAY=0
  export COPYURL_GEMINI_FOCUS_DELAY=0
  export COPYURL_CLIP_TIMEOUT=0.2
  export COPYURL_CLIP_POLL=0.01
  export COPYURL_NOTIFY=0
  # No real extension storage: diagnosis must only see what a scenario writes.
  export COPYURL_PROFILE_ROOTS="$SB/profiles"
  # Activate Window By Title needs a session bus; the shim ignores the call.
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$SB/no-bus}"
  rm -f "$COPYURL_LOG_FILE"
}

# run_flow_scenario <clipboard-before> <responses-file-content> [args...]
run_flow_scenario() {
  local before="$1" responses="$2"
  shift 2
  printf '%s' "$before" >"$SB/clip"
  printf '%s\n' "$responses" >"$SB/responses"
  echo 0 >"$SB/trigger_count"   # each scenario starts at its first trigger
  : >"$SB/shim_calls"
  : >"$SB/triggers"
  : >"$SB/clip_writes"
  rm -f "$COPYURL_LOG_FILE"
  PATH="$SB/bin:$SB/core" bash "$SCRIPT" "$@" >"$SB/stdout" 2>"$SB/stderr"
  RC=$?
}

log_has()     { grep -qF -- "$1" "$COPYURL_LOG_FILE" 2>/dev/null; }
expect_log()  { if log_has "$1"; then ok "log: $1"; else bad "log missing: $1"; fi; }
expect_nolog() { if log_has "$1"; then bad "log should NOT contain: $1"; else ok "log absent: $1"; fi; }
expect_rc()   { if [[ "$RC" == "$1" ]]; then ok "exit $1"; else bad "exit $RC (expected $1)"; fi; }
expect_clip() { local got; got="$(cat "$SB/clip")"
  if [[ "$got" == "$1" ]]; then ok "clipboard = $1"; else bad "clipboard = '$got' (expected '$1')"; fi; }

# ---------------------------------------------------------------------------
note "syntax + help"
if bash -n "$SCRIPT"; then ok "bash -n Linux/copyurl.sh"; else bad "bash -n Linux/copyurl.sh"; fi
new_sandbox
PATH="$SB/bin:$SB/core" bash "$SCRIPT" --help >"$SB/help" 2>&1
if grep -q -- '--aside' "$SB/help"; then ok "--help lists --aside"; else bad "--help output unexpected"; fi

# ---------------------------------------------------------------------------
note "success path (xclip backend)"
new_sandbox
run_flow_scenario "user-clipboard-before" "$URL_A"
expect_rc 0
expect_log "Alt+A fired (target=gemini"
expect_log "copy attempt 1: typing trigger ']'"
expect_log "copy attempt 1: clipboard changed -> $URL_A"
expect_log "done; sent url=$URL_A"
expect_clip "$URL_A"
if grep -q '^xclip -o' "$SB/shim_calls" && ! grep -q '^wl-paste' "$SB/shim_calls"; then
  ok "used xclip (no focus-stealing wl-paste)"
else
  bad "expected xclip polling, got: $(grep -E '^(xclip|wl-paste)' "$SB/shim_calls" | sort -u | tr '\n' ' ')"
fi
# activate_youtube must attempt BOTH: raise by class first, then steer by title
# (a class match can hit a Gemini Aside window; the title match finds YouTube).
# Both are vlog()'d by activate_window_by, so assert on the log.
expect_log "activateByWmClass('org.asidelinux.Browser') -> (true,)"
expect_log "activateBySubstring(' - YouTube') -> (true,)"
# The sentinel must be written BEFORE the trigger, or a same-URL re-copy is
# undetectable and every second press times out.
first_write="$(sed -n 1p "$SB/clip_writes")"
if [[ "$first_write" == __copyurl_sentinel_* ]]; then
  ok "clipboard reset to a sentinel before the trigger"
else
  bad "first clipboard write was not a sentinel: '$first_write'"
fi
if [[ "$(cat "$SB/triggers")" == "]" ]]; then ok "typed ']' once"; else bad "typed '$(cat "$SB/triggers")' (expected ']')"; fi
if log_has "activateByWmClass('chrome-gdfaincndogidkdcdkhapmbffkckdkhn-Profile_2')"; then
  ok "tried the non-Default Gemini profile first"
else
  bad "Gemini profile-2 window was not tried first"
fi

# ---------------------------------------------------------------------------
note "retry: first trigger ignored, second succeeds"
new_sandbox
run_flow_scenario "user-clipboard-before" "-
$URL_B"
expect_rc 0
expect_log "copy attempt 1: timed out after 0.2s"
expect_log "copy attempt 2: clipboard changed -> $URL_B"
expect_log "done; sent url=$URL_B"
expect_clip "$URL_B"

# ---------------------------------------------------------------------------
note "total failure: exit 1 + user clipboard restored"
new_sandbox
run_flow_scenario "my-precious-text" "-
-"
expect_rc 1
expect_log "copy attempt 2: timed out"
expect_log "ERROR: URL copy failed."
expect_clip "my-precious-text"
if grep -q '^notify-send' "$SB/shim_calls"; then ok "error notified"; else bad "error did not notify"; fi

# ---------------------------------------------------------------------------
note "stale clipboard must not count as success (sentinel's real purpose)"
# The clipboard already holds a youtube URL and the trigger does nothing. Without
# the sentinel reset the poll would see "a youtube URL is present" and report a
# copy that never happened, sending a stale video to Gemini.
new_sandbox
run_flow_scenario "$URL_A" "-
-"
expect_rc 1
expect_log "ERROR: URL copy failed."
expect_nolog "clipboard changed ->"
expect_clip "$URL_A"

# ---------------------------------------------------------------------------
note "same video twice in a row (sentinel regression)"
new_sandbox
run_flow_scenario "x" "$URL_A"
if [[ "$RC" == 0 ]] && log_has "done; sent url=$URL_A"; then ok "first copy ok"; else bad "first copy failed (rc=$RC)"; fi
: >"$COPYURL_LOG_FILE"
run_flow_scenario "$URL_A" "$URL_A"   # clipboard ALREADY holds the URL
if [[ "$RC" == 0 ]] && log_has "clipboard changed -> $URL_A"; then
  ok "second copy of the same URL still detected"
else
  bad "re-copying the same URL timed out (sentinel broken?)"
fi

# ---------------------------------------------------------------------------
note "--aside: '[' trigger, no Gemini focus"
new_sandbox
run_flow_scenario "user-clipboard-before" "$URL_A" --aside
expect_rc 0
expect_log "Alt+Z fired (target=aside"
expect_log "copy attempt 1: typing trigger '['"
expect_log "done; sent to Aside url=$URL_A"
expect_nolog "activateByWmClass('chrome-gdfaincndogidkdcdkhapmbffkckdkhn-Profile_2')"
if [[ "$(cat "$SB/triggers")" == "[" ]]; then ok "typed '['"; else bad "typed '$(cat "$SB/triggers")' (expected '[')"; fi

# ---------------------------------------------------------------------------
note "backend selection: wl-* when xclip is absent"
new_sandbox
rm -f "$SB/bin/xclip"
export DISPLAY=:0          # Xwayland present but no xclip installed
run_flow_scenario "user-clipboard-before" "$URL_A"
expect_rc 0
if grep -q '^wl-paste' "$SB/shim_calls"; then ok "fell back to wl-paste"; else bad "wl-paste fallback not used"; fi
expect_clip "$URL_A"

# ---------------------------------------------------------------------------
note "backend selection: wl-* when there is no X display at all"
new_sandbox
unset DISPLAY              # pure Wayland, no Xwayland: xclip is unusable
run_flow_scenario "user-clipboard-before" "$URL_A"
expect_rc 0
if grep -q '^wl-paste' "$SB/shim_calls"; then ok "used wl-paste"; else bad "wl-paste not used without DISPLAY"; fi

# ---------------------------------------------------------------------------
note "deps: xclip alone is enough (no wl-clipboard)"
new_sandbox
rm -f "$SB/bin/wl-copy" "$SB/bin/wl-paste"
export DISPLAY=:0
run_flow_scenario "user-clipboard-before" "$URL_A"
expect_rc 0
expect_log "done; sent url=$URL_A"
expect_clip "$URL_A"

# ---------------------------------------------------------------------------
note "deps: wl-clipboard alone is enough (no xclip)"
new_sandbox
rm -f "$SB/bin/xclip"
export DISPLAY=:0
run_flow_scenario "user-clipboard-before" "$URL_A"
expect_rc 0
expect_log "done; sent url=$URL_A"

# ---------------------------------------------------------------------------
note "deps: neither clipboard tool -> fail with install guidance"
new_sandbox
rm -f "$SB/bin/xclip" "$SB/bin/wl-copy" "$SB/bin/wl-paste"
run_flow_scenario "user-clipboard-before" "$URL_A"
expect_rc 1
if grep -q 'Missing a clipboard tool' "$SB/stderr"; then ok "says a clipboard tool is missing"; else bad "unhelpful error: $(cat "$SB/stderr")"; fi
if grep -q 'apt install xclip' "$SB/stderr"; then ok "suggests installing xclip"; else bad "no xclip suggestion"; fi

# ---------------------------------------------------------------------------
note "deps: wl backend warns about flicker (log + stderr)"
new_sandbox
rm -f "$SB/bin/xclip"
export DISPLAY=:0
export WAYLAND_DISPLAY=wayland-0
run_flow_scenario "user-clipboard-before" "$URL_A"
expect_rc 0
if grep -q 'may flicker' "$SB/stderr"; then ok "stderr warns about flicker"; else bad "no flicker warning on stderr"; fi
expect_log "WARN: clipboard backend=wl"

# ---------------------------------------------------------------------------
note "deps: no flicker warning when xclip is used"
new_sandbox
export DISPLAY=:0
export WAYLAND_DISPLAY=wayland-0
run_flow_scenario "user-clipboard-before" "$URL_A"
expect_rc 0
expect_nolog "clipboard backend=wl"
if grep -q 'may flicker' "$SB/stderr"; then bad "warned about flicker while using xclip"; else ok "no spurious flicker warning"; fi

# ---------------------------------------------------------------------------
note "deps: xclip installed but DISPLAY unset names that cause"
new_sandbox
unset DISPLAY
export WAYLAND_DISPLAY=wayland-0
run_flow_scenario "user-clipboard-before" "$URL_A"
expect_rc 0
if grep -q 'DISPLAY is unset' "$SB/stderr"; then ok "explains DISPLAY is unset"; else bad "wrong cause reported: $(cat "$SB/stderr")"; fi
# xclip IS installed here, so telling the user to install it would be wrong advice.
if grep -q 'apt install xclip' "$SB/stderr"; then bad "told the user to install xclip, but it is installed"; else ok "does not suggest installing an already-installed xclip"; fi

# ---------------------------------------------------------------------------
# Failure diagnosis. A clipboard poll can only say "timed out"; these assert the
# log says WHY, by reading the same copyurlTrace content.js writes to disk.
# trace_write <json> ; creates a fresh trace file. Any literal @TS@ in the JSON
# is replaced with "now", because the script only counts triggers recorded at or
# after the press (an older trigger would name the wrong cause).
trace_write() {
  trace_write_ago 0 "$1"
}

# Write a trace stamped N seconds in the past. Used to pin the sub-second race:
# ISO timestamps are truncated to the second and `find -newermt` is strict, so a
# trace caused by the press itself can be stamped at or just before the press
# second. That used to intermittently discard it and report the wrong cause.
# The real extension storage holds the `copyurlTrace` key, and copyurl.sh uses
# that key to tell OUR extension's files from every other installed extension's.
# Fixtures must therefore carry it, or the diagnosis skips them.
trace_write_ago() {
  local ago="$1" dir="$SB/profiles/Default/Local Extension Settings/gnkpcpmnkhflhbnoblakgdohadhnlljo"
  mkdir -p "$dir"
  printf 'copyurlTrace\0%s' "${2//@TS@/$(date -u -d "@$(( $(date +%s) - ago ))" +%Y-%m-%dT%H:%M:%S.000Z)}" >"$dir/000003.log"
}

# A DIFFERENT extension's storage, written now. copyurl.sh must ignore it: only
# our own extension's silence means "the trigger never arrived".
other_ext_write() {
  local dir="$SB/profiles/Default/Local Extension Settings/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  mkdir -p "$dir"
  printf 'someOtherKey\0{"event":"x","ts":"%s"}' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" >"$dir/000003.log"
}

note "diagnosis: key never reached the page (no trace written)"
# The window raises fine here, so this is the focus case, not a dead extension:
# the two used to share one message, which blamed the extension for a pane that
# simply had the focus. The activation-failure case below covers the other side.
new_sandbox
run_flow_scenario "before" "-
-"
expect_rc 1
expect_log "diagnosis: no extension trace written since the press"
expect_log "the browser window WAS raised"
expect_log "Click the YouTube page itself"

note "diagnosis: no video under the cursor"
new_sandbox
trace_write '{"event":"trigger","focused":true,"hovered":null,"key":"BracketRight","at":"DIV#content","ts":"@TS@"}'
run_flow_scenario "before" "-
-"
expect_rc 1
expect_log 'diagnosis: extension saw key=BracketRight focused=true hovered=null'
expect_log "diagnosis: NO VIDEO UNDER THE CURSOR at press time"
expect_log "the cursor was over 'DIV#content'"
expect_log "No video under the cursor (it was over 'DIV#content')"

note "diagnosis: a trace stamped in the same second as the press still counts"
new_sandbox
trace_write_ago 1 '{"event":"trigger","focused":true,"hovered":null,"key":"BracketRight","at":"DIV#content","ts":"@TS@"}'
run_flow_scenario "before" "-
-"
expect_rc 1
expect_log "diagnosis: NO VIDEO UNDER THE CURSOR at press time"

note "diagnosis: video hovered but page unfocused"
new_sandbox
trace_write '{"event":"trigger","focused":false,"hovered":"https://www.youtube.com/watch?v=dQw4w9WgXcQ","key":"BracketRight","ts":"@TS@"}'
run_flow_scenario "before" "-
-"
expect_rc 1
expect_log "a video was hovered but the page did not have focus"
expect_log "the page lost focus. Click the page"

note "diagnosis: key arrived, video hovered, page focused -> copy failed later"
new_sandbox
trace_write '{"event":"trigger","focused":true,"hovered":"https://www.youtube.com/watch?v=dQw4w9WgXcQ","key":"BracketRight","ts":"@TS@"}'
run_flow_scenario "before" "-
-"
expect_rc 1
expect_log "the copy failed after the key arrived"
expect_log "Check that xclip/wl-clipboard works"

note "diagnosis: trigger typed into the raised window but no page saw it"
new_sandbox
run_flow_scenario "before" "-
-"
expect_rc 1
expect_log "no extension trace written since the press"
expect_log "the browser window WAS raised"
expect_log "keyboard focus is on another pane/tab"
expect_log "Click the YouTube page itself"
expect_nolog "The extension did not respond"

note "activate_youtube: class succeeds but the YouTube title is unfocusable"
new_sandbox
CU_TITLE_FAILS=1 run_flow_scenario "user-clipboard-before" "$URL_A"
expect_rc 0
# Class activation still won, so the flow proceeds and the copy succeeds — the
# title fallback is best-effort steering, not a gate. But the mismatch is logged
# so a future "trigger went to the wrong pane" failure can be diagnosed.
expect_log "raised by class, but no window titled '*YouTube*' is focusable"
expect_log "done; sent url=$URL_A"

note "diagnosis: activation failed, so the extension is not to blame for silence"
new_sandbox
CU_ACTIVATION_FAILS=1 run_flow_scenario "before" "-
-"
expect_rc 1
expect_log "no extension trace written since the press"
expect_log "The extension did not respond"
expect_nolog "the browser window WAS raised"

note "diagnosis: another extension writing must not look like ours responding"
new_sandbox
other_ext_write
run_flow_scenario "before" "-
-"
expect_rc 1
# Ours wrote nothing, so the "no trace" verdict must stand. Reading the other
# extension's file would instead produce "no trigger was recorded for this
# press", i.e. it would claim our extension answered and ignored the key.
expect_log "no extension trace written since the press"
expect_nolog "no trigger was recorded for this press"

note "diagnosis: extension storage touched but no trigger recorded"
new_sandbox
trace_write '{"event":"focus","page":"/","ts":"@TS@"}'
run_flow_scenario "before" "-
-"
expect_rc 1
expect_log "no trigger was recorded for this press"
expect_log "Reload the YouTube tab"

note "diagnosis: newest trigger wins when several are present"
new_sandbox
trace_write '{"event":"trigger","focused":true,"hovered":null,"key":"BracketRight","ts":"@TS@"}
{"event":"trigger","focused":true,"hovered":"https://www.youtube.com/watch?v=dQw4w9WgXcQ","key":"BracketRight","ts":"@TS@"}'
run_flow_scenario "before" "-
-"
expect_rc 1
expect_log "the copy failed after the key arrived"
expect_log "Check that xclip/wl-clipboard works"

note "Summary"
if (( fail == 0 )); then echo "  ALL GREEN"; else echo "  FAILURES ABOVE"; fi
exit "$fail"
