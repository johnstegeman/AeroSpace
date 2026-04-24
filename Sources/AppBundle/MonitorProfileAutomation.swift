import AppKit
import Common

@MainActor var activeMonitorProfileName: String? = nil
@MainActor var zonesDisabledByProfile: Bool = false
@MainActor var monitorProfileManagedZoneLayout: Bool = false

@MainActor
private func refreshWorkspacesAfterZoneLayoutChange() {
    for workspace in Workspace.all {
        workspace.savedZoneWeights = nil
        workspace.focusModeZone = nil
        workspace.ensureZoneContainers(for: workspace.workspaceMonitor, force: true)
    }
    updateTrayText()
}

@MainActor
private func clearMonitorProfileZoneLayoutIfNeeded() {
    let previousPresetName = activeZonePresetName
    let hadManagedLayout = monitorProfileManagedZoneLayout || zonesDisabledByProfile
    guard hadManagedLayout else { return }

    zonesDisabledByProfile = false
    if monitorProfileManagedZoneLayout {
        config.zones = defaultZonesConfig
        activeZonePresetName = nil
        monitorProfileManagedZoneLayout = false
    }
    refreshWorkspacesAfterZoneLayoutChange()
    if activeZonePresetName != previousPresetName {
        broadcastEvent(.zonePresetChanged(workspace: focus.workspace.name, presetName: activeZonePresetName))
    }
}

@MainActor
func applyMatchingMonitorProfile() async {
    let matched = config.monitorProfiles.first { profile in
        let matcher = profile.matcher
        if let minAspectRatio = matcher.minAspectRatio {
            guard monitors.contains(where: { $0.visibleRect.width / $0.visibleRect.height >= minAspectRatio }) else {
                return false
            }
        }
        if let monitorCount = matcher.monitorCount, monitors.count != monitorCount {
            return false
        }
        return true
    }

    let previousProfileName = activeMonitorProfileName
    activeMonitorProfileName = matched?.name

    if let directive = matched?.applyZoneLayout {
        if directive == "disabled" {
            monitorProfileManagedZoneLayout = true
            if !zonesDisabledByProfile {
                zonesDisabledByProfile = true
                refreshWorkspacesAfterZoneLayoutChange()
            }
        } else if let preset = config.zonePresets[directive] {
            let previousPresetName = activeZonePresetName
            monitorProfileManagedZoneLayout = true
            zonesDisabledByProfile = false
            config.zones = config.zones.copy(\.zones, preset.zones)
            activeZonePresetName = directive
            refreshWorkspacesAfterZoneLayoutChange()
            if activeZonePresetName != previousPresetName {
                broadcastEvent(.zonePresetChanged(workspace: focus.workspace.name, presetName: directive))
            }
        } else {
            eprint("monitor-profile '\(matched?.name ?? "unknown")': unknown apply-zone-layout preset '\(directive)'")
            clearMonitorProfileZoneLayoutIfNeeded()
        }
    } else {
        clearMonitorProfileZoneLayoutIfNeeded()
    }

    if matched?.name != previousProfileName, let snapshotName = matched?.restoreWorkspaceSnapshot {
        _ = await WorkspaceSnapshot.restoreReturningExitCode(name: snapshotName, io: CmdIo(stdin: .emptyStdin))
    }
}
