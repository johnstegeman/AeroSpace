import Common

struct FocusZoneCommand: Command {
    let args: FocusZoneCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let workspace = target.workspace
        let zoneName = args.zone.val.rawValue
        guard let zone = workspace.zoneContainers[zoneName] else {
            return .fail(io.err("focus-zone: zones not active on this workspace"))
        }
        if let mruWindow = zone.mostRecentWindowRecursive {
            // Zone has windows: focus the MRU one (also updates workspace MRU for new window routing)
            workspace.focusedZone = nil
            return .from(bool: mruWindow.focusWindow())
        } else {
            // Zone is empty: set one-shot placement hint and update menu bar
            workspace.focusedZone = zoneName
            updateTrayText()
            return .succ
        }
    }
}
