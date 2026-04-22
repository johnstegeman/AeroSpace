# Ultrawide Fork Roadmap

This roadmap focuses on changes that fit the purpose of this fork: making AeroSpace feel genuinely native on ultrawide monitors rather than merely "usable".

The priorities below are based on:

- the current design of this fork (`ULTRAWIDE.md`)
- current AeroSpace capabilities and known gaps
- patterns used by other window managers and zone-based tools
- common ultrawide workflows: centered main app, narrow sidebars, monitor-profile switching, and screen-sharing constraints

## Ranking

### 1. Generalize zones beyond fixed `left/center/right`
**Priority:** Very high  
**Impact:** Very high  
**Effort:** High  
**Risk:** Medium

#### Why it matters
Three fixed zones are a strong default, but they are still only one opinionated layout. In practice:

- `34"` users often want `1/3 + 1/3 + 1/3` or `2/3 + 1/3`
- `38"/40"` users often want `25/50/25`
- `49"/57"` users often want `20/60/20`, `25/50/25`, `4 columns`, or asymmetric side utility columns

Other tools have converged on custom layouts rather than hardcoding a single topology.

#### Recommendation
Replace the fixed three-zone assumption with a monitor layout model like:

```toml
[[zones.layouts]]
name = "uw-default"
min-aspect-ratio = 2.0

[[zones.layouts.zone]]
id = "left"
width = 0.22
layout = "stack"

[[zones.layouts.zone]]
id = "center"
width = 0.56
layout = "tiles"

[[zones.layouts.zone]]
id = "right"
width = 0.22
layout = "stack"
```

Then let layouts have arbitrary counts and stable zone IDs.

#### Migration note
This is a likely config-format break if done literally. The current fork uses a flat `[zones]` table with fixed `widths` and `layouts`, so a move to `[[zones.layouts]]` needs an explicit migration plan:

- support both schemas for a deprecation window, or
- gate the new schema behind a config-version bump, or
- provide a compatibility shim that lowers the old flat model into the new dynamic one

I would not land this as a silent replacement.

#### Why this should come first
Several later features become much cleaner once zones stop being special-cased triples:

- spanning / merged zones
- per-zone insertion policy
- stack/tab sidebars
- per-monitor-profile defaults
- better query APIs

#### Implementation steps

The change has a wide blast radius — `Workspace.zoneNames` is a static `["left", "center", "right"]` referenced in at least ten files. The safest approach is to work inside-out: new data model first, then wire it up, then update consumers one at a time.

**Step 1 — Define `ZoneDefinition` and update `ZonesConfig`**

Add a new struct:
```swift
struct ZoneDefinition {
    let id: String        // stable zone ID, e.g. "left", "center", "right", "main"
    let width: Double     // proportional width, must sum to 1.0 across all zones
    let layout: Layout
}
```

Replace the parallel `widths: [Double]` and `layouts: [Layout]` arrays in `ZonesConfig` with `zones: [ZoneDefinition]`. Validation: at least 1 zone, widths sum to 1.0.

Add a compatibility shim in `parseZonesConfig`: if old `widths` + `layouts` arrays are detected, synthesize `[ZoneDefinition]` with IDs `["left", "center", "right"]` and log a deprecation warning. This keeps existing configs working while the new schema lands.

**Step 2 — Replace `Workspace.zoneNames` with an instance property**

Remove `static let zoneNames: [String] = ["left", "center", "right"]`.

Add `var activeZoneIds: [String]` on `Workspace`, populated from the active `ZoneDefinition` list when zones are activated. This preserves definition order (a dictionary does not). All existing `Workspace.zoneNames` callsites switch to `workspace.activeZoneIds` or `zoneContainers.keys` in definition order.

**Step 3 — Update `activateZones` / `deactivateZones`**

`activateZones` currently zips `zoneNames` with parallel `widths` and `layouts` arrays. Replace with iteration over `config.zones.zones: [ZoneDefinition]`. Remove the `layouts.count == 3` hardcode check at `Workspace.swift:339`.

