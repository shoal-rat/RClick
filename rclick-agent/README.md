# RClick Agent

A tiny, invisible background helper that gives Finder a **Windows-style
top-level right-click menu** — without the annoying "RClick would like to
access data from other apps" permission prompt.

## What it is

The real `RClick.app` fires a macOS privacy prompt at launch because it probes
`~/Library/Mail`, `Messages`, and `Safari` to check Full Disk Access. But its
**Finder Sync extension** (the thing that actually draws the right-click menu)
is well-behaved and already code-signed by the original developer.

`RClick Agent` replaces only the *main app*: it speaks the same private IPC
protocol (`DistributedNotificationCenter` + HMAC-signed payloads, compiled from
RClick's own `Shared/` sources) so the original signed extension gets its menu
config and executes clicks — while `RClick.app` itself never runs. No probe, no
prompt.

It is an `LSUIElement`/accessory app: **no Dock icon, no menu-bar icon, no
windows, no alerts.** Failures are written to the unified log only.

## The menu

Right-click any file or folder in Finder:

- **Actions ▸** Copy Relative Path · Copy File Name · Copy Name w/o Extension ·
  Move To… · Copy To… · Calculate SHA-256 · Show/Hide Hidden Files
- **Open in Terminal** · **Open in VS Code**
- **Copy Path** · **Compress** · **AirDrop** · **Move to Trash**
- **New File ▸** Text · Markdown · Python · JSON · HTML · Word (.docx) ·
  PowerPoint (.pptx) · Excel (.xlsx)
- **Common Folders ▸** Desktop · Documents · Downloads · Home · Applications ·
  Codex Projects

Notes:
- **Move to Trash** uses the Trash (recoverable, like the Recycle Bin), so it
  needs no confirmation dialog.
- **New Word/PowerPoint/Excel** copy blank Office templates bundled inside the
  app (`Contents/Resources/blank.{docx,pptx,xlsx}`).
- **Move To… / Copy To…** open a folder picker — the one intentional window,
  and only when you click them.

## Efficiency (runs 24/7)

- Idle-until-event: no polling timers. The process only wakes on a Finder click
  or an extension request.
- The extension heartbeats every 10 s; the agent replies **only when the menu
  actually changes** (i.e. when the hidden-files label flips), so steady-state
  IPC and CPU are ~zero and the extension's icon cache is not churned.

## Install / update / remove

```sh
./build.sh        # compile + ad-hoc sign into ~/Applications/RClick Agent.app
./install.sh      # install the LaunchAgent (auto-start at login) + enable the
                  # Finder extension + restart Finder
./uninstall.sh    # stop auto-start, disable the extension  (add --purge to also
                  # delete the app and its support files)
```

`build.sh` re-run is safe: it stops the running copy first, rebuilds, re-signs.
Re-run `install.sh` after a rebuild to relaunch.

### Optional: fully prompt-free file actions

Because the app is ad-hoc signed (no Apple Developer identity on this Mac),
macOS may ask **once per protected folder** the first time an action touches
`~/Desktop`, `~/Documents`, or `~/Downloads`. To avoid that entirely, grant
**RClick Agent** *Full Disk Access* in
System Settings → Privacy & Security → Full Disk Access (one-time).

## Files

| File | Purpose |
|------|---------|
| `main.swift` | the agent (IPC, menu config, all actions) |
| `RCBaseSubset.swift` | the four menu-item structs, copied from RClick for wire compatibility |
| `Info.plist` | `LSUIElement` accessory app bundle |
| `dev.zwk.rclick-agent.plist` | LaunchAgent (Aqua-only, RunAtLoad, KeepAlive) |
| `build.sh` / `install.sh` / `uninstall.sh` | lifecycle scripts |

## How it works (one paragraph)

At launch the agent grabs a single-instance `flock`, registers three IPC
handlers (`request-config`, `heartbeat`, `click`), and broadcasts the menu once.
The signed FinderSync extension, on first menu draw, asks for config and caches
it; thereafter it sends clicks, which the agent dispatches to the matching
action. A SIGTERM handler tells the extension goodbye and exits cleanly so
launchd doesn't respawn it. Authenticity between the two processes rests on the
HMAC shared key baked into both — which is exactly why an ad-hoc build is
honored in place of the original signed app.

## GUI verification & fixes (2026-07-06)

Everything above was verified end-to-end in the real Finder UI. Two fixes came
out of it:

1. **RClick.app is now a patched copy.** The Sequoia "'RClick' would like to
   access data from other apps" prompt was NOT coming from RClick.app launching
   — it fired every time a *fresh FinderSync extension process* built its first
   menu, because the extension reads its language preference from the app group
   `group.cn.wflixu.RClick` and that group id isn't team-ID-prefixed (macOS 15+
   rule). Neither Allow nor Don't Allow persists for that TCC class, so it
   re-prompted after every Finder restart / login. Fix: the appex binary's
   suite-name string was byte-patched to `prefs.cn.wflixu.RClick` (same length,
   ordinary prefs domain, no group container → no prompt) and the app re-signed
   ad-hoc. The pristine Developer-ID original is at
   `~/Documents/Codex/2026-07-05/pl-2/work/rclick/_backup_original_signed/`
   (plus the original download zip next to it). If RClick is ever updated,
   re-apply the patch or the prompt returns.
2. **Compress of a single file** no longer wraps the file in its parent
   folder's name inside the zip (`ditto --keepParent` is now used only for
   folders; single files go through `zip` from the parent directory).

Known limitation: Finder windows showing iCloud-synced locations (this Mac
syncs Desktop & Documents) don't get FinderSync menus at all — that's a macOS
FileProvider restriction, not a bug in this setup. The agent itself can still
operate on `~/Desktop` (e.g. via the Common Folders menu from any regular
window) after its one-time folder grant.
