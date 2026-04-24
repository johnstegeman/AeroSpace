public struct ZoneCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .zone,
        allowInConfig: false,
        help: zone_help_generated,
        flags: [
            "--json": trueBoolFlag(\.json),
        ],
        posArgs: [],
    )

    public var json: Bool = false
}

func parseZoneCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ZoneCmdArgs> {
    parseSpecificCmdArgs(ZoneCmdArgs(rawArgs: args), args)
        .filter("--json is required") { $0.json }
}
