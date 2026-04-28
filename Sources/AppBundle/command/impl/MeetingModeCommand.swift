import Common
import AppKit

struct MeetingModeCommand: Command {
    let args: MeetingModeCmdArgs
    let shouldResetClosedWindowsCache = false

    @MainActor
    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        guard let workspace = await resolveMeetingModeWorkspace(turningOn: args.action.val != .off, io) else {
            return .fail
        }
        let turnOn = switch args.action.val {
            case .on: true
            case .off: false
            case .toggle: workspace.meetingModeSnapshot == nil
        }
        return turnOn
            ? try await enableMeetingMode(on: workspace, monitor: workspace.workspaceMonitor, io)
            : disableMeetingMode(on: workspace, io)
    }
}

@MainActor
func enableMeetingMode(on workspace: Workspace, monitor: Monitor, _ io: CmdIo) async throws -> BinaryExitCode {
    guard config.meeting.isConfigured else {
        return .fail(io.err("meeting-mode: configure [meeting] first"))
    }
    workspace.ensureZoneContainers(for: monitor)
    guard !workspace.zoneContainers.isEmpty else {
        return .fail(io.err("meeting-mode: zones not active on this workspace"))
    }
    if workspace.meetingModeSnapshot != nil {
        return .succ
    }

    let previousActiveZonePresetName = activeZonePresetName
    let previouslyFocusedWindowId = focus.windowOrNil?.takeIf { $0.nodeWorkspace === workspace }?.windowId
    let windows = workspace.rootTilingContainer.allLeafWindowsRecursive
    let currentZoneNames = workspace.activeZoneDefinitions.map(\.id)
    let savedZoneWindowOrder = Dictionary(uniqueKeysWithValues: currentZoneNames.map { zoneName in
        (zoneName, workspace.zoneContainers[zoneName]?.allLeafWindowsRecursive.map(\.windowId) ?? [])
    })
    let savedAssignments = Dictionary(uniqueKeysWithValues: windows.map { window in
        (window.windowId, workspace.zoneContaining(window)?.name)
    })

    workspace.meetingModeSnapshot = Workspace.MeetingModeSnapshot(
        zoneDefinitions: workspace.currentLiveZoneDefinitions(),
        windowZoneAssignments: savedAssignments,
        zoneWindowOrder: savedZoneWindowOrder,
        previouslyFocusedWindowId: previouslyFocusedWindowId,
        focusedZone: workspace.focusedZone,
        savedZoneWeights: workspace.savedZoneWeights,
        focusModeZone: workspace.focusModeZone,
        previousActiveZonePresetName: previousActiveZonePresetName,
    )

    let zoneDefinitions: [ZoneDefinition]
    if let presetName = config.meeting.preset {
        guard let preset = config.zonePresets[presetName] else {
            workspace.meetingModeSnapshot = nil
            return .fail(io.err("meeting-mode: unknown preset '\(presetName)'"))
        }
        activeZonePresetName = presetName
        zoneDefinitions = preset.zones
    } else {
        zoneDefinitions = workspace.currentLiveZoneDefinitions()
    }

    workspace.savedZoneWeights = nil
    workspace.focusModeZone = nil
    workspace.focusedZone = nil
    workspace.rebuildZoneContainers(
        for: monitor,
        zoneDefinitions: zoneDefinitions,
        saveZoneAssignments: false,
        shouldRestoreZoneMemory: false,
    )
    try await awakenMeetingSupportApps()
    routeMeetingModeWindows(
        workspace: workspace,
        windows: windows,
        zoneDefinitions: zoneDefinitions,
        zoneWindowOrder: savedZoneWindowOrder,
        windowZoneAssignments: savedAssignments
    )
    refocusMeetingWorkspace(workspace: workspace, preferredWindowId: previouslyFocusedWindowId)
    updateTrayText()
    if activeZonePresetName != previousActiveZonePresetName {
        broadcastEvent(.zonePresetChanged(workspace: workspace.name, presetName: activeZonePresetName))
    }
    return .succ
}