`deactivateZones` currently iterates `Workspace.zoneNames` in two loops. Replace with `activeZoneIds` (the instance property set in step 2), so it iterates the actual active zones rather than the hardcoded triple.

**Step 4 — Update `ensureZoneContainers` trigger**

The current trigger is `monitor.isUltrawide` (a binary flag based on aspect ratio). With generalized layouts, the trigger should ask: does this monitor match any layout's criteria? The minimal change is to keep `isUltrawide` as the trigger but make it configurable via the layout's `min-aspect-ratio` field, rather than a hardcoded threshold.

Longer term, `ensureZoneContainers` picks the best-matching layout for the monitor and activates that layout's zone list. This is the hook that makes per-monitor-profile zone layouts work.

**Step 5 — Update consumers of `Workspace.zoneNames`**

Files to update, roughly in order of risk:

- `WorkspaceSnapshotCommand.swift` — two loops over `zoneNames`; replace with `workspace.activeZoneIds`
- `FocusZoneCommand.swift` — remove `zoneNames[0]` fallback; use `activeZoneIds.first`
- `ZoneFocusModeCommand.swift` — remove `zoneNames[1]` ("default: center") assumption; use MRU or `activeZoneIds.first`; `zoneNames.count - 1` becomes `activeZoneIds.count - 1`
- `TrayMenuModel.swift` — replace the two hardcoded `[("left", "L"), ("center", "C"), ("right", "R")]` arrays with a dynamic list derived from `zoneContainers` in definition order; derive short labels from the zone ID (first character uppercased, or a user-defined `label` field on `ZoneDefinition`)

**Step 6 — Update presets**

Zone presets currently store `widths` and `layouts` arrays of length 3. They need to store `[ZoneDefinition]` instead, or at minimum a partial override (widths-only for same-topology presets, full replacement for topology changes). The `zone-preset` command applies preset values to `config.zones`; that assignment must be updated to replace the `zones` array, not just the parallel arrays.

Consider whether a preset that changes zone count (e.g. 3 → 4 columns) should also flush `ZoneMemory` entries for zones that no longer exist. It probably should.

**Step 7 — Update `ZoneMemory`**

`ZoneMemory` stores zone IDs as strings — already stable-by-ID, so no structural change needed. However, if a zone ID is removed (e.g. a 3-zone layout becomes 2-zone), stale memory entries for the removed ID should be silently dropped on lookup rather than causing an error. Verify this is already the case; if not, add a guard in `rememberedZone`.

**Step 8 — Update `FocusZoneCmdArgs` validation**

Zone name validation in `FocusZoneCmdArgs` currently validates against the known set at parse time. With dynamic IDs, validation must move to command execution time (against `workspace.activeZoneIds`), or accept any string and fail at runtime with a clear error. The latter is simpler and consistent with how other ID-bearing commands work.

**Step 9 — Update tests**

Files with hardcoded zone assumptions:
- `ZoneEnsureContainersTest.swift` — covers 3-zone activate/deactivate; add tests for 2-zone and 4-zone layouts
- `ZoneMemoryTests.swift` — add a test that stale zone IDs are dropped on lookup after a layout change
- `ZoneNewWindowPlacementTest.swift` — parameterise on zone count

`FakeMonitor.ultrawide` should remain valid as a test fixture; the trigger condition change in step 4 just needs to be reflected in how `FakeMonitor` reports its aspect ratio.

**Step 10 — Config migration and docs**

Once the new schema is stable:
- Update `docs/` and man pages with the new `[[zones.layouts.zone]]` syntax
- Document the deprecation timeline for the old flat `[zones]` table
- Update `ULTRAWIDE.md` example configs

---

### 2. Add true stacked/tabbed zones
**Priority:** Very high  
**Impact:** Very high  
**Effort:** High  
**Risk:** High

#### Why it matters
This is the clearest UX gap between the current fork and what ultrawide users actually do.

Side zones are often not "show many windows at once" regions. They are:

- chat / Slack / Discord
- mail
- music
- notes
- logs / dashboards
- a queue of terminals or docs

