public struct ListZonesCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .listZones,
        allowInConfig: false,
        help: list_zones_help_generated,
        flags: [
            "--count": trueBoolFlag(\.outputOnlyCount),
            "--json": trueBoolFlag(\.json),
        ],
        posArgs: [],
        conflictingOptions: [
            ["--count", "--json"],
        ],
    )

    public var outputOnlyCount: Bool = false
    public var json: Bool = false
}

func parseListZonesCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ListZonesCmdArgs> {
    parseSpecificCmdArgs(ListZonesCmdArgs(rawArgs: args), args)
}
