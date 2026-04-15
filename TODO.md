# AeroSpace TODO

## Bugs / Follow-ups

### Improve getNativeFocusedWindow Fallback 2 (multi-window apps)

`getNativeFocusedWindow` has a third fallback (`Fallback 2`) that fires when:
- `getFocusedWindow()` returns nil or a popup window, AND
- `lastNativeFocusedWindowId` is also nil (e.g. first focus after AeroSpace restart)

Currently it uses `MacWindow.allWindows.first { app match && not popup }` — arbitrary if the app has multiple windows.

Better: walk the workspace MRU tree filtered by app, so it picks the most recently active window for that app on the current workspace:
```swift
return focus.workspace.allLeafWindowsRecursive
    .first { ($0 as? MacWindow)?.macApp === macApp && !($0.parent is MacosPopupWindowsContainer) }
```

Only worth fixing if users report the wrong window being targeted when the frontmost app has multiple windows open.

---

## Features

### Per-zone gap overrides

Allow individual zones to override the global gap config. Useful when external bars (e.g. sketchybar) or other UI chrome consume space on one side of a specific zone — you can add extra padding there without affecting the rest of the layout.

Proposed config shape:
```toml
[[zones.zone]]
name = "center"
gaps = { top = 40, bottom = 8, left = 8, right = 8 }
```

Or as a simpler inline override that only specifies sides that differ from the global gaps:
```toml
[zones.overrides.center]
outer-gaps.top = 40
```

Changes required:
- Extend `ZonesConfig` with per-zone gap overrides
- Apply overrides when laying out zone containers in the refresh pass

---

### Per-node max-width
Add a `default-node-max-width` config option so windows are capped at a max pixel width and auto-centered. Fixes the most common ultrawide complaint where a single window stretches to the full 3440px. Maintainer has already confirmed this is the right direction.

