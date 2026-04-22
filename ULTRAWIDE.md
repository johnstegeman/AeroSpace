# Ultrawide Zone Layout

## The Problem

Ultrawide monitors (aspect ratio > 2.1) present a fundamental challenge for tiling window managers: the default behavior of splitting the full screen into tiles works well on a 16:9 display but produces absurdly wide windows on a 32:9 or 21:9 panel. A single horizontal split fills each half with a window that is wider than it is useful. A cascade of tiles quickly produces windows that no one would intentionally size that way.

The intuitive solution — divide the screen into three vertical columns ("zones") and treat each column as its own independent tiling region — is not something AeroSpace supported. Workspaces had one root container. There was no concept of named regions within a workspace, no way to steer new windows into a specific column, and no UI feedback about which column was active.

## What We Built

We added a first-class **zone system** that activates automatically on ultrawide monitors and treats the workspace as three independent tiling regions: `left`, `center`, and `right`.

### Zone Containers

Each workspace on an ultrawide monitor gets three persistent tiling containers injected as direct children of the workspace root. These containers:

- Are flagged as zone containers (`isZoneContainer = true`) so the normalizer never flattens or removes them
- Are sized according to configurable proportional widths
- Are automatically created when a workspace lands on an ultrawide monitor and torn down when it leaves
- Survive config reloads

### Configuration

A new `[zones]` table in the TOML config controls zone behavior:

```toml
[zones]
# Proportional widths for left / center / right (must sum to 1.0)
widths = [0.25, 0.50, 0.25]

# Default tiling layout for each zone
layouts = ["tiles", "accordion", "tiles"]

# Gap in pixels between zone containers (separate from inner gaps)
gap = 8
```

### New Commands

#### `focus-zone <left|center|right>`
#### `focus-zone --scope mru`

Focuses the most-recently-used window in the named zone. If the zone is empty, sets a one-shot **placement hint**: the next new tiling window opened will be routed into that zone. The menu bar indicator updates immediately to reflect the pending zone.

`--scope mru` skips the explicit zone name and instead focuses the most-recently-used *zone* that is not the currently active one. This is useful when you frequently switch between two specific zones and don't want to remember their physical names:

```toml
[mode.main.binding]
alt-tab = 'focus-zone --scope mru'
```

MRU zone state is in-memory only and resets on AeroSpace restart.

#### `move-node-to-zone [--no-focus] <left|center|right>`

Moves the focused window into the named zone container and saves that assignment to persistent zone memory (see below). The window is focused after the move.

Pass `--no-focus` to move the window without stealing focus. This is the recommended form when calling `move-node-to-zone` from an `[[on-window-detected]]` callback so that opening a new app does not involuntarily pull focus away from your current window:

```toml
[[on-window-detected]]
check-app-id = 'com.tinyspeck.slackmacgap'
run = 'move-node-to-zone --no-focus right'

[[on-window-detected]]
check-app-id = 'com.spotify.client'
run = 'move-node-to-zone --no-focus left'
```

Zone memory is updated on every `move-node-to-zone` call, so subsequent openings of the app are routed automatically by zone memory without needing the callback.

#### `move-floating-to-zone <left|center|right>`

Repositions a floating window into the named zone without converting it to a tiling window. The window is not resized; its UL-corner offset relative to its current zone is preserved in the target zone. Zone memory is updated so a subsequent `move-node-to-zone` lands the window in the correct zone.

#### `show-workspace-menu`

Pops up an NSMenu of all workspaces at the center of the focused window (or monitor if no window is focused). Selecting an entry switches focus to that workspace. Useful for quickly navigating workspaces without remembering keybindings.

### Automatic Window Routing

When a new window appears on a zoned workspace, AeroSpace decides which zone to place it in using this priority order:

1. **Zone memory** — if the app was previously assigned to a zone on this monitor configuration, it goes back there.
2. **One-shot placement hint** (`focus-zone` on an empty zone) — the pending zone set by the user.
3. **MRU zone** — the zone containing the most-recently-focused window inherits the new window.
4. **Center fallback** — if none of the above apply, the window goes to `center`.

### Zone Memory

Zone assignments are persisted to `~/Library/Application Support/AeroSpace/zone-memory.json`. Assignments are keyed by:

- **Monitor profile** — a stable fingerprint of all connected monitors (size + position, sorted). This means the memory is specific to your ultrawide setup and doesn't interfere when you unplug it.
- **App bundle ID** — one zone per app per monitor profile.

