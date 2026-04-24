public struct WorkspaceSnapshotCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .workspaceSnapshot,
        allowInConfig: true,
        help: workspace_snapshot_help_generated,
        flags: [:],
        posArgs: [
            newMandatoryPosArgParser(\.action, parseWorkspaceSnapshotAction, placeholder: WorkspaceSnapshotCmdArgs.Action.unionLiteral),
            newMandatoryPosArgParser(\.name, parseWorkspaceSnapshotName, placeholder: "<snapshot-name>"),
        ],
    )

    public var action: Lateinit<Action> = .uninitialized
    public var name: Lateinit<String> = .uninitialized

    public enum Action: String, CaseIterable, Sendable {
        case save, restore
    }
}

func parseWorkspaceSnapshotCmdArgs(_ args: StrArrSlice) -> ParsedCmd<WorkspaceSnapshotCmdArgs> {
    parseSpecificCmdArgs(WorkspaceSnapshotCmdArgs(rawArgs: args), args)
}

private func parseWorkspaceSnapshotAction(i: PosArgParserInput) -> ParsedCliArgs<WorkspaceSnapshotCmdArgs.Action> {
    .init(parseEnum(i.arg, WorkspaceSnapshotCmdArgs.Action.self), advanceBy: 1)
}

private func parseWorkspaceSnapshotName(i: PosArgParserInput) -> ParsedCliArgs<String> {
    let name = i.arg
    let isValid = !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    return isValid
        ? .succ(name, advanceBy: 1)
        : .fail("Snapshot name must match [a-zA-Z0-9_-]+, got '\(name)'", advanceBy: 1)
}
