import AppKit
import Common

struct ShowWorkspaceMenuCommand: Command {
    let args: ShowWorkspaceMenuCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        // NSMenu.popUp uses AppKit screen coordinates (origin at bottom-left, Y up).
        // AX rects use CG coordinates (origin at top-left of main screen, Y down).
        let mainScreenHeight = NSScreen.main?.frame.height ?? 0
        let popupPoint: CGPoint
        if let window = focus.windowOrNil,
           let rect = try? await window.getAxRect()
        {
            popupPoint = CGPoint(x: rect.center.x, y: mainScreenHeight - rect.center.y)
        } else {
            let r = focus.workspace.workspaceMonitor.visibleRect
            popupPoint = CGPoint(x: r.center.x, y: mainScreenHeight - r.center.y)
        }

        let delegate = WorkspaceMenuTarget()
        let menu = NSMenu()

        for ws in TrayMenuModel.shared.workspaces {
            let item = NSMenuItem(
                title: ws.name + ws.suffix,
                action: #selector(WorkspaceMenuTarget.select(_:)),
                keyEquivalent: ""
            )
            item.target = delegate
            item.representedObject = ws.name
            item.state = ws.isFocused ? .on : .off
            item.attributedTitle = NSAttributedString(
                string: ws.name + ws.suffix,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)]
            )
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: popupPoint, in: nil)

        if let name = delegate.selectedName {
            _ = Workspace.get(byName: name).focusWorkspace()
        }
        return .succ
    }
}

@MainActor
private final class WorkspaceMenuTarget: NSObject {
    var selectedName: String?

    @objc func select(_ sender: NSMenuItem) {
        selectedName = sender.representedObject as? String
    }
}
