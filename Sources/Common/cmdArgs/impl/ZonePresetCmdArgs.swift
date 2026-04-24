public struct ZonePresetCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .zonePreset,
        allowInConfig: true,
        help: zone_preset_help_generated,
        flags: [
            "--reset": ArgParser(\.reset, constSubArgParserFun(true)),
            "--save": ArgParser(\.saveName, upcastArgParserFun(parseSaveNameArg)),
            "--export": ArgParser(\.export, constSubArgParserFun(true)),
        ],
        posArgs: [ArgParser(\.presetName, upcastArgParserFun(consumePresetNameArg))],
    )

    public var reset: Bool = false
    public var presetName: String? = nil
    public var saveName: String? = nil
    public var export: Bool = false
}

func parseZonePresetCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ZonePresetCmdArgs> {
    parseSpecificCmdArgs(ZonePresetCmdArgs(rawArgs: args), args)
        .filter("Provide exactly one of: <preset-name>, --reset, --save <name>, or --export") {
            let actionCount =
                ($0.presetName != nil ? 1 : 0) +
                ($0.reset ? 1 : 0) +
                ($0.saveName != nil ? 1 : 0) +
                ($0.export ? 1 : 0)
            return actionCount == 1
        }
}

private func consumePresetNameArg(i: PosArgParserInput) -> ParsedCliArgs<String> {
    .succ(i.arg, advanceBy: 1)
}

private func parseSaveNameArg(i: SubArgParserInput) -> ParsedCliArgs<String> {
    if let arg = i.nonFlagArgOrNil() {
        return .succ(arg, advanceBy: 1)
    } else {
        return .fail("--save requires a preset name", advanceBy: 0)
    }
}
