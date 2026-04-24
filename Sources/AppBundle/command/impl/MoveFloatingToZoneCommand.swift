import AppKit
import Common

struct MoveFloatingToZoneCommand: Command {
    let args: MoveFloatingToZoneCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

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
        guard let toZoneRect = toZone.lastAppliedLayoutPhysicalRect ?? workspace.theoreticalZoneRect(for: zoneName) else {
            return .fail(io.err("move-floating-to-zone: zone layout not yet computed"))
        }
        guard let windowRect = try await window.getAxRect() else { return .fail }

        let windowCenter = windowRect.center
        let fromZoneRect: Rect = if let homeZone = workspace.zoneContainers.values.first(where: { $0.lastAppliedLayoutPhysicalRect?.contains(windowCenter) == true }),
                                    let homeRect = homeZone.lastAppliedLayoutPhysicalRect
        {
            homeRect
        } else {
            workspace.workspaceMonitor.rect
        }

        let offsetX = windowRect.topLeftX - fromZoneRect.topLeftX
        let offsetY = windowRect.topLeftY - fromZoneRect.topLeftY
        let rawX = toZoneRect.topLeftX + offsetX
        let rawY = toZoneRect.topLeftY + offsetY
        let newX = rawX.coerce(in: toZoneRect.minX ... max(toZoneRect.minX, toZoneRect.maxX - windowRect.width))
        let newY = rawY.coerce(in: toZoneRect.minY ... max(toZoneRect.minY, toZoneRect.maxY - windowRect.height))

        window.setAxFrame(CGPoint(x: newX, y: newY), nil)
        ZoneMemory.shared.rememberZone(zoneName, for: window, profile: MonitorProfile([workspace.workspaceMonitor]))
        return .succ
    }
}