@MainActor
private func resolveMeetingModeWorkspace(turningOn: Bool, _ io: CmdIo) async -> Workspace? {
    let targetWorkspace = config.meeting.workspace.map(Workspace.get(byName:)) ?? focus.workspace
    guard let configuredWorkspaceName = config.meeting.workspace else {
        return targetWorkspace
    }
    if !turningOn || focus.workspace == targetWorkspace {
        return targetWorkspace
    }

    let focusedMonitor = focus.workspace.workspaceMonitor
    if focusedMonitor.activeWorkspace == targetWorkspace {
        _ = targetWorkspace.focusWorkspace()
        return targetWorkspace
    }
    let previousMonitor = targetWorkspace.isVisible ? targetWorkspace.workspaceMonitor : nil
    if focusedMonitor.setActiveWorkspace(targetWorkspace) {
        if let previousMonitor {
            let stubWorkspace = getStubWorkspace(for: previousMonitor)
            check(
                previousMonitor.setActiveWorkspace(stubWorkspace),
                "getStubWorkspace generated incompatible stub workspace (\(stubWorkspace)) for the monitor (\(previousMonitor)",
            )
        }
        _ = targetWorkspace.focusWorkspace()
        return targetWorkspace
    }
    io.err("meeting-mode: can't activate configured workspace '\(configuredWorkspaceName)' on monitor '\(focusedMonitor.name)'")
    return nil
}

@MainActor
func disableMeetingMode(on workspace: Workspace, _ io: CmdIo) -> BinaryExitCode {
    guard let snapshot = workspace.meetingModeSnapshot else {
        return .succ
    }

    let previousPresetName = activeZonePresetName
    let windows = workspace.rootTilingContainer.allLeafWindowsRecursive
    workspace.rebuildZoneContainers(
        for: workspace.workspaceMonitor,
        zoneDefinitions: snapshot.zoneDefinitions,
        saveZoneAssignments: false,
        shouldRestoreZoneMemory: false,
    )

    restoreWindowsToZones(
        workspace: workspace,
        windows: windows,
        zoneDefinitions: snapshot.zoneDefinitions,
        zoneWindowOrder: snapshot.zoneWindowOrder,
        windowZoneAssignments: snapshot.windowZoneAssignments
    )
    activeZonePresetName = snapshot.previousActiveZonePresetName
    workspace.focusedZone = snapshot.focusedZone
    workspace.savedZoneWeights = snapshot.savedZoneWeights
    workspace.focusModeZone = snapshot.focusModeZone
    workspace.reapplyZoneFocusModeIfNeeded()
    workspace.meetingModeSnapshot = nil

    refocusMeetingWorkspace(workspace: workspace, preferredWindowId: snapshot.previouslyFocusedWindowId)
    updateTrayText()
    if activeZonePresetName != previousPresetName {
        broadcastEvent(.zonePresetChanged(workspace: workspace.name, presetName: activeZonePresetName))
    }
    return .succ
}

