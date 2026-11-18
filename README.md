# Windows Claude Usage Widget

A small desktop widget for Windows that shows how much of your Claude plan's usage limits you've used: the current 5-hour session and your weekly limits. These are the same figures as on claude.ai under *Settings › Usage*.

Made with [Claude](https://claude.ai).

## Features

- One row per limit: **Current session** (5 hours), **Weekly · all models**, and model-specific weekly limits such as **Weekly · Opus** when your plan has them
- Colour-coded bars: green (under 50%), amber (50–79%), red (80% and over)
- A countdown to when each limit resets
- **Time markers:** a white tick on each bar shows how much of that window has passed. If the bar is past the tick, you're using the limit faster than it refills
- Shows your plan (Pro, Max and so on) in the header
- If an update fails, it keeps the last figures on screen and says what went wrong
- Drag it anywhere; it remembers its position
- Optional *Always on top* and *Start with Windows*
- Updates every 2 minutes, plus right after a limit resets. No extra software or admin rights needed, and nothing in the taskbar

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built into Windows)
- [Claude Code](https://claude.com/claude-code), signed in with your Claude (Pro, Max, Team or Enterprise) account. The widget uses Claude Code's sign-in, so there's nothing to set up in the widget itself

## Install

No admin rights needed. Choose one of these:

**Option A: one command.** Open PowerShell and paste:

```powershell
irm https://raw.githubusercontent.com/mshajarrazip/Windows-Claude-Usage-Widget/main/install.ps1 | iex
```

**Option B: download.** Click **Code › Download ZIP** on this page, extract it, then double-click **`install.cmd`**.

Either way, the installer:

- copies the widget to `%LOCALAPPDATA%\ClaudeUsageWidget`
- adds **Claude Usage Widget** to the Start menu
- sets it to start when you sign in
- starts it. The widget appears in the top-right corner of your main screen.

Running the installer again updates the widget to the latest version and keeps your settings.

To install without starting with Windows, run `install.ps1 -NoStartup` from PowerShell instead. You can also turn startup on or off later from the widget's right-click menu.

### Uninstall

Double-click **`uninstall.cmd`**, or run `install.ps1 -Uninstall`. This closes the widget and removes it, its shortcuts and its settings.

### Run without installing

Double-click **`launch.vbs`** in the downloaded folder. Only one copy of the widget runs at a time.

## Using it

| To… | Do this |
| --- | --- |
| Move the widget | Drag it |
| Update the figures now | Right-click › **Refresh now** |
| See the full usage page | Right-click › **Open usage page on claude.ai** |
| Hide or show the time markers | Right-click › **Show time markers** |
| Keep it above other windows | Right-click › **Always on top** |
| Start it when you sign in | Right-click › **Start with Windows** |
| Close it | Right-click › **Close widget** |

Hover over a limit to see the exact reset time.

## How it works

When you sign in to Claude Code, it saves its sign-in in `%USERPROFILE%\.claude\.credentials.json` (or in the folder set by `CLAUDE_CONFIG_DIR`). The widget reads that sign-in and uses it to ask Anthropic for your current usage, the same request Claude Code makes for its `/usage` screen. It does this in a background thread so the widget stays responsive.

The widget only **reads** the sign-in file. It never changes, refreshes or sends it anywhere other than Anthropic's API (`api.anthropic.com`).

## Limitations

- **This relies on an unofficial endpoint.** Anthropic doesn't publish an API for plan usage limits, so the widget uses the one Claude Code uses. If Anthropic changes it, the widget may stop working until it's updated.
- **The sign-in can expire.** Claude Code renews its sign-in when you use it. If you haven't opened Claude Code for a while, the widget shows a message asking you to; once you do, it picks up the renewed sign-in automatically. The widget doesn't renew the sign-in itself, so it can't interfere with Claude Code's.
- Usage is per Claude account, so it includes everything you do on claude.ai, in the Claude apps and in Claude Code, but only for the account Claude Code is signed in to.
- If you signed in to Claude Code with an Anthropic Console (API) account rather than a Claude subscription, there are no plan limits to show.

## Files

| File | Purpose |
| --- | --- |
| `ClaudeUsageWidget.ps1` | The widget |
| `launch.vbs` | Starts the widget without a console window |
| `install.ps1` | Installs, updates or uninstalls the widget |
| `install.cmd` / `uninstall.cmd` | Double-click shortcuts for the installer |
| `icon.ico` | The widget's icon, used by its shortcuts |

Settings (position and options) are saved in `%LOCALAPPDATA%\ClaudeUsageWidget\settings.json`. Problems are logged to `error.log` in the same folder.

## Development

To try the layout without signing in, save a usage response as JSON and run:

```powershell
powershell -STA -ExecutionPolicy Bypass -File ClaudeUsageWidget.ps1 -DemoFile sample.json
```

Add `-Snapshot out.png` to render the widget once to an image and exit.
