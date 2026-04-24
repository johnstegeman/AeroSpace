import Common

struct MoveNodeToZoneCommand: Command {
    let args: MoveNodeToZoneCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        let workspace = window.nodeWorkspace ?? focus.workspace
        let zoneName = args.zone.val
        guard let zone = workspace.zoneContainers[zoneName] else {
            return .fail(io.err("move-node-to-zone: zones not active on this workspace"))
        }
        let binding = workspace.bindingDataForNewWindow(inZone: zoneName, zone: zone)
        window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
        binding.preferredMostRecentChildAfterBind?.markAsMostRecentChild()
        ZoneMemory.shared.rememberZone(zoneName, for: window, profile: MonitorProfile([workspace.workspaceMonitor]))
        if args.noFocus { return .succ }
        return .from(bool: window.focusWindow())
    }
}
