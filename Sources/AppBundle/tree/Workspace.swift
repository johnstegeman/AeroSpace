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
    /// One-shot hint: place the next new tiling window in this zone, then clear. Set by focus-zone on an empty zone.
    var focusedZone: String? = nil

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
    if screenPointToVisibleWorkspace.count != monitors.count {
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
        activeZoneProfile = MonitorProfile([workspaceMonitor])
        rootTilingContainer.changeOrientation(.h)
        rootTilingContainer.layout = .tiles
        let widths = validatedZoneWidths(config.zones.widths)
        let layouts = config.zones.layouts.count == 3 ? config.zones.layouts : [Layout.tiles, .tiles, .tiles]
        let names = ["left", "center", "right"]
        for (name, (proportion, layout)) in zip(names, zip(widths, layouts)) {
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
        // Auto-save zone assignments so sleep/wake and reconnect cycles can restore them.
        if let profile = activeZoneProfile {
            for name in ["left", "center", "right"] {
                guard let zone = zoneContainers[name] else { continue }
                for window in zone.allLeafWindowsRecursive {
                    ZoneMemory.shared.rememberZone(name, for: window, profile: profile)
                }
            }
        }
        activeZoneProfile = nil
        for name in ["left", "center", "right"] {
            guard let zone = zoneContainers[name] else { continue }
            for child in zone.children {
                child.bind(to: rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
            zone.unbindFromParent()
        }
        zoneContainers = [:]
        rootTilingContainer.layout = config.defaultRootContainerLayout
    }

    /// Returns the zone name whose horizontal slice contains >50% of the window's area,
    /// or nil if no zone clears that threshold. On an exact tie, returns the leftmost zone.
    @MainActor
    func zoneForWindowRect(_ windowRect: Rect) -> String? {
        let names = ["left", "center", "right"]
        let containers = names.compactMap { name in zoneContainers[name].map { (name, $0) } }
        guard containers.count == 3 else { return nil }

        let monitorRect = workspaceMonitor.visibleRect
        let totalWeight = containers.reduce(0.0) { $0 + $1.1.getWeight(.h) }
        guard totalWeight > 0 else { return nil }

        var xOffset: CGFloat = monitorRect.minX
        var bestZone: String? = nil
        var bestOverlapArea: CGFloat = -1

        for (name, container) in containers {
            let zoneWidth: CGFloat = monitorRect.width * (container.getWeight(.h) / totalWeight)
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
