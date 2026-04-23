import Common

struct OverviewZonesCommand: Command {
    let args: OverviewZonesCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    @MainActor
    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        let workspace = focus.workspace
        guard let snapshot = overviewZonesSnapshot(in: workspace) else {
            return .fail(io.err("overview-zones: zones not active on this workspace"))
        }
        OverviewZonesHUDController.shared.toggle(snapshot: snapshot, monitor: workspace.workspaceMonitor)
        return .succ
    }
}
