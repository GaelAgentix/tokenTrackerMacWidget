# tokenTrackerMacWidget

Two desktop widgets for macOS that show Claude usage, styled and sized like the native
medium widgets (Weather, Screen Time) and placed directly under them:

- **Enterprise** — month-to-date spend against your spend limit (e.g. `$411.64 of $500`),
  percent used, time until the limit resets, the last 7 days as a stacked bar chart, and a
  per-product breakdown (Claude Code, Chat, Cowork).
- **Max** — weekly limit used, current 5-hour session, the Sonnet/Opus weekly limits, when
  the session resets, and how much of the weekly limit went each of the last 7 days.

## How it works

There is no public API for a member's own claude.ai usage, so the app keeps one signed-in
claude.ai session per account (each in its own WebKit data store, so the two accounts never
share cookies) and reads:

| Widget     | Source                                                                                  |
|------------|-----------------------------------------------------------------------------------------|
| Enterprise | `GET /api/organizations/{org}/usage` (spend vs. limit) and `…/usage/spend` (per-product totals and daily series — the same data as the usage page's chart) |
| Max        | `GET /api/organizations/{org}/usage` (`five_hour`, `seven_day`, `seven_day_sonnet`, …) |

Both widgets refresh on their own every 2 minutes (every minute after a failure, and right
after the Mac wakes). The claude.ai page behind them is reloaded every few hours to keep the
session alive. The Max daily bars are built from the change in weekly usage between
readings, so they fill in over the first few days.

Everything stays on your Mac. Cached readings, history, and the latest raw responses (for
troubleshooting; chat traffic is never captured) live in
`~/Library/Application Support/TokenTracker/`.

## Install

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`); full Xcode
is not needed.

```sh
./scripts/build-app.sh --install
```

This builds `build/Token Tracker.app`, copies it to `~/Applications`, and launches it. On
first launch it also sets itself to open at login.

## Use

Once each widget is signed in there is nothing to do: they sit in the desktop widget grid
(344×164pt, directly under the native widgets) and keep themselves up to date.

- **Signing in** (first run, or if claude.ai ever signs you out): click the widget. A browser
  window opens on that widget's own session; sign in with the matching account (your work
  account for Enterprise, your Max account for Max), then close the window.
- **Optional:** drag a widget to move it (the position is remembered); right-click for
  Refresh, Open Usage Page, Sign Out, Reset Widget Positions, Open at Login, and Quit.

## Development

```sh
swift build
.build/debug/TokenTracker --render-preview preview.png      # both widgets with sample data
.build/debug/TokenTracker --parse-captures ~/Library/Application\ Support/TokenTracker/captures/enterprise
```

Source is in `Sources/TokenTracker/`: `ClaudeSession` (web sessions), `Parsers`,
`Controllers` (refresh logic), `WidgetViews`/`Components` (SwiftUI), and
`DesktopWidgetWindow` (desktop-level window).
