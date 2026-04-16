public struct MoveNodeToZoneCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .moveNodeToZone,
        allowInConfig: true,
        help: move_node_to_zone_help_generated,
        flags: [
            "--no-focus": ArgParser(\.noFocus, constSubArgParserFun(true)),
        ],
        posArgs: [newMandatoryPosArgParser(\.zone, parseZoneArg, placeholder: MoveNodeToZoneCmdArgs.Zone.unionLiteral)],
    )

    public var noFocus: Bool = false
    public var zone: Lateinit<Zone> = .uninitialized

    public init(rawArgs: [String], _ zone: Zone) {
        self.commonState = .init(rawArgs.slice)
        self.zone = .initialized(zone)
    }

    public enum Zone: String, CaseIterable, Sendable {
        case left, center, right
    }
}

func parseMoveNodeToZoneCmdArgs(_ args: StrArrSlice) -> ParsedCmd<MoveNodeToZoneCmdArgs> {
    parseSpecificCmdArgs(MoveNodeToZoneCmdArgs(rawArgs: args), args)
}

private func parseZoneArg(i: PosArgParserInput) -> ParsedCliArgs<MoveNodeToZoneCmdArgs.Zone> {
    .init(parseEnum(i.arg, MoveNodeToZoneCmdArgs.Zone.self), advanceBy: 1)
}
