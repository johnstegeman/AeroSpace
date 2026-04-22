# New Bugs Found

This document tracks additional issues identified during a later code review of the `zones` branch, excluding items already covered in `BUGS.md`.

## 1. `focus-zone` Does Not Retarget Focus Mode
**Location:** `Sources/AppBundle/command/impl/FocusZoneCommand.swift` and `Sources/AppBundle/command/impl/ZoneFocusModeCommand.swift`
- **Issue:** When zone focus mode is active and `focus-zone` is used to switch to a different zone, `FocusZoneCommand` re-runs `ZoneFocusModeCommand(action: .on)` without passing the requested zone.
- **Impact:** `ZoneFocusModeCommand` resolves the target zone from the *currently focused window*, which is still in the old zone at that point. The new zone receives focus, but the collapsed/expanded geometry remains centered on the old zone.
- **Recommendation:** Pass the requested zone into `ZoneFocusModeCommand` when re-targeting focus mode, or update `workspace.focusModeZone` directly before reapplying weights.
- **Code-level detail:** `FocusZoneCommand.swift:38` constructs `ZoneFocusModeCmdArgs(rawArgs: [], .on)` with no `zone` set. `ZoneFocusModeCmdArgs` already has a `zone: ZoneName?` field (`ZoneFocusModeCmdArgs.swift:14`). Fix: set `args.zone = zoneName` on the constructed args before calling `.run`. One-line change.
- **Fixed in commit:** `f904823f23d5` (vqkupqkp)

## 2. `zone-preset` Skips Hidden Zoned Workspaces
**Location:** `Sources/AppBundle/command/impl/ZonePresetCommand.swift`
- **Issue:** `zone-preset` force-rebuilds zone containers only for `workspace.isVisible`.
- **Impact:** Hidden workspaces that already have zone containers keep their old widths/layouts. Later normal calls to `ensureZoneContainers(...)` are no-ops because the containers already exist, so those workspaces stay stale until restart or another explicit forced rebuild.
- **Recommendation:** Apply the forced rebuild to all workspaces, not only visible ones, matching the approach already used in config reload.
- **Code-level detail:** `ZonePresetCommand.swift:24` — `for workspace in Workspace.all where workspace.isVisible`. Fix: remove the `where workspace.isVisible` filter. `workspace.workspaceMonitor` is valid on hidden workspaces so the call is safe.
- **Fixed in commit:** `3b2a44960790` (xusrwyzz)

## 3. Tray Active-Zone Indicator Fails for Nested Containers
**Location:** `Sources/AppBundle/ui/TrayMenuModel.swift`
- **Issue:** The tray/menu zone indicator determines the active zone only from `window.parent` being a zone container.
- **Impact:** If the focused window sits inside a nested tiling container within a zone, the immediate parent is no longer the zone root. The tray indicator then fails to identify the active zone and often shows no active zone at all.
- **Recommendation:** Walk the focused window’s ancestor chain to find the containing zone container, the same way `focus.swift` already does for emitted `focus-changed` events.
- **Code-level detail:** `TrayMenuModel.swift` has the broken `window.parent as? TilingContainer` pattern in **two** places: lines 24–26 (tray text) and 84–86 (tray items). Both should be replaced with the ancestor-walk already used in `focus.swift:200`: `window.parents.first(where: { ($0 as? TilingContainer)?.isZoneContainer == true }) as? TilingContainer`.
- **Fixed in commit:** `3cceb8d814a3` (rqurxysu)

## 4. Initial `subscribe focus-changed` Event Omits `zoneName`
**Location:** `Sources/AppBundle/subscriptions.swift`
- **Issue:** Live `focus-changed` events include `zoneName`, but the initial snapshot sent to new subscribers does not.
- **Impact:** Consumers that depend on the initial event for state hydration start with incomplete zone information until focus changes again. This can break or delay correct initialization in menu bar / SketchyBar integrations.
- **Recommendation:** Compute the focused zone during the initial subscription snapshot and include it in the emitted `focus-changed` event payload.
- **Code-level detail:** `subscriptions.swift:23` calls `.focusChanged(windowId:workspace:appName:)` without `zoneName`. `focus.swift:199–208` shows the correct pattern: walk ancestors with `window.parents.first(where: { ($0 as? TilingContainer)?.isZoneContainer == true })`, then look up the key in `zoneContainers`. The fix is to copy that block into the `sendInitial` path in `handleSubscribeAndWaitTillError`.
- **Fixed in commit:** `c3a8d52ba173` (yzlrltpq)
