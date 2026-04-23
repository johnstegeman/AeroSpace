import Common

enum WindowTilingPlacementSource: String {
    case zoneMemory
    case startupRect
    case focusedZoneHint
    case mruZone
    case mruContainer
    case middleZoneFallback
    case rootFallback
}

struct WindowTilingPlacementDecision {
    let source: WindowTilingPlacementSource
    let bindingData: BindingData
}

@MainActor
func resolveNewTilingWindowPlacement(
    in workspace: Workspace,
    appBundleId: String?,
    startupRect: Rect? = nil
) -> WindowTilingPlacementDecision {
    if let appBundleId,
       let profile = workspace.activeZoneProfile,
       let zoneName = ZoneMemory.shared.rememberedZone(forBundleId: appBundleId, profile: profile),
       let decision = workspace.resolveZonePlacement(preferredZoneName: zoneName, source: .zoneMemory)
    {
        return decision
    }
    if let startupRect, !workspace.zoneContainers.isEmpty,
       let zoneName = workspace.zoneForWindowRect(startupRect),
       let decision = workspace.resolveZonePlacement(preferredZoneName: zoneName, source: .startupRect)
    {
        return decision
    }
    if let hintZone = workspace.focusedZone,
       let decision = workspace.resolveZonePlacement(preferredZoneName: hintZone, source: .focusedZoneHint)
    {
        workspace.focusedZone = nil
        return decision
    }
    let mruWindow = workspace.mostRecentWindowRecursive
    if let mruWindow, let (zoneName, _) = workspace.zoneContaining(mruWindow),
       let decision = workspace.resolveZonePlacement(preferredZoneName: zoneName, source: .mruZone)
    {
        return decision
    }
    if let mruWindow, let tilingParent = mruWindow.parent as? TilingContainer {
        return WindowTilingPlacementDecision(
            source: .mruContainer,
            bindingData: BindingData(
                parent: tilingParent,
                adaptiveWeight: WEIGHT_AUTO,
                index: mruWindow.ownIndex.orDie() + 1
            )
        )
    }
    if let decision = workspace.resolveZonePlacement(
        preferredZoneName: workspace.activeZoneDefinitions[safe: workspace.activeZoneDefinitions.count / 2]?.id,
        source: .middleZoneFallback
    ) {
        return decision
    }
    return WindowTilingPlacementDecision(
        source: .rootFallback,
        bindingData: BindingData(parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    )
}

@MainActor
func applyRuntimePlacementDefaults(_ window: Window) {
    guard let workspace = window.nodeWorkspace else { return }

    if !window.isFloating,
       FloatingMemory.shared.isRemembered(windowId: window.windowId)
    {
        window.bindAsFloatingWindow(to: workspace)
    }

    if !window.isFloating,
       let bundleId = window.app.rawAppBundleId,
       config.floating.appIds.contains(bundleId)
    {
        window.bindAsFloatingWindow(to: workspace)
    }

    if StickyMemory.shared.isRemembered(windowId: window.windowId) {
        window.bindAsFloatingWindow(to: focus.workspace)
    }

    if ScratchpadMemory.shared.isRemembered(windowId: window.windowId),
       window.nodeWorkspace != Workspace.scratchpad
    {
        window.bindAsFloatingWindow(to: Workspace.scratchpad)
    }
}

extension Workspace {
    @MainActor
    func resolveZonePlacement(
        preferredZoneName: String?,
        source: WindowTilingPlacementSource
    ) -> WindowTilingPlacementDecision? {
        let resolvedZoneName = preferredZoneName.flatMap { zoneContainers[$0] != nil ? $0 : nil }
            ?? activeZoneDefinitions[safe: activeZoneDefinitions.count / 2]?.id
        guard let resolvedZoneName, let zone = zoneContainers[resolvedZoneName] else { return nil }
        return WindowTilingPlacementDecision(
            source: source,
            bindingData: bindingDataForNewWindow(inZone: resolvedZoneName, zone: zone)
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
