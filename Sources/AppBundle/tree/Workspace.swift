import AppKit
import Common

@MainActor private var workspaceNameToWorkspace: [String: Workspace] = [:]

fileprivate struct MonitorIdentity: Hashable {
    let name: String
    let entry: MonitorProfile.MonitorEntry
}

extension Monitor {
    fileprivate var identity: MonitorIdentity {
        MonitorIdentity(
            name: name,
            entry: MonitorProfile.MonitorEntry(width: rect.width, height: rect.height),
        )
    }
}

@MainActor private var monitorIdentityToLastVisibleWorkspace: [MonitorIdentity: String] = [:]
@MainActor private var screenPointToLastVisibleWorkspace: [CGPoint: String] = [:]
@MainActor private var previousMonitorEntries: [MonitorProfile.MonitorEntry] = []
@MainActor private var previousScreenPoints: Set<CGPoint> = []
@MainActor private var screenPointToVisibleWorkspace: [CGPoint: Workspace] = [:]
@MainActor private var visibleWorkspaceToScreenPoint: [Workspace: CGPoint] = [:]

@MainActor
func resetMonitorAssignmentStateForTests() {
    monitorIdentityToLastVisibleWorkspace = [:]
    screenPointToLastVisibleWorkspace = [:]
    previousMonitorEntries = []
    previousScreenPoints = []
    screenPointToVisibleWorkspace = [:]
    visibleWorkspaceToScreenPoint = [:]
}

// The returned workspace must be invisible and it must belong to the requested monitor
@MainActor func getStubWorkspace(for monitor: Monitor) -> Workspace {
    if let prev = monitorIdentityToLastVisibleWorkspace[monitor.identity].map({ Workspace.get(byName: $0) }),
       !prev.isVisible && prev.forceAssignedMonitor == nil
    {
        return prev
    }
    if let prev = screenPointToLastVisibleWorkspace[monitor.rect.topLeftCorner].map({ Workspace.get(byName: $0) }),
       !prev.isVisible && prev.forceAssignedMonitor == nil
    {
        return prev
    }
    if let candidate = Workspace.all
        .first(where: { !$0.isVisible && $0.workspaceMonitor.identity == monitor.identity })
    {
        return candidate
    }
    return getEmptyStubWorkspace()
}

