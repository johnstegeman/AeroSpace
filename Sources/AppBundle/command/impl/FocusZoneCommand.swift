import Common

struct FocusZoneCommand: Command {
    let args: FocusZoneCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let workspace = target.workspace
        guard !workspace.zoneContainers.isEmpty else {
            return .fail(io.err("focus-zone: zones not active on this workspace"))
        }

        let zoneName: String
        if args.scope == .mru {
            // Pick the most-recently-used zone that is not the current zone.
            let currentZone = focus.windowOrNil.flatMap { w in
                Workspace.zoneNames.first { workspace.zoneContainers[$0]?.allLeafWindowsRecursive.contains(where: { $0 === w }) == true }
            }
            zoneName = workspace.mruZones.first(where: { $0 != currentZone })
                ?? Workspace.zoneNames.first(where: { $0 != currentZone })
                ?? Workspace.zoneNames[0]
        } else {
            zoneName = args.zone!.rawValue
        }

        guard let zone = workspace.zoneContainers[zoneName] else {
            return .fail(io.err("focus-zone: zone '\(zoneName)' not found"))
        }

        // Update MRU history: push zoneName to front, keep unique, cap at 10 entries.
        workspace.mruZones.removeAll { $0 == zoneName }
        workspace.mruZones.insert(zoneName, at: 0)
        if workspace.mruZones.count > 10 { workspace.mruZones.removeLast() }

        // If focus mode is active and targeting a different zone, switch the focused zone.
        if workspace.savedZoneWeights != nil, zoneName != workspace.focusModeZone {
            ZoneFocusModeCommand(args: ZoneFocusModeCmdArgs(rawArgs: [], .on)).run(env, io)
        }

        if let mruWindow = zone.mostRecentWindowRecursive {
            workspace.focusedZone = nil
            return .from(bool: mruWindow.focusWindow())
        } else {
            workspace.focusedZone = zoneName
            updateTrayText()
            return .succ
        }
    }
}
