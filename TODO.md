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

### Per-node max-width

Add a `default-node-max-width` config option so windows are capped at a max pixel width and auto-centered. Fixes the most common ultrawide complaint where a single window stretches to the full 3440px. Maintainer has already confirmed this is the right direction.

References: GitHub issues [#60](https://github.com/nikitabobko/AeroSpace/issues/60), [discussion #621](https://github.com/nikitabobko/AeroSpace/discussions/621)

---

### Configurable zone count

Currently zones are hardcoded to exactly 3 (left/center/right) — the literals appear in `activateZones`, `deactivateZones`, `restoreZoneMemory`, `FlattenWorkspaceTreeCommand`, and every zone command. Making the count user-defined would cover more use cases:

- **2 zones** — master-stack equivalent on a wide-but-not-ultrawide monitor
- **3 zones** — current default, good for ~34" ultrawide
- **4 zones** — 32:9 super-ultrawide (e.g. Samsung Odyssey G9)

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

### Accordion improvements

Pain points that have been raised:

- **Title bars floating above other windows** — hidden accordion windows' title bars render on top of everything ([#484](https://github.com/nikitabobko/AeroSpace/issues/484), 8 reactions)
- **Pixel-only accordion padding** — `accordion-padding` only accepts pixel values; should support percentages (covered by the percentage-based resize entry below)
- **Per-container layout config** — no way to define a sub-layout per container in config, e.g. accordion within the right column of a tiled layout ([#187](https://github.com/nikitabobko/AeroSpace/issues/187), 27 reactions)

---

### Percentage-based resize and gaps

Support percentage values for gaps and resize amounts (e.g. `outer-gaps = 5%`) so configs are resolution-independent across different display sizes (2560 vs 3440 vs 5120px wide ultrawides).

References: GitHub issue [#397](https://github.com/nikitabobko/AeroSpace/issues/397) (41 reactions)

---

## Backlog / Future Explorations

- [ ] **Focus-Follows-Mouse**: Implement focus-on-hover.
- [ ] **AeroSpace "Mission Control" (Overview Mode)**: A custom UI that shows a grid of all virtual workspaces and their windows at once. Useful since AeroSpace workspaces are invisible to macOS Mission Control.
- [ ] **Native Hiding Research**: Explore alternatives to moving windows off-screen to eliminate occasional bleed artifacts at screen edges.