Those zones benefit from **preserving one slot and switching within it**, not from recursively tiling or visually overlapping more windows.

#### How this differs from current accordion zones
Your current implementation has two accordion variants:

- `overlap`: all children are laid out in the same container with peek padding around the MRU child
- `cascade`: all children are laid out simultaneously with positional offsets

And the new indicator adds:

- a floating icon strip
- click-to-focus
- highlight of the currently focused child
- a layout inset so windows do not sit underneath the overlay

That is useful, but it is still **accordion with better discoverability**, not a true stack/tab model.

#### Specifically: accordion + indicator vs stack/tab

##### Current accordion + indicator
- Every child window is still an independently laid out window in the container.
- In `cascade`, every child gets a real frame at once.
- In `overlap`, every child still gets a frame; they just mostly cover each other.
- The active window is effectively derived from MRU / z-order behavior.
- The indicator is an external overlay panel, not part of the tiling model itself.
- Adding a new window still increases visual complexity inside the same accordion container.
- The container still behaves like a normal tiling container with accordion-specific focus semantics.

##### True stack/tab zone
- The zone owns a list of windows, but only one child is visually presented in the content slot at a time.
- The tab/stack bar is part of the zone model, not just an overlay decorating an accordion container.
- The active child is explicit state, not just inferred from MRU.
- Opening a second, third, or tenth window does **not** shrink the visible content area.
- Cycling becomes a first-class action: next tab, previous tab, move focused tab left/right, send to stack, expel from stack.
- The side zone stays a stable width utility panel no matter how many windows you park there.

#### What this enables that accordion does not
- A Slack/mail/Spotify/sidebar zone that never gets visually messy
- A terminal stack in a narrow column without cascade peeking
- A browser-doc-reference stack where only one item is visible at a time
- Better screen sharing, because the visible shape remains stable
- Clean support for commands like:

```text
focus-stack next
focus-stack prev
move-node-to-stack right
stack-node-with right
unstack-node
toggle-zone-tabbar
```

#### Concrete design direction
Two plausible implementations:

1. **Dedicated zone-local stack layout**
   - New layout type: `stack` or `tabs`
   - Explicit `activeChildIndex`
   - Optional `tabbar-position = left|right|top|bottom`

2. **Container stacking primitive**
   - General "many windows in one container, one visible at a time" primitive
   - Reusable outside zones later

For this fork, I would start with a **zone-local layout**. It fits the feature goal and keeps the blast radius smaller.

#### Architectural caveat
This is riskier than a normal new layout because the current tree and layout code assume that child windows in a tiling container participate in layout normally. A true stack means some children are owned by the container but not visually presented. That likely requires:

- explicit active-child state in the container or zone model
- a defined treatment for non-visible-but-owned children in traversal/query code
- careful interaction with hidden-window parking and any code that assumes `allLeafWindowsRecursive` implies "laid out right now"

That does not make the feature a bad idea, but it does make it a deeper tree-model change than the current wording implied.

#### Focus mode interaction
`zone-focus-mode` needs explicit treatment here. If a stack zone is collapsed and later re-expanded, its active-child selection must survive intact. That state needs to live on the zone/container model, not be derived from transient focus alone.

#### Recommendation
Implement `stack` first, with optional icon-only or icon+title bar. Treat it as a distinct layout from accordion.

For command naming, prefer a zone-local namespace such as:

```text
focus-zone-stack next
focus-zone-stack prev
move-node-to-zone-stack right
```

This avoids potential confusion with existing or future upstream uses of "stack".

---

### 3. Add zone spanning / merged zones
**Priority:** High  
**Impact:** High  
**Effort:** High  
**Risk:** Medium-high

#### Why it matters
A lot of ultrawide workflows are not "three independent columns forever". They are:

- narrow left utility
- wide centered editor
- occasional editor + preview spanning center+right
- temporary wide browser/doc window spanning two zones

This is especially common for users who prefer a centered `2/3` main window.

#### Recommendation
Support temporary or persistent adjacency merges:

```text
move-node-to-zone center+right
toggle-zone-span right
span-zone center right
unspan-zone center
```