References: GitHub issues [#60](https://github.com/nikitabobko/AeroSpace/issues/60), [discussion #621](https://github.com/nikitabobko/AeroSpace/discussions/621)

---

### Configurable zone count
Currently zones are hardcoded to exactly 3 (left/center/right) — the literals appear in `activateZones`, `deactivateZones`, `restoreZoneMemory`, `FlattenWorkspaceTreeCommand`, and every zone command. Making the count user-defined would cover more use cases:

- **2 zones** — master-stack equivalent on a wide-but-not-ultrawide monitor
- **3 zones** — current default, good for ~34" ultrawide
- **4 zones** — 32:9 super-ultrawide (e.g. Samsung Odyssey G9)

Centered-master and master-stack are not separate layout types — they're just zone configurations with different widths (e.g. `[0.25, 0.50, 0.25]` or `[0.65, 0.35]`). No need to implement them separately.

Proposed config shape:
```toml
[zones]
zones = ["main", "sidebar"]      # count inferred from array length; names used by focus-zone / move-node-to-zone
widths = [0.65, 0.35]
layouts = ["tiles", "accordion"]
```

Changes required:
- Relax `ZonesConfig` from fixed 3-element arrays to variable-length
- Replace `left`/`center`/`right` name literals with user-defined names
- Decide activation trigger — remove the hardcoded >2.1:1 aspect ratio guard, or make it a configurable `min-aspect-ratio`
- Update `focus-zone`, `move-node-to-zone`, and `move-floating-to-zone` commands to accept arbitrary zone names

---

### Accordion improvements / tabbed layout
The accordion layout is AeroSpace's answer to i3's stacked/tabbed layouts — windows overlap and you cycle through them. No one has filed a standalone "tabbed layout" request; the accordion already covers the use case. Pain points that have been raised:

- **Title bars floating above other windows** — hidden accordion windows' title bars render on top of everything ([#484](https://github.com/nikitabobko/AeroSpace/issues/484), 8 reactions)
- ~~**DFS cycling**~~ — ✅ implemented: `focus dfs-next/dfs-prev --scope current-container`
- **Pixel-only accordion padding** — `accordion-padding` only accepts pixel values; should support percentages (covered by the percentage-based resize entry below)
- **Per-container layout config** — no way to define a sub-layout per container in config, e.g. accordion within the right column of a tiled layout ([#187](https://github.com/nikitabobko/AeroSpace/issues/187), 27 reactions)

~~**Cascade/stagger mode**~~ — ✅ implemented: `[accordion] mode = "cascade"` with `offset-x`/`offset-y`. Remaining nice-to-haves from original spec: configurable peek direction, click-to-focus strips.

True i3-style tabs (visible tab bars rendered across the top of a container) would require custom window decoration rendering — a large UI investment not worth prioritising over the accordion fixes above.

---

### Percentage-based resize and gaps
Support percentage values for gaps and resize amounts (e.g. `outer-gaps = 5%`) so configs are resolution-independent across different display sizes (2560 vs 3440 vs 5120px wide ultrawides).

References: GitHub issue [#397](https://github.com/nikitabobko/AeroSpace/issues/397) (41 reactions)

---

## Backlog / Future Explorations

### Ultrawide & Zone Extensions
- [ ] **Config-driven Zone Routing**: Support `move-node-to-zone` in `[[on-window-detected]]` callbacks.
  - *Rationale*: Allows deterministic layouts (e.g., "always put Slack in the right zone") rather than relying on MRU or manual moves.
  - *Example*: `[[on-window-detected]] check-app-id = 'com.apple.Music' run = 'move-node-to-zone right'`
- [ ] **Dynamic Zone Resizing (Mouse)**: Allow resizing zone widths by clicking and dragging the "gutters" (gaps) between them.
  - *Rationale*: Fixed proportional widths in config can be too rigid; users often need to temporarily "expand" a center column for deep work.
- [ ] **Zone-specific "Focus Mode"**: Command to temporarily maximize the current zone (or a window within it) while dimming or collapsing the other zones.
  - *Rationale*: On 32:9 or 49" displays, side windows can be a distraction. This provides a "centered master" feel on demand.
- [ ] **MRU Zone Cycling**: Add a `--scope mru` flag to `focus-zone` to cycle through zones based on recent activity.
  - *Rationale*: More intuitive than physical `left` -> `center` -> `right` order for users who frequently jump between two specific zones.

### Layout & State Persistence
- [ ] **Snapshot Save/Restore**: Mechanism to save the current window arrangement (across all zones and workspaces) to a JSON file and restore it later.
  - *Rationale*: Addresses one of the biggest TWM pain points: manually rebuilding layouts after a reboot or a "janky" monitor reconnect.
- [ ] **Named Zone Layout Presets**: Define named presets (e.g., "dev", "comms") that activate a specific zone configuration (widths, layouts, gaps) via command. No app launching — window placement is handled by config-driven zone routing rules. Scope: named aliases for zone config that can be switched at runtime.
- [ ] **Persistent Sticky Metadata**: Ensure that when a "sticky" window is closed and reopened, it retains its sticky state (if configured by app ID rules).

### UX & Visual Improvements
- [ ] **Native Focused Window Borders**: Implement a lightweight, high-performance border overlay to identify focus natively.
  - *Rationale*: Eliminates dependency on 3rd party tools like JankyBorders and ensures the border is perfectly synced with AeroSpace's layout engine.
- [ ] **AeroSpace "Mission Control" (Overview Mode)**: A custom UI that shows a grid of all virtual workspaces and their windows at once.
  - *Rationale*: Since AeroSpace workspaces are invisible to macOS Mission Control, users need a way to "see" where windows are without blind-switching.
- [ ] **Focus-Follows-Mouse**: Implement focus-on-hover (focus follows mouse).
  - *Rationale*: High impact on ultrawides where the physical distance between windows makes keyboard-only focus switching feel slow.

### Technical & Compatibility
- [ ] **Non-US Keyboard Compatibility**: Audit and provide "Safe Defaults" or a setup wizard for layouts (German, French, etc.) where default `Option+Number` bindings conflict with essential characters like `[` or `{`.
- [ ] **Native Hiding Research**: Explore alternatives to "move windows off-screen" (like `NSWindow.orderOut`) to eliminate "bleeding" artifacts often seen at the bottom-right of the screen.
- [ ] **IPC Event Stream**: Add a `watch` command to the CLI that streams JSON events (e.g., `window-focused`, `workspace-switched`, `zone-changed`, `snapshot-restored`) for status bar (e.g., sketchybar) integrations. Good community value once the Zone Power Suite ships; deferred because the user is not running sketchybar today.

References: GitHub issue [#397](https://github.com/nikitabobko/AeroSpace/issues/397) (41 reactions)
