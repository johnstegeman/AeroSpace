public struct FocusZoneCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .focusZone,
        allowInConfig: true,
        help: focus_zone_help_generated,
        flags: [:],
        posArgs: [newMandatoryPosArgParser(\.zone, parseFocusZoneArg, placeholder: FocusZoneCmdArgs.Zone.unionLiteral)],
    )

    public var zone: Lateinit<Zone> = .uninitialized

    public enum Zone: String, CaseIterable, Sendable {
        case left, center, right
    }
}

func parseFocusZoneCmdArgs(_ args: StrArrSlice) -> ParsedCmd<FocusZoneCmdArgs> {
    parseSpecificCmdArgs(FocusZoneCmdArgs(rawArgs: args), args)
}

private func parseFocusZoneArg(i: PosArgParserInput) -> ParsedCliArgs<FocusZoneCmdArgs.Zone> {
    .init(parseEnum(i.arg, FocusZoneCmdArgs.Zone.self), advanceBy: 1)
}