Or model it as assigning a window to multiple adjacent zone IDs.

#### Architectural note
This gets easier once zones are generalized and stop being hardcoded triples, but it still has a real data-model mismatch with the current tree. Today every window has exactly one parent. Spanning therefore likely needs a new primitive:

- a synthetic merged container that temporarily replaces adjacent zones, or
- a zone-group abstraction that owns a combined rect while preserving single parentage

I would explicitly avoid a multi-parent model. This is probably the highest-effort item in the advanced phase.

---

### 4. Make monitor-profile automation first-class
**Priority:** High  
**Impact:** High  
**Effort:** Medium  
**Risk:** Low-medium

#### Why it matters
This fork already has good raw ingredients:

- zone presets
- zone memory
- monitor-change hooks
- workspace snapshots

But the intended workflow still feels too script-driven.

Ultrawide users routinely move between:

- laptop only
- laptop + ultrawide
- home office dock
- office dock

#### Recommendation
Promote this into config-native behavior:

```toml
[[monitor-profiles]]
name = "home-ultrawide"
match.min-aspect-ratio = 2.0
apply-zone-layout = "uw-default"
restore-workspace-snapshot = "home-dev"

[[monitor-profiles]]
name = "laptop-only"
match.monitor-count = 1
apply-zone-layout = "disabled"
```

This should be declarative, deterministic, and observable in logs/events.

---

### 5. Add zone-native query commands and events
**Priority:** High  
**Impact:** High  
**Effort:** Medium  
**Risk:** Low

#### Why it matters
Once the fork has its own zone model, external automation needs first-class visibility into it.

Right now the scripting story is workable but still indirect.

#### Recommendation
Add:

- `list-zones`
- `list-zone-windows`
- `zone --json`
- `%{zone}`
- `%{zone-layout}`
- `%{zone-preset}`
- `%{zone-is-focused}`
- `%{zone-window-count}`

Add events like:

- `zone-focused`
- `zone-layout-changed`
- `zone-preset-changed`
- `zone-window-count-changed`

This also makes testing much easier.

#### Suggested implementation steps

1. **Baseline query command**
   - Add `list-zones`
   - JSON-first output, with a stable schema
   - Start with the focused workspace only if that keeps scope down
   - **Done in `6706a95b3444`** (`feat: add list-zones query command`)

   Minimum useful fields:
   - workspace name
   - monitor ID / monitor name
   - zone ID
   - layout type
   - whether the zone is focused
   - window count
   - current width / weight

2. **Focused-zone query**
   - Add `zone --json`
   - Returns the active zone on the focused workspace
   - Useful for bars, scripts, and debugging bindings
   - **Done in `PENDING`**

3. **Subscription events**
   - Add at least:
     - `zone-focused`
     - `zone-preset-changed`
   - Prefer events that are explicit about cause rather than forcing consumers to diff snapshots

4. **Formatting / templating integration**
   - Add:
     - `%{zone}`
     - `%{zone-layout}`
     - `%{zone-window-count}`
   - Make these work anywhere existing formatting variables are supported

5. **Per-zone window introspection**
   - Add `list-zone-windows`
   - Or extend `list-windows` with zone fields if that is cleaner
   - This is where stack/tab zones and routing rules become much easier to debug

6. **Second-wave events**
   - Add:
     - `zone-layout-changed`
     - `zone-window-count-changed`
   - Only after the first query/event surfaces exist and the event shapes are clearer in practice

#### Recommended order
Ship the query surfaces before the event fan-out:

1. `list-zones`
2. `zone --json`
3. `zone-focused` / `zone-preset-changed`
4. formatting variables
5. `list-zone-windows`
6. secondary zone events

That order gives you immediate debugging value with low design risk, and it gives future work a stable inspection surface before you commit to a larger event taxonomy.

Current progress:

- `list-zones`: done in `6706a95b3444`
- `zone --json`: done in `PENDING`

---

### 6. Per-zone insertion policy
**Priority:** Medium-high  
**Impact:** High  
**Effort:** Medium  
**Risk:** Low-medium

