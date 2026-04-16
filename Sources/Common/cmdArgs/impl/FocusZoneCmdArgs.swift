public struct FocusZoneCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .focusZone,
        allowInConfig: true,
        help: focus_zone_help_generated,
        flags: [
            "--scope": ArgParser(\.scope, upcastArgParserFun(parseFocusZoneScopeArg)),
        ],
        // Zone is optional: omitted when --scope is provided.
        posArgs: [ArgParser(\.zone, upcastArgParserFun(parseFocusZoneEnumArg))],
    )

    public var scope: Scope? = nil
    public var zone: Zone? = nil

    public enum Zone: String, CaseIterable, Sendable {
        case left, center, right
    }

    public enum Scope: String, CaseIterable, Sendable {
        case mru
    }
}

func parseFocusZoneCmdArgs(_ args: StrArrSlice) -> ParsedCmd<FocusZoneCmdArgs> {
    parseSpecificCmdArgs(FocusZoneCmdArgs(rawArgs: args), args)
        .filter("Provide either a zone name or '--scope mru', not both") {
            !($0.zone != nil && $0.scope != nil)
        }
        .filter("Provide either a zone name or '--scope mru'") {
            $0.zone != nil || $0.scope != nil
        }
}

private func parseFocusZoneEnumArg(i: PosArgParserInput) -> ParsedCliArgs<FocusZoneCmdArgs.Zone> {
    .init(parseEnum(i.arg, FocusZoneCmdArgs.Zone.self), advanceBy: 1)
}

private func parseFocusZoneScopeArg(i: SubArgParserInput) -> ParsedCliArgs<FocusZoneCmdArgs.Scope> {
    if let arg = i.nonFlagArgOrNil() {
        return .init(parseEnum(arg, FocusZoneCmdArgs.Scope.self), advanceBy: 1)
    } else {
        return .fail("<scope> is mandatory (possible values: mru)", advanceBy: 0)
    }
}
