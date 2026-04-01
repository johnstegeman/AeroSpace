import AppKit
import Common

@MainActor private var workspaceNameToWorkspace: [String: Workspace] = [:]

@MainActor private var screenPointToPrevVisibleWorkspace: [CGPoint: String] = [:]
/// Snapshot of monitor entries from the previous rearrangeWorkspacesOnMonitors call.
/// Used to detect monitor topology changes (connect/disconnect/rearrange) for on-monitor-changed rules.
@MainActor private var previousMonitorEntries: [MonitorProfile.MonitorEntry] = []
/// Snapshot of screen origin points from the previous rearrangeWorkspacesOnMonitors call.
/// Used to detect monitor rearrangements (same monitors, different positions).
@MainActor private var previousScreenPoints: Set<CGPoint> = []
@MainActor private var screenPointToVisibleWorkspace: [CGPoint: Workspace] = [:]
@MainActor private var visibleWorkspaceToScreenPoint: [Workspace: CGPoint] = [:]

// The returned workspace must be invisible and it must belong to the requested monitor
@MainActor func getStubWorkspace(for monitor: Monitor) -> Workspace {
    getStubWorkspace(forPoint: monitor.rect.topLeftCorner)
}

@MainActor
private func getStubWorkspace(forPoint point: CGPoint) -> Workspace {
    if let prev = screenPointToPrevVisibleWorkspace[point].map({ Workspace.get(byName: $0) }),
       !prev.isVisible && prev.workspaceMonitor.rect.topLeftCorner == point && prev.forceAssignedMonitor == nil
    {
        return prev
    }
    if let candidate = Workspace.all
        .first(where: { !$0.isVisible && $0.workspaceMonitor.rect.topLeftCorner == point })
    {
        return candidate
    }
    return (1 ... Int.max).lazy
        .map { Workspace.get(byName: String($0)) }
        .first { $0.isEffectivelyEmpty && !$0.isVisible && !config.persistentWorkspaces.contains($0.name) && $0.forceAssignedMonitor == nil }
        .orDie("Can't create empty workspace")
}

final class Workspace: TreeNode, NonLeafTreeNodeObject, Hashable, Comparable {
    /// The reserved name for the hidden scratchpad workspace.
    static let scratchpadName = "__scratchpad__"

    /// The global scratchpad workspace. Created on first access.
    @MainActor static var scratchpad: Workspace { Workspace.get(byName: scratchpadName) }

    /// True for the internal scratchpad workspace, which is never shown on any monitor.
    var isScratchpad: Bool { name == Workspace.scratchpadName }

    let name: String
    nonisolated private let nameLogicalSegments: StringLogicalSegments
    /// `assignedMonitorPoint` must be interpreted only when the workspace is invisible
    fileprivate var assignedMonitorPoint: CGPoint? = nil
    /// Active zone containers keyed by name ("left", "center", "right"). Empty when zones are inactive.
    var zoneContainers: [String: TilingContainer] = [:]
    /// Monitor profile that was active when zones were last activated. Used to save zone memory on deactivation.
    var activeZoneProfile: MonitorProfile? = nil
    /// Root container orientation saved before zone activation, restored when zones are deactivated.
    var savedRootOrientation: Orientation? = nil
    /// One-shot hint: place the next new tiling window in this zone, then clear. Set by focus-zone on an empty zone.
    var focusedZone: String? = nil
    /// MRU zone history for this workspace (most-recent-first). In-memory only; resets on restart.
    var mruZones: [String] = []
    /// Saved zone weights captured when zone-focus-mode was activated. nil when focus mode is off.
    var savedZoneWeights: [String: CGFloat]? = nil
    /// Name of the currently focused zone when zone focus mode is active. nil when focus mode is off.
    var focusModeZone: String? = nil

    /// Canonical ordered list of zone names. Use this everywhere instead of hardcoded string arrays.
    static let zoneNames: [String] = ["left", "center", "right"]

    @MainActor
    private init(_ name: String) {
        self.name = name
        self.nameLogicalSegments = name.toLogicalSegments()
        super.init(parent: NilTreeNode.instance, adaptiveWeight: 0, index: 0)
    }

    @MainActor static var all: [Workspace] {
        workspaceNameToWorkspace.values.sorted()
    }