#### Why it matters
Different zones want different new-window behavior.

Examples:

- center editor zone: insert after focused
- left utilities zone: append to stack
- right comms zone: replace active tab or append in background

#### Recommendation
Allow:

```toml
[zones.behavior.left]
new-window = "append"

[zones.behavior.center]
new-window = "after-focused"

[zones.behavior.right]
new-window = "append-hidden"
```

This becomes much more powerful once `stack` exists.

---

### 7. First-class floating defaults
**Status:** Done in `aff63975e1b6` (`feat: add [floating].app-ids config sugar`)  
**Priority:** Medium-high  
**Impact:** High  
**Effort:** Low-medium  
**Risk:** Low

#### Why it matters
Many real configs contain a long run of `[[on-window-detected]]` rules that all mean the same thing:

- match app bundle ID
- run `layout floating`

That is expressive, but it is the wrong abstraction level for a common default behavior.

Typical examples:

- Finder
- Raycast
- password managers
- chat apps
- mail apps
- utility terminals
- meeting apps

#### Recommendation
Add a dedicated config primitive:

```toml
[floating]
app-ids = [
  "com.apple.finder",
  "com.raycast.macos",
  "com.1password.1password",
  "Cisco-Systems.Spark",
]
```

Possible later expansion:

```toml
[floating]
app-ids = [...]
app-name-regex-substrings = ["^Finder$"]
window-title-regex-substrings = ["^Quick Look$", "Picture in Picture"]
```

#### Why this is better than `[[on-window-detected]]`
- Much less verbose for a very common case
- Easier to document and discover
- Lower cognitive overhead in real configs
- Potentially cheaper code path than generic callback matching

#### Implementation direction
Two reasonable approaches:

1. **Parse-time sugar**
   - Parse `[floating]`
   - Lower it internally to synthetic `on-window-detected` callbacks that run `layout floating`
   - Minimal behavior risk

2. **Dedicated runtime fast path**
   - Add `Config.floatingDefaults`
   - If a detected window’s app bundle ID matches, float it directly
   - Keep `[[on-window-detected]]` for more complex workflows

For this fork, I would start with **parse-time sugar** unless you explicitly want to clean up the callback pipeline now.

#### Precedence recommendation
The clean rule set would be:

- built-in floating defaults establish the baseline
- explicit `[[on-window-detected]]` remains the escape hatch for special cases
- docs should say: use `[floating]` for simple app-wide defaults, use callbacks for conditional automation

#### Future symmetry
If this works well, the same pattern likely makes sense for:

- `[sticky]`
- `[scratchpad]`
- `[workspace-defaults]`
- zone/workspace app routing defaults

---

### 8. App-to-zone routing rules
**Priority:** Medium-high  
**Impact:** High  
**Effort:** Low-medium  
**Risk:** Low

#### Why it matters
Once stable zones exist, the natural next question is: where does a new window land? Right now the answer for most apps is "wherever AeroSpace decides" unless you write an `on-window-detected` callback per app. That works, but it is verbose for a very common case.

On ultrawide the need is even sharper. Users have stable utility zones — a right column for comms, a left column for terminals — and they want specific apps to always open there without thinking about it.

#### Recommendation
Add a declarative routing table alongside `[floating]`:

```toml
[zones.app-routing]
"com.tinyspeck.slackmacgap" = "right"
"com.apple.mail" = "right"
"com.googlecode.iterm2" = "left"
"com.spotify.client" = "right"
```

This should apply only when a zone layout is active on the target monitor. If the workspace has no zones, fall through to normal tiling behavior.

#### Implementation direction
Same parse-time sugar approach as `[floating]`: lower each entry into a synthetic `on-window-detected` rule that calls `move-node-to-zone --no-focus`. The `--no-focus` flag is important — without it, opening a routed app like Slack or Mail steals focus from the current window.

Note that parse-time sugar is slightly leaky here: the intended abstraction is "default routing", not "run a command on detection". If the callback pipeline is ever refactored, routing rules should be a first-class concept, not sugar. For now, sugar is the right tradeoff.

