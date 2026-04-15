import AppKit
import Common

struct ScratchpadCommand: Command {
    let args: ScratchpadCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let focusedWorkspace = target.workspace

        // If the focused window is a scratchpad window visible on the current workspace, hide it
        if let window = target.windowOrNil,
           window.isFloating,
           ScratchpadMemory.shared.isRemembered(windowId: window.windowId),
           window.nodeWorkspace != Workspace.scratchpad
        {
            if let rect = try await window.getAxRect() {
                window.lastFloatingSize = rect.size
                ScratchpadMemory.shared.rememberPosition(rect.topLeftCorner, for: window.windowId)
            }
            window.bindAsFloatingWindow(to: Workspace.scratchpad)
            return .succ
        }

        // Otherwise show the most-recently-used scratchpad window
        let scratchpadWindows = Workspace.scratchpad.floatingWindows
        guard let window = scratchpadWindows.first(where: { ScratchpadMemory.shared.isRemembered(windowId: $0.windowId) })
            ?? scratchpadWindows.first
        else {
            return .fail(io.err("No windows in scratchpad"))
        }

        window.bindAsFloatingWindow(to: focusedWorkspace)

        // Restore last known position; if none, center on the monitor
        if let position = ScratchpadMemory.shared.rememberedPosition(for: window.windowId) {
            window.setAxFrame(position, window.lastFloatingSize)
        } else {
            let monitor = focusedWorkspace.workspaceMonitor
            if let size = window.lastFloatingSize {
                let x = monitor.visibleRect.minX + (monitor.visibleRect.width - size.width) / 2
                let y = monitor.visibleRect.minY + (monitor.visibleRect.height - size.height) / 2
                window.setAxFrame(CGPoint(x: x, y: y), size)
            }
        }

        _ = window.focusWindow()
        return .succ
    }
}
