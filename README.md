# YouTube-to-Gemini Helper

![Sample output](docs/sample-output.png)

> 📖 **[See this for a visually explained README](https://vascode2.github.io/YouTube-to-Gemini-Helper/docs/youtube-to-gemini-helper-explainer.html)**

**How it was built:** [docs/project-build-presentation.html](docs/project-build-presentation.html) — narrative from the Cursor chat that shaped the extension, AutoHotkey, and Gemini workflow.

**macOS?** A Hammerspoon port with the same workflow (cursorless, auto-test URL handlers, file logging at `~/Library/Logs/CopyURL.log`) lives in [Mac/](Mac/) — see [Mac/README.md](Mac/README.md). Hotkey is **Option+Z**.

**Linux?** An Ubuntu / GNOME Wayland port (`ydotool` + `wl-clipboard` + the *Activate Window By Title* GNOME extension) lives in [Linux/](Linux/) — see [Linux/README.md](Linux/README.md). Linux also uses **Alt+A**, through its separately configured GNOME custom shortcut. It raises the Brave/YouTube window before sending the trigger, so Alt+A works even when Brave isn't the focused window.

**Repo hooks:** This repo ships a `pre-commit` hook in [.githooks/pre-commit](.githooks/pre-commit) that auto-refreshes a "Recent activity" footer in `README.md`, `CLAUDE.md`, and `docs/troubleshooting.md` on every commit. After cloning, run once:
```sh
git config core.hooksPath .githooks
```

## Workflow

1. Open YouTube in Brave, Chrome, or Aside with the extension enabled.
2. Hover the video thumbnail.
3. Press a hotkey:
   - **Alt+A** — Windows AutoHotkey copies the hovered URL, sends it with `한국어로 요약해 줘` to the Gemini desktop app, verifies that the app sent it, and restores the clipboard to the plain URL. **Gemini** replies with a summary (and you can follow up in the same chat).
   - **Alt+Z** (Aside only) — same copy, but the prompt goes to Aside's built-in AI side panel in the same window instead of Gemini.

**Implementation note:** the extension uses F24 as the internal AutoHotkey-to-browser copy signal. **Alt+A and Alt+Z are the Windows user-facing hotkeys.** The Gemini desktop handoff and the Aside panel handoff both use Windows UI Automation; neither relies on window geometry.

| Hotkey | Action |
|--------|--------|
| **Alt+A (Windows)** | Copy the hovered YouTube URL → Gemini desktop app → paste the Korean summary prompt → send |
| **Alt+Z, YouTube tab in Aside** | Copy the hovered YouTube URL (brings a background Aside YouTube window forward; prefers the one under the mouse) → Aside AI side panel (opened with Ctrl+S if closed) → Korean summary prompt → Enter. The panel's auto-attached "current page" chip is removed unless it is the same video. |
| **Alt+Z, Netflix tab in Aside** (title contains `Netflix`) | Ctrl+C copies the current subtitle sentence (via the Netflix language-learning extension) → sent with "이 문장을 한국어로 해석해줘:" to the Aside AI side panel in the same window. Focus returns to the page and your clipboard is restored. |

---

## Requirements

- Windows, AutoHotkey v2, `copy.ahk`.
- **Alt+A:** the Gemini desktop app, signed in to your Google account.
- **Alt+Z:** the Aside browser with a working AI provider (`Settings > Models`), and the extension loaded in Aside. For the Netflix mode, the Netflix subtitle extension that copies the current line on Ctrl+C.
- Reload the AHK script after changes: tray icon → **Reload Script**.

## 1. Load the YouTube extension

1. Open `brave://extensions`, `chrome://extensions`, or `aside://extensions`.
2. Enable Developer mode, select **Load unpacked**, choose this repository folder, and verify the extension is enabled.
3. Open YouTube in that browser.

## 2. Run AutoHotkey

1. Install AutoHotkey v2 and double-click this repository's `copy.ahk`.
2. Confirm the **H** tray icon appears.
3. Hover a YouTube thumbnail and press **Alt+A** (or **Alt+Z** in Aside).
4. For auto-start, point a Startup shortcut at `AutoHotkey64.exe "<repo path>\copy.ahk"`.

## 3. Use Gemini desktop (Alt+A)

Install and sign in to the official Gemini Windows app. Keep it running; `copy.ahk` prefers its visible **Gemini** window. If the desktop app is not running, the script falls back to a Gemini Chrome PWA.

The desktop route uses Windows UI Automation to find the **Ask Gemini** composer and **Send message** button. Like the PWA route, it replaces any text already in the composer, then sends; failures are reported in `copyurl_log.txt`. The Chrome PWA keeps the existing cursorless click-and-paste route.

## 4. Use the Aside AI panel (Alt+Z)

`scripts/send_aside_panel.ps1` finds the side panel, pastes the prompt into its composer and presses Enter (opening the panel with Ctrl+S if it is closed). The helper is bounded to 40 s; on failure `copyurl_log.txt` has an `Aside UIA helper exit=… status=…` line plus a `trace:` of the last steps. Custom model providers live in `~/.aside/u/0/models.json`; if `apiKey` names an environment variable, restart Aside after changing it. Alt+Z needs the Aside YouTube/Netflix tab to be the active tab (in split view, the focused pane).

## macOS and Linux

macOS uses **Option+Z** with [Mac/](Mac/). Linux uses a separate GNOME **Alt+A** shortcut with [Linux/](Linux/).


<!-- AUTO:RECENT-ACTIVITY:BEGIN -->
<!-- This block is regenerated by .githooks/pre-commit on every commit.
     Do not edit by hand — your changes will be overwritten. -->

**Last updated:** `2026-10-26T17:23:11Z`

**Recent commits (last 5 on HEAD):**

- `3c78c66` docs(ci): note the log analyzer step in the workflow header _(13 minutes ago)_
- `6c6acc5` feat(tools): analyze rotated logs too _(14 minutes ago)_
- `3f7e726` fix: three defects found by validating against the scripts' real output _(17 minutes ago)_
- `9704d8d` feat(tools): analyze the log into a success rate + failure-mode histogram _(29 minutes ago)_
- `055ea30` feat(linux): diagnose why a copy failed instead of only "timed out" _(33 minutes ago)_

**Files in the pending commit:**

- `CLAUDE.md`
- `Linux/copyurl.sh`
- `Linux/README.md`
- `tests/linux/run_copyurl_unit.sh`
<!-- AUTO:RECENT-ACTIVITY:END -->
