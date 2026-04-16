import AppKit
import Common

struct ZonePresetCommand: Command {
    let args: ZonePresetCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        if args.reset {
            config.zones = defaultZonesConfig
        } else if let name = args.presetName {
            guard let preset = config.zonePresets[name] else {
                return .fail(io.err("zone-preset: unknown preset '\(name)'. Available: \(config.zonePresets.keys.sorted().joined(separator: ", "))"))
            }
            config.zones = config.zones.copy(\.widths, preset.widths).copy(\.layouts, preset.layouts)
        }
        // Exit focus mode on all workspaces before rebuilding — stale savedZoneWeights from
        // before the preset would otherwise overwrite the new preset widths on zone-focus-mode off.
        for workspace in Workspace.all {
            workspace.savedZoneWeights = nil
            workspace.focusModeZone = nil
        }
        // Rebuild zone containers on all visible workspaces with force=true to pick up new widths/layouts.
        for workspace in Workspace.all where workspace.isVisible {
            workspace.ensureZoneContainers(for: workspace.workspaceMonitor, force: true)
        }
        updateTrayText()
        return .succ
    }
}
