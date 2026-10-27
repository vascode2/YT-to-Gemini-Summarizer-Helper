# CopyURL contract

One behavior, four implementations (Windows `copy.ahk`, macOS `Mac/hammerspoon/init.lua`, Linux `Linux/copyurl.sh`, and the shared extension `content.js`/`gemini.js`). Each platform hand-rolls the same flow; drift between them is the single biggest source of silent bugs (macOS has reverted fixes 3×). This file is the shared invariant every implementation — and its tests — must honor.

## The flow (invariant)

```
hover a YouTube thumbnail → press the hotkey → the hovered URL, plus the
summary suffix, reaches the Gemini/app composer → the message is sent
```

Observable end state, in order of precedence:

1. **The copied URL is the one under the cursor at press time.** Moving the mouse
   after the press must not change what is copied (Windows pins `origX/origY`);
   a stale `hoveredVideoUrl` must not win over the press-time thumbnail.
2. **No default browser/profile changes.** Windows and Linux send through
   behavior already configured by the user (Gemini desktop app vs PWA, Aside
   panel); macOS targets the native `com.google.GeminiMacOS` app. A new browser
   must not pop up, and the user's clipboard is restored on failure.
3. **Failure is diagnosed, not just reported.** A failed copy names the leg that
   failed (no extension trace → `extension-silent` / `beacon=none`; no hover →
   no-video; wrong pane → "click the page"; clipboard blocked → write-failed).
   A bare "timed out" is never the final user-facing message.

## Platform mapping

| Step | Windows (`copy.ahk`) | macOS (`init.lua`) | Linux (`copyurl.sh`) | Shared extension |
|---|---|---|---|---|
| Trigger | `$!a::` (F24 to content.js, title beacon) | Option+Z → `]` keystroke | Alt+A → `ydotool type "]"` | `content.js` acts on key while hovering |
| Copy detect | AHK polls clipboard, reads `beacon=` from title | Hammerspoon polls pasteboard, `beacon=` from title | `copyurl.sh` polls `wl-paste` / `xclip -o` | writes URL to clipboard |
| Handoff | UIA fill Gemini desktop composer | AX `AXValue` set into native-app composer | `chrome.storage` → `gemini.js` inserts + clicks send | `content.js` queues URL+`PASTE_SUFFIX` |
| Summary suffix | `한국어로 요약해 줘` | `한국어로 요약해 줘` | `한국말로 요약해줘` (== `PASTE_SUFFIX`) | `PASTE_SUFFIX` in `content.js` |

> The suffix string differs per platform by design; the tests read it from
> `content.js` (`readPasteSuffix()`) rather than hardcoding, so rewording cannot
> silently desync them while a wrong URL still fails.

## What the tests must assert (shared contract)

Each platform's test suite asserts the same six things, adapted to its harness:

1. Press is detected (no dropped hotkey — the parenthetical in `Alt+Z (Aside)`
   regression).
2. Hovered URL flows all the way to the composer (cross-page handoff, not just
   clipboard).
3. Send fires exactly once, and never while the composer is disabled/empty.
4. A failure names the failing leg (mode classification, not a bare timeout).
5. The clipboard is restored after a failed copy.
6. Success rate is floor-checked per target browser (rate guard), so a
   platform-specific regression like Aside 50% cannot hide in a blended number.

## Where each platform is covered today

- **Linux**: hermetic `tests/linux/run_copyurl_unit.sh` + full-system
  `tests/e2e/run_full_system.mjs` + `scripts/analyze_log.py` + `rate_guard.py`.
  Fullest coverage.
- **Windows**: logic covered indirectly — `tests/test_analyze_log.py` pins the
  Windows `DebugLog` line shapes (beacon states, `Sent to …`, send-failure).
  The AHK script itself has no automated runner (no Windows CI); manual
  tray-reload + log read.
- **macOS**: `Mac/check_live_sync.sh` detects when the live `~/.hammerspoon/
  init.lua` drifts from the repo (it has reverted fixes 3×). No macOS CI yet
  (issue #4).
- **Extension**: `tests/e2e/run_e2e.mjs` loads the real unpacked extension and
  drives hover → trigger → Gemini handoff; the headless `gemini.js` DOM mock
  covers paste/submit.
