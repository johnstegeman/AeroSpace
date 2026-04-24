public struct MoveFloatingToZoneCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .moveFloatingToZone,
        allowInConfig: true,
        help: """
            USAGE: move-floating-to-zone [-h|--help] (left|center|right)
            """,
        flags: [:],
        posArgs: [newMandatoryPosArgParser(\.zone, parseMoveFloatingToZoneArg, placeholder: MoveFloatingToZoneCmdArgs.Zone.unionLiteral)],
    )

    public var zone: Lateinit<Zone> = .uninitialized

    public enum Zone: String, CaseIterable, Sendable {
        case left, center, right
    }
}

func parseMoveFloatingToZoneCmdArgs(_ args: StrArrSlice) -> ParsedCmd<MoveFloatingToZoneCmdArgs> {
    parseSpecificCmdArgs(MoveFloatingToZoneCmdArgs(rawArgs: args), args)
}

private func parseMoveFloatingToZoneArg(i: PosArgParserInput) -> ParsedCliArgs<MoveFloatingToZoneCmdArgs.Zone> {
    .init(parseEnum(i.arg, MoveFloatingToZoneCmdArgs.Zone.self), advanceBy: 1)
}
