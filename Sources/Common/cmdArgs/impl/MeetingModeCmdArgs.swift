public struct MeetingModeCmdArgs: CmdArgs {
    public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .meetingMode,
        allowInConfig: false,
        help: """
            USAGE: meeting-mode on
                   meeting-mode off
                   meeting-mode toggle
            """,
        flags: [:],
        posArgs: [
            newMandatoryPosArgParser(\.action, parseMeetingModeAction, placeholder: Action.unionLiteral),
        ],
    )

    public var action: Lateinit<Action> = .uninitialized

    public enum Action: String, CaseIterable, Sendable {
        case on, off, toggle
    }
}

func parseMeetingModeCmdArgs(_ args: StrArrSlice) -> ParsedCmd<MeetingModeCmdArgs> {
    parseSpecificCmdArgs(MeetingModeCmdArgs(rawArgs: args), args)
}

private func parseMeetingModeAction(i: PosArgParserInput) -> ParsedCliArgs<MeetingModeCmdArgs.Action> {
    .init(parseEnum(i.arg, MeetingModeCmdArgs.Action.self), advanceBy: 1)
}
