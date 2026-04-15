import Common

struct MoveNodeToZoneCommand: Command {
    let args: MoveNodeToZoneCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        let workspace = window.nodeWorkspace ?? focus.workspace
        let zoneName = args.zone.val.rawValue
        guard let zone = workspace.zoneContainers[zoneName] else {
            return .fail(io.err("move-node-to-zone: zones not active on this workspace"))
        }
        window.bind(to: zone, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        ZoneMemory.shared.rememberZone(zoneName, for: window, profile: MonitorProfile([workspace.workspaceMonitor]))
        return .from(bool: window.focusWindow())
    }
}
