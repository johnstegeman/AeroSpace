import Common

struct MoveNodeToWorkspaceCommand: Command {
    let args: MoveNodeToWorkspaceCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        let subjectWs = window.nodeWorkspace
        let targetWorkspace: Workspace
        switch args.target.val {
            case .relative(let nextPrev):
                guard let subjectWs else { return .fail(io.err("Window \(window.windowId) doesn't belong to any workspace")) }
                let ws = getNextPrevWorkspace(
                    current: subjectWs,
                    isNext: nextPrev == .next,
                    wrapAround: args.wrapAround,
                    stdin: args.useStdin ? io.readStdin() : nil,
                    target: target,
                )
                guard let ws else { return .fail(io.err("Can't resolve next or prev workspace")) }
                targetWorkspace = ws
            case .direct(let name):
                targetWorkspace = Workspace.get(byName: name.raw)
        }
        return moveWindowToWorkspace(window, targetWorkspace, io, focusFollowsWindow: args.focusFollowsWindow, failIfNoop: args.failIfNoop)
    }
}

@MainActor
func moveWindowToWorkspace(_ window: Window, _ targetWorkspace: Workspace, _ io: CmdIo, focusFollowsWindow: Bool, failIfNoop: Bool, index: Int = INDEX_BIND_LAST) -> BinaryExitCode {
    if window.nodeWorkspace == targetWorkspace {
        return switch failIfNoop {
            case true: .fail
            case false:
                .succ(io.err("Window '\(window.windowId)' already belongs to workspace '\(targetWorkspace.name)'. Tip: use --fail-if-noop to exit with non-zero code"))
        }
    }
    targetWorkspace.ensureZoneContainers(for: targetWorkspace.workspaceMonitor)
    let targetContainer: NonLeafTreeNodeObject
    if window.isFloating {
        targetContainer = targetWorkspace
    } else if !targetWorkspace.zoneContainers.isEmpty {
        let profile = MonitorProfile([targetWorkspace.workspaceMonitor])
        if let zoneName = ZoneMemory.shared.rememberedZone(for: window, profile: profile),
           let zone = targetWorkspace.zoneContainers[zoneName]
        {
            targetContainer = zone
        } else {
            // Fall back to the middle zone by definition order (index count/2), which is "center"
            // for the default 3-zone layout. For N-zone layouts this picks the most central zone.
            let defs = targetWorkspace.activeZoneDefinitions
            let middleZone = defs.isEmpty ? nil : targetWorkspace.zoneContainers[defs[defs.count / 2].id]
            targetContainer = middleZone ?? targetWorkspace.rootTilingContainer
        }
    } else {
        targetContainer = targetWorkspace.rootTilingContainer
    }
    window.bind(to: targetContainer, adaptiveWeight: WEIGHT_AUTO, index: index)
    if !targetWorkspace.isScratchpad {
        ScratchpadMemory.shared.forget(windowId: window.windowId)
    }
    return .from(bool: focusFollowsWindow ? window.focusWindow() : true)
}
