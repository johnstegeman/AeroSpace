import AppKit
import Common

@MainActor private var workspaceNameToWorkspace: [String: Workspace] = [:]

@MainActor private var screenPointToPrevVisibleWorkspace: [CGPoint: String] = [:]
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
    /// Ordered zone definitions that were active when zones were last activated.
    var activeZoneDefinitions: [ZoneDefinition] = []

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
    if screenPointToVisibleWorkspace.count != monitors.count {
        rearrangeWorkspacesOnMonitors()
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
    func zoneContaining(_ window: Window) -> (name: String, container: TilingContainer)? {
        let zoneContainer = window.parents
            .first(where: { ($0 as? TilingContainer)?.isZoneContainer == true }) as? TilingContainer
        guard let zoneContainer else { return nil }
        guard let zoneName = zoneContainers.first(where: { $0.value === zoneContainer })?.key else { return nil }
        return (zoneName, zoneContainer)
    }

    @MainActor
    func newWindowInsertionPolicy(for zoneName: String) -> ZoneNewWindowPolicy {
        config.zones.behavior[zoneName]?.newWindow ?? .afterFocused
    }

    @MainActor
    func bindingDataForNewWindow(inZone zoneName: String, zone: TilingContainer) -> BindingData {
        switch newWindowInsertionPolicy(for: zoneName) {
            case .append:
                return BindingData(parent: zone, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            case .afterFocused:
                if let zoneWindow = zone.mostRecentWindowRecursive,
                   let parent = zoneWindow.parent as? TilingContainer
                {
                    return BindingData(
                        parent: parent,
                        adaptiveWeight: WEIGHT_AUTO,
                        index: zoneWindow.ownIndex.orDie() + 1,
                    )
                }
                return BindingData(parent: zone, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            case .appendHidden:
                let preservedMru = zone.layout == .stack ? zone.mostRecentChild : nil
                return BindingData(
                    parent: zone,
                    adaptiveWeight: WEIGHT_AUTO,
                    index: INDEX_BIND_LAST,
                    preferredMostRecentChildAfterBind: preservedMru,
                )
        }
    }

    @MainActor
    func ensureZoneContainers(for monitor: Monitor, force: Bool = false) {
        if monitor.isUltrawide && zoneContainers.isEmpty {
            activateZones(monitorWidth: monitor.visibleRect.width)
        } else if monitor.isUltrawide && !zoneContainers.isEmpty && force {
            deactivateZones()
            activateZones(monitorWidth: monitor.visibleRect.width)
        } else if !monitor.isUltrawide && !zoneContainers.isEmpty {
            deactivateZones()
        }
    }

    @MainActor
    private func activateZones(monitorWidth: CGFloat) {
        activeZoneProfile = MonitorProfile([workspaceMonitor])
        activeZoneDefinitions = config.zones.zones
        savedRootOrientation = rootTilingContainer.orientation
        rootTilingContainer.changeOrientation(.h)
        rootTilingContainer.layout = .tiles
        for def in activeZoneDefinitions {
            let container = TilingContainer(
                parent: rootTilingContainer,
                adaptiveWeight: monitorWidth * def.width,
                .h,
                def.layout,
                index: INDEX_BIND_LAST,
            )
            container.isZoneContainer = true
            zoneContainers[def.id] = container
        }
        restoreZoneMemory()
    }

    @MainActor
    func restoreZoneMemory() {
        let profile = MonitorProfile([workspaceMonitor])
        let defs = activeZoneDefinitions
        let fallbackZone = defs.isEmpty ? nil : zoneContainers[defs[defs.count / 2].id]
        let windows = rootTilingContainer.allLeafWindowsRecursive
        for window in windows {
            guard let zoneName = ZoneMemory.shared.rememberedZone(for: window, profile: profile) else { continue }
            let zone = zoneContainers[zoneName] ?? fallbackZone
            if let zone {
                let targetZoneName = zoneContainers[zoneName] != nil ? zoneName : defs[defs.count / 2].id
                let binding = bindingDataForNewWindow(inZone: targetZoneName, zone: zone)
                window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
                binding.preferredMostRecentChildAfterBind?.markAsMostRecentChild()
            }
        }
    }

    @MainActor
    private func deactivateZones() {
        if let profile = activeZoneProfile {
            for zoneName in activeZoneDefinitions.map(\.id) {
                guard let zone = zoneContainers[zoneName] else { continue }
                for window in zone.allLeafWindowsRecursive {
                    ZoneMemory.shared.rememberZone(zoneName, for: window, profile: profile)
                }
            }
        }
        activeZoneProfile = nil
        let orderedZoneNames = activeZoneDefinitions.map(\.id)
        activeZoneDefinitions = []
        for zoneName in orderedZoneNames {
            guard let zone = zoneContainers[zoneName] else { continue }
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

    /// Returns the zone name whose horizontal slice contains >50% of the window's area,
    /// or nil if no zone clears that threshold. On an exact tie, returns the leftmost zone.
    @MainActor
    func zoneForWindowRect(_ windowRect: Rect) -> String? {
        let containers = activeZoneDefinitions.compactMap { def in zoneContainers[def.id].map { (def.id, $0) } }
        guard !containers.isEmpty else { return nil }

        let monitorRect = workspaceMonitor.visibleRect
        let effectiveWeight: (String, TilingContainer) -> CGFloat = { [saved = savedZoneWeights] name, container in
            saved?[name] ?? container.getWeight(.h)
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

    @MainActor
    func theoreticalZoneRect(for zoneName: String) -> Rect? {
        let containers = activeZoneDefinitions.compactMap { def in zoneContainers[def.id].map { (def.id, $0) } }
        guard containers.count == activeZoneDefinitions.count, !containers.isEmpty else { return nil }

        let monitorRect = workspaceMonitor.visibleRect
        let effectiveWeight: (String, TilingContainer) -> CGFloat = { [saved = savedZoneWeights] name, container in
            saved?[name] ?? container.getWeight(.h)
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
}

extension Sequence<MonitorProfile.MonitorEntry> {
    fileprivate var counts: [Element: Int] {
        reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}
