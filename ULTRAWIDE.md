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

Focuses the most-recently-used window in the named zone. If the zone is empty, sets a one-shot **placement hint**: the next new tiling window opened will be routed into that zone. The menu bar indicator updates immediately to reflect the pending zone.

#### `move-node-to-zone <left|center|right>`

Moves the focused window into the named zone container and saves that assignment to persistent zone memory (see below). The window is focused after the move.

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

### Zone HUD

A floating, non-activating heads-up display (`ZoneHUDController`) shows the zone layout with per-zone window counts and highlights the active zone. Configurable via `[hud]`:

```toml
[hud]
# ultrawide (default) | always | never
active-on = "ultrawide"
```

### Per-Zone Default Layouts

Each zone can have its own default tiling layout (`tiles`, `accordion`). When `ensureZoneContainers()` creates a zone container for the first time it applies the configured layout for that position.

### Startup Placement

On startup, existing windows are distributed across zones based on zone memory before the first layout pass, so windows land in the right columns immediately rather than all piling into center.