This means unplugging your ultrawide and re-attaching it later restores apps to their remembered zones automatically.

### Menu Bar Indicator

When zones are active on the focused workspace, the menu bar tray appends a zone indicator to the workspace name:

```
1 : L [C] R
```

Brackets mark the currently active zone (the zone containing the focused window, or the one-shot hint zone). The indicator is also shown in the icon tray as `L`, `C`, `R` square SF Symbols.

### Named Zone Layout Presets

Define named sets of zone widths and layouts in the config, then switch between them at runtime:

```toml
[[zone-presets]]
name = "dev"
widths = [0.25, 0.50, 0.25]
layouts = ["accordion", "tiles", "tiles"]

[[zone-presets]]
name = "comms"
widths = [0.20, 0.60, 0.20]
layouts = ["tiles", "accordion", "tiles"]
```

Switch presets with:

```
zone-preset dev       # apply the "dev" preset
zone-preset --reset   # restore the original zones config from the config file
```

Per-zone gap overrides (`[zones.overrides.*]`) are **not** part of presets and survive preset switches.

```toml
[mode.main.binding]
alt-1 = 'zone-preset dev'
alt-2 = 'zone-preset comms'
alt-0 = 'zone-preset --reset'
```

### on-monitor-changed

`[[on-monitor-changed]]` fires whenever the monitor configuration changes — both when a monitor is connected and when one is disconnected. Rules are evaluated in order; all matching rules fire.

```toml
[[on-monitor-changed]]
if.any-monitor-min-aspect-ratio = 2.0
run = 'workspace-snapshot restore dev'

[[on-monitor-changed]]
# no 'if' — fires on every topology change
run = 'exec-and-forget ~/.config/aerospace/on-monitor-changed.sh'
```

**`if.any-monitor-min-aspect-ratio`** — optional matcher. When set, the rule only fires if at least one currently-connected monitor has `width/height >= value` at the time the event fires (i.e., after the connect or disconnect has already taken effect). Omitting `if` means the rule always fires.

This is the recommended way to restore a layout when your ultrawide connects:

```toml
[[on-monitor-changed]]
if.any-monitor-min-aspect-ratio = 2.0
run = 'workspace-snapshot restore dev'
```

### Event Stream (subscribe)

AeroSpace exposes a streaming event subscription for external tools (SketchyBar, custom scripts, etc.):

```sh
aerospace subscribe --all
aerospace subscribe focus-changed workspace-changed monitor-changed
```

Each event is a JSON object written to stdout, one per line. Supported event types:

| Event | Key fields |
|---|---|
| `focus-changed` | `windowId`, `workspace`, `appName` |
| `focused-workspace-changed` | `workspace`, `prevWorkspace` |
| `focused-monitor-changed` | `workspace`, `monitorId` |
| `mode-changed` | `mode` |
| `window-detected` | `windowId`, `workspace`, `appBundleId`, `appName` |
| `binding-triggered` | `mode`, `binding` |
| `monitor-changed` | `monitorCount` |

**SketchyBar integration** — SketchyBar supports custom events via `sketchybar --trigger`. A bridge script is the standard pattern:

```sh
#!/usr/bin/env bash
# ~/.config/aerospace/sketchybar-bridge.sh
# Run this as a background process alongside SketchyBar.
aerospace subscribe monitor-changed workspace-changed focus-changed | while IFS= read -r event; do
    type=$(echo "$event" | jq -r '._event')
    sketchybar --trigger "aerospace_${type}" info="$event"
done
```

SketchyBar items subscribe to the custom event and update themselves:

```lua
sketchybar --add event aerospace_monitor_changed
sketchybar --subscribe my_item aerospace_monitor_changed
-- item script receives $INFO with the full JSON payload
```

Pass `--no-send-initial` to suppress the initial state snapshot that is otherwise sent on connection.

---

#### Bridge script (`plugins/aerospace_bridge.sh`)

Subscribes to `focused-workspace-changed` and `focus-changed`, fires custom sketchybar events:

```sh
/usr/local/bin/aerospace subscribe focused-workspace-changed focus-changed --no-send-initial | \
while IFS= read -r line; do
    EVENT=$(printf '%s' "$line" | sed 's/.*"_event":"\([^"]*\)".*/\1/')
    case "$EVENT" in
        focused-workspace-changed)
            WS=$(printf '%s' "$line" | sed 's/.*"workspace":"\([^"]*\)".*/\1/')
            sketchybar --trigger aerospace_workspace_changed workspace="$WS" ;;
        focus-changed)
            APP=$(printf '%s' "$line" | sed 's/.*"appName":"\([^"]*\)".*/\1/')
            sketchybar --trigger aerospace_focus_changed app_name="$APP" ;;
    esac
done
```