    @MainActor static func get(byName name: String) -> Workspace {
        if let existing = workspaceNameToWorkspace[name] {
            return existing
        } else {
            let workspace = Workspace(name)
            workspaceNameToWorkspace[name] = workspace
            return workspace
        }
    }

    nonisolated static func < (lhs: Workspace, rhs: Workspace) -> Bool {
        lhs.nameLogicalSegments < rhs.nameLogicalSegments
    }

    override func getWeight(_ targetOrientation: Orientation) -> CGFloat {
        workspaceMonitor.visibleRectPaddedByOuterGaps.getDimension(targetOrientation)
    }

    override func setWeight(_ targetOrientation: Orientation, _ newValue: CGFloat) {
        die("It's not possible to change weight of Workspace")
    }

    @MainActor
    var description: String {
        let description = [
            ("name", name),
            ("isVisible", String(isVisible)),
            ("isEffectivelyEmpty", String(isEffectivelyEmpty)),
            ("doKeepAlive", String(config.persistentWorkspaces.contains(name))),
        ].map { "\($0.0): \(String(describing: $0.1).singleQuoted)" }.joined(separator: ", ")
        return "Workspace(\(description))"
    }

    @MainActor
    static func garbageCollectUnusedWorkspaces() {
        for name in config.persistentWorkspaces {
            _ = get(byName: name) // Make sure that all persistent workspaces are "cached"
        }
        workspaceNameToWorkspace = workspaceNameToWorkspace.filter { (_, workspace: Workspace) in
            workspace.isScratchpad || // always keep the scratchpad workspace
                config.persistentWorkspaces.contains(workspace.name) ||
                !workspace.isEffectivelyEmpty ||
                workspace.isVisible ||
                workspace.name == focus.workspace.name
        }
    }

