public struct ZonePresetCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .zonePreset,
        allowInConfig: true,
        help: zone_preset_help_generated,
        flags: [
            "--reset": ArgParser(\.reset, constSubArgParserFun(true)),
        ],
        posArgs: [ArgParser(\.presetName, upcastArgParserFun(consumePresetNameArg))],
    )

    public var reset: Bool = false
    public var presetName: String? = nil

    public init(rawArgs: [String]) {
        self.commonState = .init(rawArgs.slice)
    }
}

func parseZonePresetCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ZonePresetCmdArgs> {
    parseSpecificCmdArgs(ZonePresetCmdArgs(rawArgs: args), args)
        .filter("Provide either a preset name or '--reset', not both") {
            !($0.presetName != nil && $0.reset)
        }
        .filter("Provide either a preset name or '--reset'") {
            $0.presetName != nil || $0.reset
        }
}

private func consumePresetNameArg(i: PosArgParserInput) -> ParsedCliArgs<String> {
    .succ(i.arg, advanceBy: 1)
}