Started on every `sketchybar --reload` (previous instance killed first). Custom events `aerospace_workspace_changed` and `aerospace_focus_changed` must be registered with `sketchybar --add event` before items subscribe.

#### Monitor-aware bar layout

`sketchybarrc` detects ultrawide vs laptop via physical pixel width from `system_profiler`:

| Setting | Ultrawide (≥5000px) | Laptop |
|---|---|---|
| `margin` | `screen_width × 0.32 + 5` (zone-centered) | `0` (full width) |
| `y_offset` | `0` (overlays menu bar) | `0` (overlays menu bar, left of notch) |
| `padding_left` | `640` | `680` (positions pills just left of notch) |
| `padding_right` | `480` | `10` |
| Items shown | all | workspace pills only |

`on-monitor-changed` in `aerospace.toml` runs `exec-and-forget /usr/local/bin/sketchybar --reload` so the bar automatically reconfigures when the ultrawide is connected or disconnected.

### Per-Zone Outer-Gap Overrides

Individual zones can override the global outer gap on any side. Override values are **absolute pixel distances from the screen edge** — they replace the global value for that zone, they do not add to it. Omitting a side means the zone inherits the global `outer-gaps` value for that side unchanged.

This lets you reserve space for an external bar (e.g. sketchybar) in only one zone, without wasting that space in the others:

```toml
# Global gap accounts for menu bar (25px) + sketchybar (40px) sitting above the dock.
# On laptop (no zones), this applies everywhere.
[gaps]
outer.bottom = 65

# On ultrawide, sketchybar only occupies the bottom of the center zone.
# Left and right zones reclaim that space — their bottom gap is just the dock clearance.
[zones.overrides.left]
bottom = 25

[zones.overrides.right]
bottom = 25

# center inherits outer.bottom = 65 from [gaps] — no override needed
```

Because override values can be set below the global, left/right zones effectively "expand downward" into the space the global gap had reserved for sketchybar.

### Zone Focus Mode

A command to temporarily maximize one zone while collapsing the others to 8px slivers:

```
zone-focus-mode [--zone <left|center|right>] (on|off|toggle)
```

`on` — collapse all zones except the target zone. If `--zone` is omitted, the currently focused zone (or MRU zone) is used.  
`off` — restore zones to their weights at the time `on` was called.  
`toggle` — turns on if currently off, off if currently on.

```toml
[mode.main.binding]
alt-z = 'zone-focus-mode toggle'            # toggle focus mode on current zone
alt-shift-z = 'zone-focus-mode off'          # explicitly exit focus mode
```

When `focus-zone` is called while focus mode is active and the target zone differs from the current focused zone, focus mode automatically shifts to the new zone (discarding prior saved weights and re-capturing current weights).

Collapsed zones remain visible at 8px. Zone weights captured at `on` time are restored exactly on `off` — not from config defaults.

### Per-Zone Default Layouts

Each zone can have its own default tiling layout (`tiles`, `accordion`). When `ensureZoneContainers()` creates a zone container for the first time it applies the configured layout for that position.

### Workspace Snapshots

Save and restore the current window arrangement across all workspaces:

```
workspace-snapshot save dev      # save current layout as "dev"
workspace-snapshot restore dev   # restore windows to their saved zones
```

Snapshot names must match `[a-zA-Z0-9_-]+`. Snapshots are saved to `~/Library/Application Support/AeroSpace/snapshots/<name>.json`.

**Save:** For each workspace, records which zone each tiling window belongs to (by app bundle ID). Floating windows are recorded separately.

**Restore:** For each zone entry, finds a running window with the matching bundle ID (first-come-first-served for apps with multiple windows) and binds it to the recorded zone. Missing apps are skipped gracefully. Excess windows stay in their current location.

```toml
[mode.main.binding]
alt-s = 'workspace-snapshot save dev'
alt-r = 'workspace-snapshot restore dev'
```

### Startup Placement

On startup, existing windows are distributed across zones based on zone memory before the first layout pass, so windows land in the right columns immediately rather than all piling into center.

### Accordion Cascade Mode

The accordion layout now supports a `cascade` mode where every window in the stack has a visible strip, rather than only the one directly behind the focused window.

```toml
[accordion]
mode = "cascade"   # vs "overlap" (default)
offset-x = 24      # horizontal shift per window depth level
offset-y = 0       # vertical shift per window depth level
padding = 30       # peek size used in overlap mode
```

