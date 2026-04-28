import AppKit
import Common

@MainActor var activeZonePresetName: String? = nil

struct ZonePresetCommand: Command {
    let args: ZonePresetCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        let targetWorkspace = env.workspaceName.map { Workspace.get(byName: $0) } ?? focus.workspace
        if args.reset {
            config.zones = defaultZonesConfig
            activeZonePresetName = nil
            zonesDisabledByProfile = false
            monitorProfileManagedZoneLayout = false
        } else if let name = args.presetName {
            guard let preset = config.zonePresets[name] else {
                return .fail(io.err("zone-preset: unknown preset '\(name)'. Available: \(config.zonePresets.keys.sorted().joined(separator: ", "))"))
            }
            config.zones = config.zones.copy(\.zones, preset.zones)
            activeZonePresetName = name
            zonesDisabledByProfile = false
            monitorProfileManagedZoneLayout = false
        } else if let name = args.saveName {
            let preset = ZonePreset(zones: targetWorkspace.currentLiveZoneDefinitions())
            config.zonePresets[name] = preset
            io.out("Saved zone preset '\(name)' (\(preset.zones.count) zones)")
            return .succ
        } else if args.export {
            io.out(exportCurrentZones(workspace: targetWorkspace))
            return .succ
        }
        for workspace in Workspace.all {
            workspace.savedZoneWeights = nil
            workspace.focusModeZone = nil
        }
        for workspace in Workspace.all {
            workspace.ensureZoneContainers(for: workspace.workspaceMonitor, force: true)
        }
        updateTrayText()
        broadcastEvent(.zonePresetChanged(workspace: focus.workspace.name, presetName: activeZonePresetName))
        return .succ
    }
}

@MainActor
private func exportCurrentZones(workspace: Workspace) -> String {
    let name = activeZonePresetName ?? "my-layout"
    var lines: [String] = []
    lines.append("[[zone-presets]]")
    lines.append("name = \(tomlBasicString(name))")
    for zone in workspace.currentLiveZoneDefinitions() {
        lines.append("")
        lines.append("[[zone-presets.zone]]")
        lines.append("id = \(tomlBasicString(zone.id))")
        lines.append("width = \(zone.width)")
        lines.append("layout = \(tomlBasicString(zone.layout.rawValue))")
    }
    return lines.joined(separator: "\n")
}

private func tomlBasicString(_ value: String) -> String {
    let escaped = value
        .replacing("\\", with: "\\\\")
        .replacing("\"", with: "\\\"")
        .replacing("\u{08}", with: "\\b")
        .replacing("\u{0C}", with: "\\f")
        .replacing("\n", with: "\\n")
        .replacing("\r", with: "\\r")
        .replacing("\t", with: "\\t")
    return "\"\(escaped)\""
}
