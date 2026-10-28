# Claude Usage Bar

A tiny macOS menu-bar widget showing your **real Claude subscription usage** —
the same numbers as `claude.ai → Settings → Usage` and Claude Code's `/usage`.

```
▰▰▰▱▱▱▱▱ 32%
```

**[Website](https://harshitbwc.github.io/claude-usage-bar/)** · **[Download](https://github.com/harshitbwc/claude-usage-bar/releases/latest)**

## How it works

It calls the same authenticated endpoint Claude Code's `/usage` uses:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <oauth token>
anthropic-beta: oauth-2025-04-20
```

which returns your live utilization:

```json
{
  "five_hour":         {"utilization": 32.0, "resets_at": "..."},
  "seven_day":         {"utilization": 21.0, "resets_at": "..."},
  "seven_day_sonnet":  {"utilization": 12.0, "resets_at": "..."}
}
```

The OAuth token is read from the Keychain item `Claude Code-credentials` (the
one Claude Code itself stores), via `/usr/bin/security`. The token is sent only
to Anthropic's own API — nowhere else.

**Polling / rate limits.** `/api/oauth/usage` is rate-limited per account and is
*shared* with Claude Code's own `/usage` checks, so the app polls gently:

- background poll every **5 minutes**;
- a refresh when you open the popover, but only if data is older than 90s;
- on a `429`, it backs off (≥60s, doubling, capped at 15m) and keeps showing the
  last-good number rather than erroring.

Activity is logged to `~/Library/Logs/ClaudeUsageBar.log` — `tail -f` it to see
exactly when requests happen.

**Token refresh (only when needed).** If the stored token has expired (or a request
returns 401), the app refreshes it via `POST /v1/oauth/token` and updates the *same*
Keychain item so Claude Code stays logged in. Safeguards, since refresh tokens rotate:

- never refreshes ahead of time — only once the token is actually unusable;
- re-reads the Keychain first and uses Claude Code's token if it already refreshed;
- updates the existing item in place (tokens go to `security -i` over stdin, hex-encoded, so they never show up in `ps`), keeps every key in the stored JSON, then
  re-reads to verify the write;
- if the write fails, holds the new tokens in memory and retries rather than losing them — but discards them if the Keychain changed in the meantime (e.g. you logged in again), so a newer login is never overwritten.

If the latest fetch failed but an older number is still shown, the bar turns gray and gets a trailing `⚠` so a stale value can't pass for a live one.

The menu-bar item is a horizontal bar that fills left→right in Claude's coral
(`#D97757`), with the 5-hour % drawn on it; it turns red past 90%.

> Earlier versions estimated usage by summing tokens from local
> `~/.claude/projects/*.jsonl` files against a guessed limit. That couldn't match
> the official number because Anthropic weights models (Opus ≫ Sonnet) and cache
> reads very differently from a raw token count. This version uses the real data.

## Install

**Requirements:** macOS 13+, and [Claude Code](https://claude.com/claude-code)
installed and logged in on the same Mac (the app reads its login from the
Keychain — without it you'll see "No Claude login found").

### Option A — download the app

1. Download `ClaudeUsageBar.dmg` from the
   [Releases page](https://github.com/harshitbwc/claude-usage-bar/releases/latest).
2. Open it and drag **Claude Usage Bar** onto the **Applications** shortcut.
3. The app is not notarized, so macOS will block the first launch. Either
   right-click the app in Applications → **Open** → **Open**, or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/ClaudeUsageBar.app
   ```
4. Open it. On the first Keychain read you may get a prompt — choose **Always Allow**.

### Option B — build from source

```bash
xcode-select --install        # Command Line Tools, if you don't have them
git clone https://github.com/harshitbwc/claude-usage-bar.git
cd claude-usage-bar
./build.sh                    # universal binary (Apple Silicon + Intel)
open build/ClaudeUsageBar.app
```

A locally built app isn't quarantined, so there's no Gatekeeper prompt.
`./package.sh` also produces `dist/ClaudeUsageBar.dmg` for a release.

## Please read

- **Unofficial.** Not affiliated with or endorsed by Anthropic. It relies on an
  undocumented usage endpoint and Claude Code's public OAuth client ID, so it can
  break or stop working at any time.
- **It touches your Claude Code login.** It reads the token Claude Code stores in
  the Keychain and, only when that token has expired, refreshes it and writes the
  new one back to the same item. A bug or race there could force you to log in to
  Claude Code again. Use at your own risk.
- **Privacy.** The token is sent only to `api.anthropic.com`. No analytics, no other
  servers — it's all in `Sources/` if you want to check.

## The popover

- **5-hour limit** bar (the primary number, also shown in the menu bar)
- **Weekly (all)** bar
- **Weekly · Sonnet** / **Weekly · Opus** when present
- Reset countdown for each window
- Last-updated time, **Refresh**, **Quit**

If refresh fails (e.g. the refresh token itself was revoked), the bar shows `⚠` —
run Claude Code once to log in again.

## Launch at login

Toggle **Launch at login** in the popover (uses `SMAppService`). It registers
the app with macOS so it starts automatically; you'll see it under
System Settings → General → Login Items.

> The registration points at the app's current path. **Move the app to
> `/Applications` first, then enable the toggle** — otherwise moving/rebuilding
> it later breaks the login item. Re-toggle if you ever relocate it.

## Source

- `Sources/Usage.swift` — Keychain token, refresh + usage API client
- `Sources/App.swift` — menu-bar widget + popover
- `build.sh` — compiles a universal binary and assembles the ad-hoc-signed `.app`
- `package.sh` — builds the app and packages it as a `.dmg` for a release
```

## License

MIT — see `LICENSE`.
