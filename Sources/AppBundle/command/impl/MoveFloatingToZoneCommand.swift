import AppKit
import Common

struct MoveFloatingToZoneCommand: Command {
    let args: MoveFloatingToZoneCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        guard let parent = window.parent else { return .fail }
        let workspace: Workspace
        switch parent.cases {
            case .workspace(let ws):
                workspace = ws
            case .tilingContainer:
                guard let ws = window.nodeWorkspace else { return .fail }
                workspace = ws
                window.bindAsFloatingWindow(to: workspace)
            default:
                return .fail(io.err("move-floating-to-zone: focused window is not floating or tiling"))
        }
        let zoneName = args.zone.val.rawValue
        guard let toZone = workspace.zoneContainers[zoneName] else {
            return .fail(io.err("move-floating-to-zone: zones not active on this workspace"))
        }
        guard let toZoneRect = toZone.lastAppliedLayoutPhysicalRect else {
            return .fail(io.err("move-floating-to-zone: zone layout not yet computed"))
        }
        guard let windowRect = try await window.getAxRect() else { return .fail }

        // Find the "from zone" by checking which zone contains the window center
        let windowCenter = windowRect.center
        let fromZoneRect: Rect = if let homeZone = workspace.zoneContainers.values.first(where: { $0.lastAppliedLayoutPhysicalRect?.contains(windowCenter) == true }),
                                    let homeRect = homeZone.lastAppliedLayoutPhysicalRect
        {
            homeRect
        } else {
            // Fall back to monitor rect
            workspace.workspaceMonitor.rect
        }

        let offsetX = windowRect.topLeftX - fromZoneRect.topLeftX
        let offsetY = windowRect.topLeftY - fromZoneRect.topLeftY
        let newOrigin = CGPoint(x: toZoneRect.topLeftX + offsetX, y: toZoneRect.topLeftY + offsetY)

        window.setAxFrame(newOrigin, nil)
        ZoneMemory.shared.rememberZone(zoneName, for: window, profile: MonitorProfile([workspace.workspaceMonitor]))
        return .succ
    }
}