#### Precedence
- `[floating]` takes priority (a floating window is never routed to a zone)
- `[zones.app-routing]` applies next
- explicit `[[on-window-detected]]` callbacks remain the override for conditional logic

#### Future symmetry
Same pattern as `[floating]`. If both ship together they form a coherent declarative-defaults layer, with `[[on-window-detected]]` reserved for cases that need conditions.

---

### 9. Enhance zone memory
**Priority:** Medium-high  
**Impact:** Medium  
**Effort:** Low-medium  
**Risk:** Low

#### Current state
The fork already implements `ZoneMemory`: bundle-ID-keyed zone assignments, persisted to disk, restored on new-window detection and across monitor-profile changes. The core behavior is done.

#### Why it matters to improve it
`ZoneMemory` as implemented covers the common case, but it has a few gaps that will become more visible as zone layouts get richer:

- **Scope is coarse.** It keys on bundle ID only. Apps with multiple window roles (e.g. a main editor window vs a quick-entry panel) get the same routing regardless.
- **No UX for inspection or reset.** There is no command to see what zone memory has recorded, clear a specific entry, or clear all. Users can only observe indirectly.
- **Observability is absent.** When a window is routed by zone memory, nothing is logged or emitted. Debugging unexpected routing is hard.
- **Scope is per-monitor-profile, not per-workspace.** This is probably correct, but it should be explicit in config and docs.

#### Recommendation
Extend `ZoneMemory` incrementally:

1. **Inspection and reset commands**
   ```text
   zone-memory list
   zone-memory clear [--app-id <id>]
   zone-memory clear --all
   ```

2. **Optional title-pattern key**
   ```toml
   [zones.memory]
   key = "app-id"           # default, current behavior
   # key = "app-id+title"   # opt-in: also considers window title
   ```

3. **Routing observability** — emit a `zone-memory-restored` event or log line when zone memory influences placement, so users can see why a window landed where it did.

#### Interaction with app routing
`[zones.app-routing]` (item 8) takes priority over zone memory. Zone memory is the fallback: "where did this window last live?" App routing is the explicit rule: "this app always goes here."

---

### 10. Presentation / screen-share mode
**Priority:** Medium-high  
**Impact:** Medium-high  
**Effort:** Medium  
**Risk:** Low

#### Why it matters
Ultrawides are awkward for screen sharing. Users often want:

- centered 16:9 or 21:9-safe content
- comms/tools hidden or collapsed
- one-command transition in and out

#### Recommendation
Add a command or preset class like:

```text
zone-preset share
presentation-mode on
presentation-mode off
```

Behavior could include:

- force center-focused layout
- collapse side zones
- optionally move chat to a hidden stack
- expose a "share-safe region" query for automation

---

### 11. Monitor arrangement / health diagnostics
**Priority:** Medium  
**Impact:** Medium-high  
**Effort:** Low-medium  
**Risk:** Low

#### Why it matters
Upstream AeroSpace already depends on proper monitor arrangement for hidden-window parking. This fork is even more geometry-sensitive.

#### Recommendation
Add:

- `doctor monitors`
- `doctor zones`
- startup warning if arrangement is unsafe
- explicit explanation of which monitor/edge is invalid

This is cheap and reduces support/debug churn.

---

### 12. Zone proportion persistence
**Priority:** Medium  
**Impact:** Medium  
**Effort:** Low  
**Risk:** Low

#### Why it matters
Zone widths can be adjusted at runtime via `zone-preset` or direct resize commands. But those adjustments are lost on restart — the config `widths` array is the only durable source of truth. If a user spends time tuning a layout interactively (wider center, narrower left), they currently have to manually transcribe those values back into their config.

#### Recommendation
Two complementary commands:

```text
zone-preset save <name>
zone-preset export
```

`zone-preset save <name>` writes the current zone widths to state as a new named preset, separate from the TOML config. It does not overwrite config-defined presets — it adds to the runtime preset pool. The user can then refer to it by name in subsequent `zone-preset` calls for the session.