@MainActor
private func routeMeetingModeWindows(
    workspace: Workspace,
    windows: [Window],
    zoneDefinitions: [ZoneDefinition],
    zoneWindowOrder: [String: [UInt32]],
    windowZoneAssignments: [UInt32: String?]
) {
    let zoneNames = Set(zoneDefinitions.map(\.id))
    let meetingZoneName = zoneNames.contains(config.meeting.meetingZone) ? config.meeting.meetingZone : nil
    let supportZoneName = zoneNames.contains(config.meeting.supportZone) ? config.meeting.supportZone : nil
    let orderedWindows = orderedMeetingWindows(
        windows: windows,
        zoneWindowOrder: zoneWindowOrder,
        zoneNamesInOrder: zoneDefinitions.map(\.id)
    )

    for window in orderedWindows {
        let bundleId = window.app.rawAppBundleId
        let targetZoneName: String?
        if bundleId.map({ config.meeting.appIds.contains($0) }) == true, let meetingZoneName {
            targetZoneName = meetingZoneName
        } else if bundleId.map({ config.meeting.supportAppIds.contains($0) }) == true, let supportZoneName {
            targetZoneName = supportZoneName
        } else if let previousZone = windowZoneAssignments[window.windowId].flatMap({ $0 }), zoneNames.contains(previousZone) {
            targetZoneName = previousZone
        } else {
            targetZoneName = nil
        }

        if let targetZoneName, let zone = workspace.zoneContainers[targetZoneName] {
            window.bind(to: zone, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        } else {
            let decision = resolveNewTilingWindowPlacement(in: workspace, appBundleId: bundleId)
            let binding = decision.bindingData
            window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
            binding.preferredMostRecentChildAfterBind?.markAsMostRecentChild()
        }
    }
}

@MainActor
private func awakenMeetingSupportApps() async throws {
    guard !isUnitTest, !config.meeting.supportAppIds.isEmpty else { return }
    let frontmostAppBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    let aliveWindowIds = try await MacApp.refreshAllAndGetAliveWindowIds(frontmostAppBundleId: frontmostAppBundleId)
    for runningApp in NSWorkspace.shared.runningApplications {
        guard let bundleId = runningApp.bundleIdentifier,
              config.meeting.supportAppIds.contains(bundleId)
        else { continue }

        if runningApp.isHidden {
            runningApp.unhide()
        }
        guard let macApp = try await MacApp.getOrRegister(runningApp),
              let windowIds = aliveWindowIds[macApp]
        else { continue }
        for windowId in windowIds {
            if try await macApp.isMacosNativeMinimized(windowId) == true {
                macApp.setNativeMinimized(windowId, false)
            }
        }
    }
}

@MainActor
private func orderedMeetingWindows(windows: [Window], zoneWindowOrder: [String: [UInt32]]) -> [Window] {
    orderedMeetingWindows(windows: windows, zoneWindowOrder: zoneWindowOrder, zoneNamesInOrder: Array(zoneWindowOrder.keys))
}

@MainActor
private func orderedMeetingWindows(
    windows: [Window],
    zoneWindowOrder: [String: [UInt32]],
    zoneNamesInOrder: [String]
) -> [Window] {
    let windowsById = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowId, $0) })
    var ordered: [Window] = []
    var seen: Set<UInt32> = []
    for zoneName in zoneNamesInOrder {
        let zoneWindows = zoneWindowOrder[zoneName] ?? []
        for windowId in zoneWindows {
            guard let window = windowsById[windowId], !seen.contains(windowId) else { continue }
            ordered.append(window)
            seen.insert(windowId)
        }
    }
    for window in windows where !seen.contains(window.windowId) {
        ordered.append(window)
    }
    return ordered
}

@MainActor
private func restoreWindowsToZones(
    workspace: Workspace,
    windows: [Window],
    zoneDefinitions: [ZoneDefinition],
    zoneWindowOrder: [String: [UInt32]],
    windowZoneAssignments: [UInt32: String?]
) {
    let windowsById = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowId, $0) })
    var restoredWindowIds: Set<UInt32> = []
    for zoneName in zoneDefinitions.map(\.id) {
        guard let zone = workspace.zoneContainers[zoneName] else { continue }
        for windowId in zoneWindowOrder[zoneName] ?? [] {
            guard let window = windowsById[windowId] else { continue }
            window.bind(to: zone, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            restoredWindowIds.insert(windowId)
        }
    }

    for window in windows where !restoredWindowIds.contains(window.windowId) {
        if let previousZone = windowZoneAssignments[window.windowId].flatMap({ $0 }),
           let zone = workspace.zoneContainers[previousZone]
        {
            window.bind(to: zone, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        } else {
            let decision = resolveNewTilingWindowPlacement(in: workspace, appBundleId: window.app.rawAppBundleId)
            let binding = decision.bindingData
            window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
            binding.preferredMostRecentChildAfterBind?.markAsMostRecentChild()
        }
    }
}

@MainActor
private func refocusMeetingWorkspace(workspace: Workspace, preferredWindowId: UInt32?) {
    if let preferredWindowId, let focusedWindow = Window.get(byId: preferredWindowId) {
        _ = focusedWindow.focusWindow()
    } else {
        _ = workspace.focusWorkspace()
    }
}