    nonisolated static func == (lhs: Workspace, rhs: Workspace) -> Bool {
        check((lhs === rhs) == (lhs.name == rhs.name), "lhs: \(lhs) rhs: \(rhs)")
        return lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

extension Workspace {
    @MainActor
    var isVisible: Bool { visibleWorkspaceToScreenPoint.keys.contains(self) }
    @MainActor
    var workspaceMonitor: Monitor {
        forceAssignedMonitor
            ?? visibleWorkspaceToScreenPoint[self]?.monitorApproximation
            ?? assignedMonitorPoint?.monitorApproximation
            ?? mainMonitor
    }
}

extension Monitor {
    @MainActor
    var activeWorkspace: Workspace {
        if let existing = screenPointToVisibleWorkspace[rect.topLeftCorner] {
            return existing
        }
        // What if monitor configuration changed? (frame.origin is changed)
        rearrangeWorkspacesOnMonitors()
        // Normally, recursion should happen only once more because we must take the value from the cache
        // (Unless, monitor configuration data race happens)
        return self.activeWorkspace
    }

    @MainActor
    func setActiveWorkspace(_ workspace: Workspace) -> Bool {
        rect.topLeftCorner.setActiveWorkspace(workspace)
    }
}

@MainActor
func gcMonitors() {
    let currentEntries = monitors.map { MonitorProfile.MonitorEntry(width: $0.rect.width, height: $0.rect.height) }
    var prevCounts: [MonitorProfile.MonitorEntry: Int] = [:]
    for e in previousMonitorEntries { prevCounts[e, default: 0] += 1 }
    var currCounts: [MonitorProfile.MonitorEntry: Int] = [:]
    for e in currentEntries { currCounts[e, default: 0] += 1 }
    // Also check resolution profile, not just count: disconnecting the ultrawide while asleep and
    // waking on the laptop screen keeps count at 1 but switches resolution, and without this check
    // rearrangeWorkspacesOnMonitors() would never run so on-monitor-changed never fires.
    if screenPointToVisibleWorkspace.count != monitors.count || currCounts != prevCounts {
        rearrangeWorkspacesOnMonitors()
    }
    for (point, workspace) in screenPointToVisibleWorkspace {
        workspace.ensureZoneContainers(for: point.monitorApproximation)
    }
}

extension CGPoint {
    @MainActor
    fileprivate func setActiveWorkspace(_ workspace: Workspace) -> Bool {
        if !isValidAssignment(workspace: workspace, screen: self) {
            return false
        }
        if let prevMonitorPoint = visibleWorkspaceToScreenPoint[workspace] {
            visibleWorkspaceToScreenPoint.removeValue(forKey: workspace)
            screenPointToPrevVisibleWorkspace[prevMonitorPoint] =
                screenPointToVisibleWorkspace.removeValue(forKey: prevMonitorPoint)?.name
        }
        if let prevWorkspace = screenPointToVisibleWorkspace[self] {
            screenPointToPrevVisibleWorkspace[self] =
                screenPointToVisibleWorkspace.removeValue(forKey: self)?.name
            visibleWorkspaceToScreenPoint.removeValue(forKey: prevWorkspace)
        }
        visibleWorkspaceToScreenPoint[workspace] = self
        screenPointToVisibleWorkspace[self] = workspace
        workspace.assignedMonitorPoint = self
        return true
    }
}

@MainActor
private func rearrangeWorkspacesOnMonitors() {
    // Capture current monitor entries BEFORE reassigning to detect newly-connected monitors.
    let currentEntries = monitors.map { MonitorProfile.MonitorEntry(width: $0.rect.width, height: $0.rect.height) }
    // Use multiset comparison so that a second identical monitor (same resolution) is treated as
    // newly added even though an entry with that resolution already existed in previousMonitorEntries.
    var prevCounts: [MonitorProfile.MonitorEntry: Int] = [:]
    for e in previousMonitorEntries { prevCounts[e, default: 0] += 1 }
    var currCounts: [MonitorProfile.MonitorEntry: Int] = [:]
    for e in currentEntries { currCounts[e, default: 0] += 1 }
    // One entry per surplus instance (e.g. 2 identical monitors where 1 was known → one newly-added entry).
    var newlyAdded: [MonitorProfile.MonitorEntry] = []
    for (entry, currCount) in currCounts {
        let surplus = currCount - (prevCounts[entry] ?? 0)
        if surplus > 0 { newlyAdded.append(contentsOf: Array(repeating: entry, count: surplus)) }
    }

    let newScreens = monitors.map(\.rect.topLeftCorner)
    var newScreenToOldScreenMapping: [CGPoint: CGPoint] = [:]
    for (oldScreen, _) in screenPointToVisibleWorkspace {
        guard let newScreen = newScreens.minBy({ ($0 - oldScreen).vectorLength }) else { continue }
        if let prevOldScreen = newScreenToOldScreenMapping[newScreen] {
            if (prevOldScreen - newScreen).vectorLength <= (oldScreen - newScreen).vectorLength {
                // newScreen has already been assigned to a closer oldScreen.
                continue
            }
        }
        newScreenToOldScreenMapping[newScreen] = oldScreen
    }

    let oldScreenPointToVisibleWorkspace = screenPointToVisibleWorkspace
    screenPointToVisibleWorkspace = [:]
    visibleWorkspaceToScreenPoint = [:]

    for newScreen in newScreens {
        if let existingVisibleWorkspace = newScreenToOldScreenMapping[newScreen].flatMap({ oldScreenPointToVisibleWorkspace[$0] }),
           newScreen.setActiveWorkspace(existingVisibleWorkspace)
        {
            continue
        }
        let stubWorkspace = getStubWorkspace(forPoint: newScreen)
        check(newScreen.setActiveWorkspace(stubWorkspace),
              "getStubWorkspace generated incompatible stub workspace (\(stubWorkspace)) for the monitor (\(newScreen)")
    }

    for (point, workspace) in screenPointToVisibleWorkspace {
        workspace.ensureZoneContainers(for: point.monitorApproximation)
    }

    // Update previousMonitorEntries for next call.
    previousMonitorEntries = currentEntries

    // Detect removed monitors (entries in prev that are surplus relative to current).
    // Build the removed list for aspect-ratio matching, not just a boolean.
    var removedEntries: [MonitorProfile.MonitorEntry] = []
    for (entry, prevCount) in prevCounts {
        let surplus = prevCount - (currCounts[entry] ?? 0)
        if surplus > 0 { removedEntries.append(contentsOf: Array(repeating: entry, count: surplus)) }
    }
    let removedAny = !removedEntries.isEmpty

    // Detect monitor rearrangements: same monitor count and resolutions, but different screen origins.
    let positionsChanged = !previousScreenPoints.isEmpty && Set(newScreens) != previousScreenPoints
    previousScreenPoints = Set(newScreens)

    aeroLog("monitors: \(monitors.count) screens, newly-added: \(newlyAdded.count), removed: \(removedAny), rearranged: \(positionsChanged)")
    for (point, ws) in screenPointToVisibleWorkspace {
        aeroLog("  screen \(point) → ws:\(ws.name)")
    }

    // Fire on-monitor-changed rules on any topology change (skip during startup).
    // Deferred via Task so commands run after the current refresh session has fully committed its
    // tree state — avoids bind() calls re-entering an in-progress layout pass.
    if !isStartup && (!newlyAdded.isEmpty || removedAny || positionsChanged) {
        broadcastEvent(.monitorChanged(monitorCount: monitors.count))

        // For add/remove: only filter by the aspect ratios of changed monitors so that connecting
        // an unrelated small monitor does not trigger ultrawide-targeted rules (Bug 28).
        // For pure rearrangement: all current monitors are involved, so use current aspect ratios.
        let changedAspectRatios: [CGFloat]
        if !newlyAdded.isEmpty || removedAny {
            changedAspectRatios = (newlyAdded + removedEntries).map { $0.width / $0.height }
        } else {
            changedAspectRatios = monitors.map { $0.rect.width / $0.rect.height }
        }
        let rulesToFire = config.onMonitorChanged.filter { callback in
            guard let minRatio = callback.matcher.anyMonitorMinAspectRatio else { return true }
            return changedAspectRatios.contains { $0 >= minRatio }
        }
        if !rulesToFire.isEmpty {
            Task { @MainActor in
                for rule in rulesToFire {
                    _ = try? await rule.run.runCmdSeq(.defaultEnv, .emptyStdin)
                }
            }
        }
    }
}

@MainActor
private func isValidAssignment(workspace: Workspace, screen: CGPoint) -> Bool {
    switch workspace.forceAssignedMonitor {
        case let forceAssigned? where forceAssigned.rect.topLeftCorner != screen: false
        default: true
    }
}

extension Workspace {
    @MainActor
    func ensureZoneContainers(for monitor: Monitor, force: Bool = false) {
        if monitor.isUltrawide && zoneContainers.isEmpty {
            activateZones(monitorWidth: monitor.visibleRect.width)
        } else if monitor.isUltrawide && !zoneContainers.isEmpty && force {
            // Config reload: tear down and rebuild so updated widths/layouts take effect.
            // deactivateZones auto-saves current assignments; activateZones restores them.
            deactivateZones()
            activateZones(monitorWidth: monitor.visibleRect.width)
        } else if !monitor.isUltrawide && !zoneContainers.isEmpty {
            deactivateZones()
        }
    }

    @MainActor
    private func activateZones(monitorWidth: CGFloat) {
        aeroLog("activateZones: ws:\(name) monitorWidth=\(monitorWidth)")
        activeZoneProfile = MonitorProfile([workspaceMonitor])
        savedRootOrientation = rootTilingContainer.orientation
        rootTilingContainer.changeOrientation(.h)
        rootTilingContainer.layout = .tiles
        let widths = validatedZoneWidths(config.zones.widths)
        let layouts = config.zones.layouts.count == 3 ? config.zones.layouts : [Layout.tiles, .tiles, .tiles]
        for (name, (proportion, layout)) in zip(Workspace.zoneNames, zip(widths, layouts)) {
            let container = TilingContainer(
                parent: rootTilingContainer,
                adaptiveWeight: monitorWidth * proportion,
                .h,
                layout,
                index: INDEX_BIND_LAST,
            )
            container.isZoneContainer = true
            zoneContainers[name] = container
        }
        restoreZoneMemory()
    }

    @MainActor
    func restoreZoneMemory() {
        let profile = MonitorProfile([workspaceMonitor])
        let windows = rootTilingContainer.allLeafWindowsRecursive
        for window in windows {
            guard let zoneName = ZoneMemory.shared.rememberedZone(for: window, profile: profile),
                  let zone = zoneContainers[zoneName]
            else { continue }
            window.bind(to: zone, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
    }

    @MainActor
    private func deactivateZones() {
        aeroLog("deactivateZones: called for ws:\(name), zoneContainers=\(zoneContainers.keys.sorted())")
        // Auto-save zone assignments so sleep/wake and reconnect cycles can restore them.
        if let profile = activeZoneProfile {
            for name in Workspace.zoneNames {
                guard let zone = zoneContainers[name] else { continue }
                for window in zone.allLeafWindowsRecursive {
                    ZoneMemory.shared.rememberZone(name, for: window, profile: profile)
                }
            }
        }
        activeZoneProfile = nil
        for name in Workspace.zoneNames {
            guard let zone = zoneContainers[name] else { continue }
            for child in zone.children {
                child.bind(to: rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
            zone.unbindFromParent()
        }
        zoneContainers = [:]
        rootTilingContainer.layout = config.defaultRootContainerLayout
        if let saved = savedRootOrientation {
            rootTilingContainer.changeOrientation(saved)
            savedRootOrientation = nil
        }
    }

    /// Returns the theoretical physical rect for the named zone, computed from adaptive weights
    /// and the monitor's visible rect. Used when `lastAppliedLayoutPhysicalRect` is not yet set
    /// (e.g. the workspace has never been visible). Returns nil if zones are not active or the
    /// named zone does not exist.
    /// When zone-focus-mode is active, uses the saved (pre-collapse) weights so the rects
    /// reflect actual zone proportions rather than the 8px collapsed slivers.
    @MainActor
    func theoreticalZoneRect(for zoneName: String) -> Rect? {
        let containers = Workspace.zoneNames.compactMap { name in zoneContainers[name].map { (name, $0) } }
        guard containers.count == 3 else { return nil }
        let monitorRect = workspaceMonitor.visibleRect
        let effectiveWeight: (String, TilingContainer) -> CGFloat = { [saved = savedZoneWeights] name, c in
            saved?[name] ?? c.getWeight(.h)
        }
        let totalWeight = containers.reduce(0.0) { $0 + effectiveWeight($1.0, $1.1) }
        guard totalWeight > 0 else { return nil }
        var xOffset = monitorRect.minX
        for (name, container) in containers {
            let zoneWidth = monitorRect.width * (effectiveWeight(name, container) / totalWeight)
            if name == zoneName {
                return Rect(topLeftX: xOffset, topLeftY: monitorRect.topLeftY, width: zoneWidth, height: monitorRect.height)
            }
            xOffset += zoneWidth
        }
        return nil
    }

    /// Returns the zone name whose horizontal slice contains >50% of the window's area,
    /// or nil if no zone clears that threshold. On an exact tie, returns the leftmost zone.
    /// When zone-focus-mode is active, uses saved weights so overlap is computed against
    /// real proportions, not collapsed slivers.
    @MainActor
    func zoneForWindowRect(_ windowRect: Rect) -> String? {
        let containers = Workspace.zoneNames.compactMap { name in zoneContainers[name].map { (name, $0) } }
        guard containers.count == 3 else { return nil }

        let monitorRect = workspaceMonitor.visibleRect
        let effectiveWeight: (String, TilingContainer) -> CGFloat = { [saved = savedZoneWeights] name, c in
            saved?[name] ?? c.getWeight(.h)
        }
        let totalWeight = containers.reduce(0.0) { $0 + effectiveWeight($1.0, $1.1) }
        guard totalWeight > 0 else { return nil }

        var xOffset: CGFloat = monitorRect.minX
        var bestZone: String? = nil
        var bestOverlapArea: CGFloat = -1

        for (name, container) in containers {
            let zoneWidth: CGFloat = monitorRect.width * (effectiveWeight(name, container) / totalWeight)
            let overlapMinX: CGFloat = max(windowRect.minX, xOffset)
            let overlapMaxX: CGFloat = min(windowRect.maxX, xOffset + zoneWidth)
            if overlapMaxX > overlapMinX {
                let overlapArea: CGFloat = (overlapMaxX - overlapMinX) * windowRect.height
                if overlapArea > bestOverlapArea {
                    bestOverlapArea = overlapArea
                    bestZone = name
                }
                // Ties keep the leftmost (already the case since we iterate left→right)
            }
            xOffset += zoneWidth
        }

        let windowArea: CGFloat = windowRect.width * windowRect.height
        guard windowArea > 0, let bestZone, bestOverlapArea / windowArea > 0.5 else { return nil }
        return bestZone
    }
}

private func validatedZoneWidths(_ widths: [Double]) -> [Double] {
    guard widths.count == 3, abs(widths.reduce(0, +) - 1.0) < 0.01, widths.allSatisfy({ $0 > 0 }) else {
        return [1.0 / 3, 1.0 / 3, 1.0 / 3]
    }
    return widths
}