@MainActor
private func getEmptyStubWorkspace() -> Workspace {
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
    fileprivate var assignedMonitorIdentity: MonitorIdentity? = nil
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
    /// Non-nil while meeting mode is temporarily overriding this workspace's zone topology.
    var meetingModeSnapshot: MeetingModeSnapshot? = nil
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
    func resetMonitorAssignmentForTests() {
        assignedMonitorPoint = nil
        assignedMonitorIdentity = nil
    }

    @MainActor
    var isVisible: Bool { visibleWorkspaceToScreenPoint.keys.contains(self) }
    @MainActor
    var workspaceMonitor: Monitor {
        forceAssignedMonitor
            ?? visibleWorkspaceToScreenPoint[self]?.monitorApproximation
            ?? assignedMonitorIdentity.flatMap({ identity in monitors.first(where: { $0.identity == identity }) })
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
func gcMonitors() async {
    guard monitors.allSatisfy(\.isStableTopologyMonitor) else {
        return
    }
    let currentEntries = monitors.map { MonitorProfile.MonitorEntry(width: $0.rect.width, height: $0.rect.height) }
    let profileChanged = currentEntries.counts != previousMonitorEntries.counts
    if screenPointToVisibleWorkspace.count != monitors.count || profileChanged {
        rearrangeWorkspacesOnMonitors()
        await applyMatchingMonitorProfile()
    }
}

extension CGPoint {
    @MainActor
    fileprivate func setActiveWorkspace(_ workspace: Workspace, persistAssignment: Bool = true) -> Bool {
        if !isValidAssignment(workspace: workspace, screen: self) {
            return false
        }
        if let prevMonitorPoint = visibleWorkspaceToScreenPoint[workspace] {
            visibleWorkspaceToScreenPoint.removeValue(forKey: workspace)
            screenPointToVisibleWorkspace.removeValue(forKey: prevMonitorPoint)
        }
        if let prevWorkspace = screenPointToVisibleWorkspace[self] {
            screenPointToVisibleWorkspace.removeValue(forKey: self)
            visibleWorkspaceToScreenPoint.removeValue(forKey: prevWorkspace)
        }
        visibleWorkspaceToScreenPoint[workspace] = self
        screenPointToVisibleWorkspace[self] = workspace
        if persistAssignment {
            let monitor = self.monitorApproximation
            workspace.assignedMonitorPoint = self
            workspace.assignedMonitorIdentity = monitor.identity
            screenPointToLastVisibleWorkspace[self] = workspace.name
            monitorIdentityToLastVisibleWorkspace[monitor.identity] = workspace.name
        }
        workspace.ensureZoneContainers(for: self.monitorApproximation)
        return true
    }
}

@MainActor
private func rearrangeWorkspacesOnMonitors() {
    let currentEntries = monitors.map { MonitorProfile.MonitorEntry(width: $0.rect.width, height: $0.rect.height) }
    var prevCounts: [MonitorProfile.MonitorEntry: Int] = [:]
    for entry in previousMonitorEntries {
        prevCounts[entry, default: 0] += 1
    }
    var currCounts: [MonitorProfile.MonitorEntry: Int] = [:]
    for entry in currentEntries {
        currCounts[entry, default: 0] += 1
    }
    var newlyAdded: [MonitorProfile.MonitorEntry] = []
    for (entry, currCount) in currCounts {
        let surplus = currCount - (prevCounts[entry] ?? 0)
        if surplus > 0 {
            newlyAdded.append(contentsOf: Array(repeating: entry, count: surplus))
        }
    }

    let oldScreenPointToVisibleWorkspace = screenPointToVisibleWorkspace
    let focusedWorkspace: Workspace? = oldScreenPointToVisibleWorkspace.isEmpty ? nil : focus.workspace
    let focusedWorkspaceScreen = focusedWorkspace.flatMap { workspace in
        oldScreenPointToVisibleWorkspace.first(where: { $0.value == workspace })?.key
    }
    let newMonitors = monitors
    let newScreens = newMonitors.map(\.rect.topLeftCorner)
    let focusedMonitorRemoved = focusedWorkspaceScreen.map { !newScreens.contains($0) } ?? false
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

    screenPointToVisibleWorkspace = [:]
    visibleWorkspaceToScreenPoint = [:]

    var assignedWorkspaces: Set<Workspace> = []
    if let focusedWorkspace,
       focusedMonitorRemoved,
       let focusedWorkspaceScreen,
       let targetScreen = newScreens.minBy({ ($0 - focusedWorkspaceScreen).vectorLength })
    {
        check(targetScreen.setActiveWorkspace(focusedWorkspace, persistAssignment: false),
              "Can't temporarily move focused workspace (\(focusedWorkspace)) to surviving monitor (\(targetScreen))")
        assignedWorkspaces.insert(focusedWorkspace)
    }

    for monitor in newMonitors {
        let screen = monitor.rect.topLeftCorner
        guard screenPointToVisibleWorkspace[screen] == nil else { continue }

        if let remembered = monitorIdentityToLastVisibleWorkspace[monitor.identity]
            .map({ Workspace.get(byName: $0) })?
            .takeIf({ !assignedWorkspaces.contains($0) && $0.forceAssignedMonitor == nil }),
           screen.setActiveWorkspace(remembered)
        {
            assignedWorkspaces.insert(remembered)
            continue
        }

        if let existingVisibleWorkspace = newScreenToOldScreenMapping[screen]
            .flatMap({ oldScreenPointToVisibleWorkspace[$0] })?
            .takeIf({ !assignedWorkspaces.contains($0) }),
           screen.setActiveWorkspace(existingVisibleWorkspace)
        {
            assignedWorkspaces.insert(existingVisibleWorkspace)
            continue
        }

        let stubWorkspace = getStubWorkspace(for: monitor).takeIf { !assignedWorkspaces.contains($0) } ?? getEmptyStubWorkspace()
        check(screen.setActiveWorkspace(stubWorkspace),
              "getStubWorkspace generated incompatible stub workspace (\(stubWorkspace)) for the monitor (\(screen)")
        assignedWorkspaces.insert(stubWorkspace)
    }

    for workspace in Workspace.all {
        workspace.ensureZoneContainers(for: workspace.workspaceMonitor)
    }

    previousMonitorEntries = currentEntries

    var removedEntries: [MonitorProfile.MonitorEntry] = []
    for (entry, prevCount) in prevCounts {
        let surplus = prevCount - (currCounts[entry] ?? 0)
        if surplus > 0 {
            removedEntries.append(contentsOf: Array(repeating: entry, count: surplus))
        }
    }

    let positionsChanged = !previousScreenPoints.isEmpty && Set(newScreens) != previousScreenPoints
    previousScreenPoints = Set(newScreens)

    if !isStartup && (!newlyAdded.isEmpty || !removedEntries.isEmpty || positionsChanged) {
        broadcastEvent(.monitorChanged(monitorCount: monitors.count))

        let changedAspectRatios: [CGFloat]
        if !newlyAdded.isEmpty || !removedEntries.isEmpty {
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
                guard let token: RunSessionGuard = .isServerEnabled else { return }
                try await runLightSession(.onMonitorChanged, token) {
                    for rule in rulesToFire {
                        _ = try await rule.run.runCmdSeq(.defaultEnv.copy(\.commandSource, .onMonitorChanged), .emptyStdin)
                    }
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
    struct MeetingModeSnapshot {
        let zoneDefinitions: [ZoneDefinition]
        let windowZoneAssignments: [UInt32: String?]
        let zoneWindowOrder: [String: [UInt32]]
        let previouslyFocusedWindowId: UInt32?
        let focusedZone: String?
        let savedZoneWeights: [String: CGFloat]?
        let focusModeZone: String?
        let previousActiveZonePresetName: String?
    }

    @MainActor
    func currentLiveZoneDefinitions() -> [ZoneDefinition] {
        let defs = activeZoneDefinitions
        guard !defs.isEmpty else { return config.zones.zones }
        let saved = savedZoneWeights
        var raw: [(id: String, weight: CGFloat, layout: Layout)] = []
        for def in defs {
            let container = zoneContainers[def.id]
            let weight = saved?[def.id] ?? container?.getWeight(.h) ?? CGFloat(def.width)
            let layout = container?.layout ?? def.layout
            raw.append((def.id, weight, layout))
        }
        let total = raw.reduce(0.0) { $0 + $1.weight }
        guard total > 0 else { return config.zones.zones }
        return raw.map { ZoneDefinition(id: $0.id, width: Double($0.weight / total), layout: $0.layout) }
    }

    @MainActor
    func reapplyZoneFocusModeIfNeeded() {
        guard let saved = savedZoneWeights, let focusModeZone else { return }
        guard zoneContainers[focusModeZone] != nil else {
            savedZoneWeights = nil
            self.focusModeZone = nil
            return
        }
        let nonFocusedCount = CGFloat(activeZoneDefinitions.count - 1)
        let totalWeight = saved.values.reduce(0, +)
        guard totalWeight > 0 else { return }
        for def in activeZoneDefinitions {
            guard let container = zoneContainers[def.id] else { continue }
            if def.id == focusModeZone {
                let focusedWeight = max(0, totalWeight - CGFloat(config.zones.focusModeCollapsedWidth) * max(0, nonFocusedCount))
                container.setWeight(.h, focusedWeight)
            } else {
                container.setWeight(.h, CGFloat(config.zones.focusModeCollapsedWidth))
            }
        }
    }

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
        guard monitor.isStableTopologyMonitor else { return }
        let shouldHaveZones = monitor.isUltrawide && !zonesDisabledByProfile
        if shouldHaveZones && zoneContainers.isEmpty {
            activateZones(monitorWidth: monitor.visibleRect.width)
        } else if shouldHaveZones && !zoneContainers.isEmpty && force {
            if meetingModeSnapshot != nil {
                rebuildZoneContainers(
                    for: monitor,
                    zoneDefinitions: activeZoneDefinitions,
                    saveZoneAssignments: false,
                    shouldRestoreZoneMemory: false,
                )
            } else {
                rebuildZoneContainers(for: monitor, zoneDefinitions: config.zones.zones)
            }
        } else if !shouldHaveZones && !zoneContainers.isEmpty {
            if let snapshot = meetingModeSnapshot {
                activeZonePresetName = snapshot.previousActiveZonePresetName
                meetingModeSnapshot = nil
                deactivateZones(saveAssignments: false)
            } else {
                deactivateZones()
            }
        }
    }

    @MainActor
    func rebuildZoneContainers(
        for monitor: Monitor,
        zoneDefinitions: [ZoneDefinition],
        saveZoneAssignments: Bool = true,
        shouldRestoreZoneMemory: Bool = true
    ) {
        if !zoneContainers.isEmpty {
            deactivateZones(saveAssignments: saveZoneAssignments)
        }
        activateZones(
            monitorWidth: monitor.visibleRect.width,
            zoneDefinitions: zoneDefinitions,
            shouldRestoreZoneMemory: shouldRestoreZoneMemory,
        )
    }

    @MainActor
    private func activateZones(
        monitorWidth: CGFloat,
        zoneDefinitions: [ZoneDefinition] = config.zones.zones,
        shouldRestoreZoneMemory: Bool = true
    ) {
        activeZoneProfile = MonitorProfile([workspaceMonitor])
        activeZoneDefinitions = zoneDefinitions
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
        telemetryLog("zone.activated", payload: compactTelemetry(
            ("monitorName", .string(workspaceMonitor.name)),
            ("presetName", telemetryString(activeZonePresetName)),
            ("workspace", .string(name)),
            ("zoneCount", .int(activeZoneDefinitions.count))
        ))
        if shouldRestoreZoneMemory {
            restoreWindowPlacementsAfterZoneActivation()
        }
    }

    @MainActor
    func restoreWindowPlacementsAfterZoneActivation() {
        let profile = MonitorProfile([workspaceMonitor])
        let defs = activeZoneDefinitions
        let windows = rootTilingContainer.allLeafWindowsRecursive
        for window in windows {
            let decision: WindowTilingPlacementDecision?
            if let appBundleId = window.app.rawAppBundleId,
               let zoneName = config.zones.appRouting[appBundleId]
            {
                decision = resolveZonePlacement(preferredZoneName: zoneName, source: .appRouting)
            } else if let zoneName = ZoneMemory.shared.rememberedZone(for: window, profile: profile) {
                decision = resolveZonePlacement(preferredZoneName: zoneName, source: .zoneMemory)
            } else if let zoneName = window.lastPlacementRecord?.zoneName {
                decision = resolveZonePlacement(preferredZoneName: zoneName, source: .lastKnownZone)
            } else {
                decision = resolveZonePlacement(
                    preferredZoneName: defs.isEmpty ? nil : defs[defs.count / 2].id,
                    source: .middleZoneFallback
                )
            }
            guard let decision else { continue }
            let binding = decision.bindingData
            window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
            binding.preferredMostRecentChildAfterBind?.markAsMostRecentChild()
            recordPlacement(decision, for: window)
            broadcastWindowRouted(decision, for: window)
        }
    }

    @MainActor
    private func deactivateZones(saveAssignments: Bool = true) {
        let previousZoneCount = activeZoneDefinitions.count
        let previousPresetName = activeZonePresetName
        if saveAssignments, let profile = activeZoneProfile {
            ZoneMemory.shared.withBatchUpdate {
                for zoneName in activeZoneDefinitions.map(\.id) {
                    guard let zone = zoneContainers[zoneName] else { continue }
                    for window in zone.allLeafWindowsRecursive {
                        ZoneMemory.shared.rememberZone(zoneName, for: window, profile: profile)
                    }
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
        telemetryLog("zone.deactivated", payload: compactTelemetry(
            ("monitorName", .string(workspaceMonitor.name)),
            ("presetName", telemetryString(previousPresetName)),
            ("workspace", .string(name)),
            ("zoneCount", .int(previousZoneCount))
        ))
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