`zone-preset export` prints TOML for the current layout to stdout, so the user can paste it directly into their config file. This is the path to making a layout permanent.

#### Why not silent override on startup
Silently loading state over config-defined presets creates a shadow config: the TOML says one thing, the runtime does another, and the user eventually forgets why. The `export` command keeps TOML as the authoritative source while still removing the manual transcription step.

#### Scope
Widths only, not layout type or zone count. Full layout editing is item 14.

---

### 13. Lightweight zone picker / transient overlay
**Priority:** Medium  
**Impact:** Medium  
**Effort:** Medium  
**Risk:** Low-medium

#### Why it matters
Keyboard-first users still benefit from a temporary visual aid when:

- applying presets
- moving windows between zones
- spanning zones
- targeting a stack/tab zone

#### Recommendation
Provide a transient overlay that shows:

- zone IDs
- active zone
- occupancy count
- layout type
- current preset

This should remain command-first and optional, not a permanent GUI editor.

---

### 14. Optional overview / layout editor later
**Priority:** Low  
**Impact:** Medium  
**Effort:** Very high  
**Risk:** High

#### Why it matters
There is precedent in other systems for:

- visual zone editing
- overview mode
- drag-and-drop across logical regions

But this is probably not aligned with AeroSpace’s general philosophy unless kept extremely lightweight.

#### Recommendation
Do not build this early. If anything, ship a CLI-first custom-layout format first and consider a helper UI only later.

## Suggested implementation order

### Phase 1: Foundation
1. Add zone-native query/event APIs
2. Generalize zone topology
3. Add monitor-profile automation
4. Add zone proportion persistence (low-effort, config-layer — land early)

### Phase 2: Workflow power
5. Add true `stack` layout for zones
6. Add per-zone insertion policy
7. Done: first-class floating defaults (`aff63975e1b6`)
8. Add app-to-zone routing rules
9. Enhance zone memory
10. Add presentation/share preset

### Phase 3: Advanced composition
11. Add zone spanning
12. Add lightweight transient zone picker

## What I would build first if time is limited

If only one major feature gets built next, I would choose:

### `stack` zones

Reason:

- biggest real-world UX improvement
- most visible distinction from upstream AeroSpace
- highly complementary to your current zone model
- matches how people actually use narrow side columns on ultrawides
- lets the center zone remain "real tiling" while side zones become stable utility rails

## Notes on naming

If you keep `accordion`, I would avoid overloading it further.

Recommended taxonomy:

- `tiles`: all children visible, split space
- `accordion`: all children visible, overlapped/cascaded
- `stack`: one child visible, cycle through children
- `tabs`: `stack` with a more explicit top/bottom tab strip presentation

Depending on implementation, `tabs` can simply be a presentation variant of `stack`.

## Source signals behind this roadmap

- AeroSpace emphasizes CLI-first scripting, shared workspaces across monitors, and careful monitor arrangement.
- FancyZones and Rectangle Pro strongly validate custom layouts, quick layout switching, last-known-zone behavior, and display-triggered layout changes.
- Komorebi explicitly recommends an ultrawide-specific stack-oriented layout and supports stacked containers.
- Amethyst includes multiple widescreen-specific layouts but not a true zone model.
- niri demonstrates the value of preserving width, tabbed columns, overview, and monitor/workspace persistence concepts.

The common thread is consistent:

**On ultrawides, users want stable horizontal regions first, and then different behaviors inside each region.**

Your fork already solves the first half. The next big win is to make the behavior inside each region more specialized.

## Upstream drift strategy

This is a fork, so architectural ambition needs to be balanced against rebase cost.

Guidelines worth following:

- keep zone-specific behavior isolated in clearly named files/modules where possible
- prefer additive config and command surfaces over invasive rewrites when the UX win is similar
- treat tree-model changes as expensive because they increase merge friction with upstream AeroSpace
- land observability and config-layer features earlier, since they are both useful and comparatively easy to carry forward

That is another reason to front-load query/event APIs and config-native defaults before the deepest tree changes.

---
