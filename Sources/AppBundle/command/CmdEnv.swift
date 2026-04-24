import Common

enum CommandSource: String, Sendable {
    case cli
    case hotkey
    case onWindowDetected = "on-window-detected"
    case onFocusChanged = "on-focus-changed"
    case onFocusedMonitorChanged = "on-focused-monitor-changed"
    case onModeChanged = "on-mode-changed"
    case onMonitorChanged = "on-monitor-changed"
    case afterStartupCommand = "after-startup-command"
    case trayMenu = "tray-menu"
}

struct CmdEnv: ConvenienceCopyable {
    var windowId: UInt32?
    var workspaceName: String?
    var commandSource: CommandSource? = nil

    static let defaultEnv: CmdEnv = .init()
    func withFocus(_ focus: LiveFocus) -> CmdEnv {
        switch focus.asLeaf {
            case .window(let wd): self.copy(\.windowId, wd.windowId).copy(\.workspaceName, nil)
            case .emptyWorkspace(let ws): self.copy(\.workspaceName, ws.name).copy(\.windowId, nil)
        }
    }

    var asMap: [String: String] {
        var result = [String: String]()
        if let windowId {
            result[AEROSPACE_WINDOW_ID] = windowId.description
        }
        if let workspaceName {
            result[AEROSPACE_WORKSPACE] = workspaceName.description
        }
        return result
    }
}
