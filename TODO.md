# AeroSpace TODO

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
Currently zones are hardcoded to exactly 3 (left/center/right). Making the count user-defined would cover more use cases:

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

### Sticky/persistent floating windows
Allow a floating window to be marked "sticky" so it follows the user across workspace switches. Useful for persistent tools like terminals, Spotify, or reference docs — especially on ultrawide setups where a side panel is always visible.

References: GitHub issue [#2](https://github.com/nikitabobko/AeroSpace/issues/2) (107 reactions — most-reacted open issue)

---

### Scratchpad
Implement an i3-style scratchpad: a hidden workspace where windows can be sent and summoned/dismissed with a hotkey. Useful for overflow windows (chats, quick terminals, reference material) that don't belong in the main layout but need fast access.

References: GitHub issue [#272](https://github.com/nikitabobko/AeroSpace/issues/272) (54 reactions)

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