In cascade mode, each window is offset by `(i * offset-x, i * offset-y)` from the container origin, and all windows share the same size (container dimensions minus total offset). The focused window is naturally on top due to OS focus z-order.

### Accordion Indicator Overlay

> Ported from [nikitabobko/AeroSpace#2038](https://github.com/nikitabobko/AeroSpace/pull/2038) by [@frecano](https://github.com/frecano).

When an accordion zone contains more than one window, a floating icon strip appears along the zone edge showing each window's app icon. Clicking an icon focuses that window. The focused window's icon is highlighted; others are dimmed.

The indicator only appears with ≥2 windows. When it is showing, the zone's content area is automatically inset on the indicator side so windows never slide underneath the overlay.

```toml
[accordion-indicator]
enabled = true
icon-size = 30          # app icon size in points
icon-padding = 2        # padding between icons
bar-padding = 4         # padding inside the indicator bar
position = 'left'       # left | right | top | bottom
vertical-navigation = false  # if true, up/down always navigates accordion regardless of orientation
```

The inset is computed from `icon-size + bar-padding * 2 + 4` (the fixed gap between indicator and window edge) and applied during the layout pass — so it participates in all the same gap override and zone focus mode math as the rest of the layout.

### DFS Scope for Accordion Cycling

`focus dfs-next` and `focus dfs-prev` now accept a `--scope` flag to limit cycling to the immediate parent container of the focused window:

```
focus dfs-next --scope current-container   # cycles within accordion stack or zone only
focus dfs-prev --scope current-container
focus dfs-next --scope workspace           # default: all windows in workspace
```

This is the recommended binding for cycling through an accordion stack without jumping to other zones.

### Sticky Floating Windows

A floating window can be marked **sticky** so it follows the user across workspace switches. Sticky windows are useful for persistent overlays — terminals, music players, reference docs — that should always be visible regardless of which workspace is active.

#### Usage

```
layout sticky    # make the focused window floating and sticky
layout floating  # remove sticky (window stays floating but no longer follows)
layout tiling    # tile the window and remove sticky
```

`layout sticky` is a superset of `layout floating`: it makes the window floating AND marks it sticky in one command. Toggling between `sticky` and `floating` does not resize the window.

#### Persistence

Sticky state is saved to `~/Library/Application Support/AeroSpace/sticky-windows.json` and survives AeroSpace restarts. The window will be floating and sticky the next time AeroSpace starts, regardless of which workspace it was on when AeroSpace quit.

#### Behavior

When the user switches to a different workspace, all sticky floating windows on the previous workspace are moved to the new workspace before the layout pass runs. They remain at their current screen position.

---

### Window Borders

An integrated border renderer that draws a colored outline around tiling windows — similar to jankyborders, but with zero lag because borders are updated synchronously as part of AeroSpace's own layout pass.

#### Configuration

```toml
[borders]
enabled = true
width = 2.0

# 0xAARRGGBB hex integer format
active-color = 0xff5e81ac     # border on the focused window
inactive-color = 0x00000000   # 0x00... = transparent = no border for inactive windows

# App bundle IDs that should never receive a border.
# Useful for apps whose install/auth dialogs break when an overlay panel is present.
ignore-app-ids = ["com.apple.AppStore", "com.apple.systempreferences"]
```

Setting `inactive-color` to a non-transparent color draws borders around all visible tiling windows (not just the focused one). Setting it to `0x00000000` (the default) means only the focused window gets a border.

#### Notes

- Borders are drawn as transparent `NSPanel` overlays at `normal+1` window level — above normal windows but below floating-level windows (PiP, system overlays). This prevents borders from bleeding through always-on-top windows.
- Borders are removed immediately when a window is closed or garbage-collected.
- Border colors sync on every focus change, not just on layout passes, so the active border updates immediately when clicking between windows.
- No ricing by default — `enabled = false` is the default. Opt in explicitly.

---

### Debug Logging

AeroSpace writes a structured debug log to `~/Library/Logs/AeroSpace/debug.log` (rotates at 4 MB, previous saved as `debug.log.old`). Logged events include: refresh session triggers, focus changes, window detection/close, and monitor rearrangements.

#### Marker command

Drop a visible marker into the log so you can find what happened before a bug:

```
debug-log-marker [--label <text>]
```

Bind it to a key for instant use when something goes wrong:

```toml
[mode.main.binding]
hyper-b = 'debug-log-marker'
```

Then inspect the log:

```sh
tail -100 ~/Library/Logs/AeroSpace/debug.log
# or live:
tail -f ~/Library/Logs/AeroSpace/debug.log
```

---

### Scratchpad

An i3-style **scratchpad** workspace for windows that don't belong in the main layout but need fast, hotkey-driven access. The scratchpad is a hidden workspace named `__scratchpad__`; its windows are never part of any visible tiling or floating layout unless explicitly summoned.

#### Commands

```
send-to-scratchpad [--window-id <id>]   # send focused (or specified) window to the scratchpad
scratchpad                               # toggle: summon MRU scratchpad window, or hide it if already visible
```

**`send-to-scratchpad`**: Moves the focused window into the scratchpad workspace as a floating window. If the window is currently tiling, it is automatically floated first. The window's current position and size are saved for restoration.

**`scratchpad`**: Toggle behavior —
- If the focused window is a scratchpad window visible on the current workspace → it is sent back to the scratchpad workspace (hidden).
- Otherwise → the most-recently-used scratchpad window is moved to the current workspace as a floating window at its last known position. If no position was remembered, it is centered on the monitor.

Subsequent presses of `scratchpad` cycle through scratchpad windows in MRU order: each call shows the next hidden window. Already-visible scratchpad windows are not reshown until hidden again.

#### Persistence

The set of scratchpad windows and their last-known positions are saved to `~/Library/Application Support/AeroSpace/scratchpad-windows.json`. On restart, scratchpad windows are returned to the scratchpad workspace automatically regardless of which regular workspace they were on when AeroSpace quit.

#### Notes

- The scratchpad workspace is hidden from `list-workspaces` output and cannot be switched to via the `workspace` command.
- Sticky and scratchpad are independent features: a scratchpad window is not sticky (it stays in the scratchpad workspace when you switch workspaces, rather than following you).

---

### Bug Fix: Zone Containers Lost After Closed-Windows Cache Restore

**Symptom:** On ultrawide, zone containers disappeared across all workspaces whenever a frequently-appearing/disappearing window (e.g. the Granola nub overlay) triggered the closed-windows cache restore. Tiling windows (Slack, Dia, etc.) would be laid out flat across the full screen width instead of within their zones.

**Root cause:** AeroSpace's closed-windows cache protects against the lock screen (where all AX API returns empty, making AeroSpace think every window closed). When any window reappears that was in the cache, the entire world tree is restored via `restoreTreeRecursive`. This function created new `TilingContainer` objects with `isZoneContainer = false` (the default), and the workspace's `zoneContainers` dict was left pointing to the now-detached old containers. On the next `refreshModel()` call, `normalizeContainers` treated the restored zone containers as ordinary single-child containers and flattened them, promoting windows into `rootTilingContainer` directly. Since `zoneContainers` wasn't empty (stale entries), `ensureZoneContainers` never re-activated zones.

**Fix:** During freeze (`FrozenContainer`), tag each zone container child with its zone name. During restore (`restoreTreeRecursive`), clear the stale `zoneContainers` dict, set `isZoneContainer = true` on the recreated containers, and re-register them in `workspace.zoneContainers`.

### Bug Fix: on-monitor-changed Not Firing After Sleep + Disconnect

**Symptom:** Disconnecting the ultrawide while the MacBook is asleep, then opening the lid, left AeroSpace confused about the monitor setup: sketchybar was not notified (via `monitor-changed` subscribe event or `[[on-monitor-changed]]` rules), zones remained active on the now-laptop-only session, and window layouts were wrong.

**Root cause:** `gcMonitors()` in `Workspace.swift` guards `rearrangeWorkspacesOnMonitors()` with a simple count check: `screenPointToVisibleWorkspace.count != monitors.count`. When the ultrawide is disconnected during sleep, both before and after sleep there is exactly 1 monitor (ultrawide → MacBook built-in), both at origin (0, 0). Count stays 1, origin stays the same, so `rearrangeWorkspacesOnMonitors()` was never called and `on-monitor-changed` never fired.

**Fix:** Extend the guard in `gcMonitors()` to also compare the monitor resolution profile (a multiset of `MonitorProfile.MonitorEntry`) against `previousMonitorEntries`. Since `MonitorEntry` is `Hashable`, the same `[entry: count]` dictionary comparison that `rearrangeWorkspacesOnMonitors()` uses internally is applied up front. A same-count substitution (different resolution or aspect ratio) now correctly triggers rearrangement and fires all `on-monitor-changed` callbacks.
