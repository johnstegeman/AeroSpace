import AppKit
import Common
import HotKey
import TOMLDecoder
import OrderedCollections

@MainActor
func readConfig(forceConfigUrl: URL? = nil) -> Result<(Config, URL), String> {
    let configUrl: URL
    if let forceConfigUrl {
        configUrl = forceConfigUrl
    } else {
        switch findCustomConfigUrl() {
            case .file(let url): configUrl = url
            case .noCustomConfigExists: configUrl = defaultConfigUrl
            case .ambiguousConfigError(let candidates):
                let msg = """
                    Ambiguous config error. Several configs found:
                    \(candidates.map(\.path).joined(separator: "\n"))
                    """
                return .failure(msg)
        }
    }
    let (parsedConfig, errors) = (try? String(contentsOf: configUrl, encoding: .utf8)).map { parseConfig($0) } ?? (defaultConfig, [])

    if errors.isEmpty {
        return .success((parsedConfig, configUrl))
    } else {
        let msg = """
            Failed to parse \(configUrl.absoluteURL.path)

            \(errors.map(\.description).joined(separator: "\n\n"))
            """
        return .failure(msg)
    }
}

enum ConfigParseError: Error, CustomStringConvertible, Equatable {
    case semantic(_ backtrace: ConfigBacktrace, _ message: String)
    case syntax(_ message: String)

    var description: String {
        return switch self {
            // todo Make 'split' + flatten normalization prettier
            case .semantic(let backtrace, let message) where backtrace.description.isEmpty: message
            case .semantic(let backtrace, let message): "\(backtrace): \(message)"
            case .syntax(let message): message
        }
    }
}

typealias ParsedConfig<T> = Result<T, ConfigParseError>

extension ParserProtocol {
    func transformRawConfig(_ raw: S,
                            _ value: Json,
                            _ backtrace: ConfigBacktrace,
                            _ errors: inout [ConfigParseError]) -> S
    {
        if let value = parse(value, backtrace, &errors).getOrNil(appendErrorTo: &errors) {
            return raw.copy(keyPath, value)
        }
        return raw
    }
}

protocol ParserProtocol<S>: Sendable {
    associatedtype T
    associatedtype S where S: ConvenienceCopyable
    var keyPath: SendableWritableKeyPath<S, T> { get }
    var parse: @Sendable (Json, ConfigBacktrace, inout [ConfigParseError]) -> ParsedConfig<T> { get }
}

struct Parser<S: ConvenienceCopyable, T>: ParserProtocol {
    let keyPath: SendableWritableKeyPath<S, T>
    let parse: @Sendable (Json, ConfigBacktrace, inout [ConfigParseError]) -> ParsedConfig<T>

    init(_ keyPath: SendableWritableKeyPath<S, T>, _ parse: @escaping @Sendable (Json, ConfigBacktrace, inout [ConfigParseError]) -> T) {
        self.keyPath = keyPath
        self.parse = { raw, backtrace, errors -> ParsedConfig<T> in .success(parse(raw, backtrace, &errors)) }
    }

    init(_ keyPath: SendableWritableKeyPath<S, T>, _ parse: @escaping @Sendable (Json, ConfigBacktrace) -> ParsedConfig<T>) {
        self.keyPath = keyPath
        self.parse = { raw, backtrace, _ -> ParsedConfig<T> in parse(raw, backtrace) }
    }
}

private let keyMappingConfigRootKey = "key-mapping"
private let modeConfigRootKey = "mode"
private let persistentWorkspacesKey = "persistent-workspaces"

// For every new config option you add, think:
// 1. Does it make sense to have different value
// 2. Prefer commands and commands flags over toml options if possible
private let configParser: [String: any ParserProtocol<Config>] = [
    "config-version": Parser(\.configVersion, parseConfigVersion),

    "after-login-command": Parser(\.afterLoginCommand, parseAfterLoginCommand),
    "after-startup-command": Parser(\.afterStartupCommand) { parseCommandOrCommands($0).toParsedConfig($1) },

    "on-focus-changed": Parser(\.onFocusChanged) { parseCommandOrCommands($0).toParsedConfig($1) },
    "on-mode-changed": Parser(\.onModeChanged) { parseCommandOrCommands($0).toParsedConfig($1) },
    "on-focused-monitor-changed": Parser(\.onFocusedMonitorChanged) { parseCommandOrCommands($0).toParsedConfig($1) },
    // "on-focused-workspace-changed": Parser(\.onFocusedWorkspaceChanged, { parseCommandOrCommands($0).toParsedConfig($1) }),

    "enable-normalization-flatten-containers": Parser(\.enableNormalizationFlattenContainers, parseBool),
    "enable-normalization-opposite-orientation-for-nested-containers": Parser(\.enableNormalizationOppositeOrientationForNestedContainers, parseBool),

    "default-root-container-layout": Parser(\.defaultRootContainerLayout, parseLayout),
    "default-root-container-orientation": Parser(\.defaultRootContainerOrientation, parseDefaultContainerOrientation),

    "start-at-login": Parser(\.startAtLogin, parseBool),
    "auto-reload-config": Parser(\.autoReloadConfig, parseBool),
    "automatically-unhide-macos-hidden-apps": Parser(\.automaticallyUnhideMacosHiddenApps, parseBool),
    "accordion": Parser(\.accordion, parseAccordionConfig),
    "accordion-indicator": Parser(\.accordionIndicator, parseAccordionIndicator),
    "stack-indicator": Parser(\.stackIndicator, parseStackIndicator),
    persistentWorkspacesKey: Parser(\.persistentWorkspaces, parsePersistentWorkspaces),
    "exec-on-workspace-change": Parser(\.execOnWorkspaceChange, parseArrayOfStrings),
    "exec": Parser(\.execConfig, parseExecConfig),

    keyMappingConfigRootKey: Parser(\.keyMapping, skipParsing(Config().keyMapping)), // Parsed manually
    modeConfigRootKey: Parser(\.modes, skipParsing(Config().modes)), // Parsed manually

    "gaps": Parser(\.gaps, parseGaps),
    "zones": Parser(\.zones, parseZonesConfig),
    "zone-presets": Parser(\.zonePresets, parseZonePresetsArray),
    "monitor-profiles": Parser(\.monitorProfiles, parseMonitorProfilesArray),
    "on-monitor-changed": Parser(\.onMonitorChanged, parseOnMonitorChangedArray),
    "hud": Parser(\.hud, parseHUDConfig),
    "borders": Parser(\.borders, parseBorderConfig),
    "floating": Parser(\.floating, parseFloatingConfig),
    "workspace-to-monitor-force-assignment": Parser(\.workspaceToMonitorForceAssignment, parseWorkspaceToMonitorAssignment),
    "on-window-detected": Parser(\.onWindowDetected, parseOnWindowDetectedArray),

    // Deprecated
    "non-empty-workspaces-root-containers-layout-on-startup": Parser(\._nonEmptyWorkspacesRootContainersLayoutOnStartup, parseStartupRootContainerLayout),
    "indent-for-nested-containers-with-the-same-orientation": Parser(\._indentForNestedContainersWithTheSameOrientation, parseIndentForNestedContainersWithTheSameOrientation),
]

extension ParsedCmd where T == any Command {
    fileprivate func toEither() -> Parsed<T> {
        return switch self {
            case .cmd(let a):
                a.info.allowInConfig
                    ? .success(a)
                    : .failure("Command '\(a.info.kind.rawValue)' cannot be used in config")
            case .help(let a): .failure(a)
            case .failure(let a): .failure(a.msg)
        }
    }
}

extension Command {
    fileprivate var isMacOsNativeCommand: Bool { // Problem ID-B6E178F2
        self is MacosNativeMinimizeCommand || self is MacosNativeFullscreenCommand
    }
}

func parseAfterLoginCommand(_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<[any Command]> {
    if let array = raw.asArrayOrNil, array.count == 0 {
        return .success([])
    }
    let msg = "after-login-command is deprecated since AeroSpace 0.19.0. https://github.com/nikitabobko/AeroSpace/issues/1482"
    return .failure(.semantic(backtrace, msg))
}

func parseCommandOrCommands(_ raw: Json) -> Parsed<[any Command]> {
    if let rawString = raw.asStringOrNil {
        return parseCommand(rawString).toEither().map { [$0] }
    } else if let rawArray = raw.asArrayOrNil {
        let commands: Parsed<[any Command]> = (0 ..< rawArray.count).mapAllOrFailure { index in
            let rawString: String = rawArray[index].asStringOrNil ?? expectedActualTypeError(expected: .string, actual: rawArray[index].tomlType)
            return parseCommand(rawString).toEither()
        }
        return commands.filter("macos-native-* commands are only allowed to be the last commands in the list") {
            !$0.dropLast().contains(where: { $0.isMacOsNativeCommand })
        }
    } else {
        return .failure(expectedActualTypeError(expected: [.string, .array], actual: raw.tomlType))
    }
}

func tomlAnyToParsedConfigRecursive(any: Any, _ backtrace: ConfigBacktrace) -> ParsedConfig<Json> {
    switch any {
        case let dict as [String: Any]:
            var json = Json.JsonDict()
            for (key, tomlValue) in dict {
                let jsonResultValue = tomlAnyToParsedConfigRecursive(any: tomlValue, backtrace + .key(key))
                switch jsonResultValue {
                    case .success(let jsonValue): json[key] = jsonValue
                    case .failure(let fail): return .failure(fail)
                }
            }
            return .success(.dict(json))
        case let array as [Any]:
            var json = Json.JsonArray()
            for (index, tomlValue) in array.enumerated() {
                let jsonResultValue = tomlAnyToParsedConfigRecursive(any: tomlValue, backtrace + .index(index))
                switch jsonResultValue {
                    case .success(let jsonValue): json.append(jsonValue)
                    case .failure(let fail): return .failure(fail)
                }
            }
            return .success(.array(json))
        default:
            return Json.newScalarOrNil(any).orFailure(.semantic(backtrace, "Unsupported TOML type: \(type(of: any))"))
    }
}

@MainActor func parseConfig(_ rawToml: String) -> (config: Config, errors: [String]) { // todo change return value to Result
    let result = _parseConfig(rawToml)
    return (result.config, result.errors.map(\.description).sorted())
}

@MainActor private func _parseConfig(_ rawToml: String) -> (config: Config, errors: [ConfigParseError]) { // todo change return value to Result
    let rawTable: Json.JsonDict
    do {
        let dict: [String: Any] = try .init(try TOMLTable(source: rawToml))
        switch tomlAnyToParsedConfigRecursive(any: dict, .emptyRoot) {
            case .success(.dict(let dict)): rawTable = dict
            case .success: return (defaultConfig, [.syntax("Config parsing error: the top level type must be a TOML Table")])
            case .failure(let fail): return (defaultConfig, [fail])
        }
    } catch {
        return (defaultConfig, [.syntax(error.description)])
    }

    var errors: [ConfigParseError] = []

    var config = rawTable.parseTable(Config(), configParser, .emptyRoot, &errors)

    if let mapping = rawTable[keyMappingConfigRootKey].flatMap({ parseKeyMapping($0, .rootKey(keyMappingConfigRootKey), &errors) }) {
        config.keyMapping = mapping
    }

    // Parse modeConfigRootKey after keyMappingConfigRootKey
    if let modes = rawTable[modeConfigRootKey].flatMap({ parseModes($0, .rootKey(modeConfigRootKey), &errors, config.keyMapping.resolve()) }) {
        config.modes = modes
    }

    if config.configVersion <= 1 {
        if rawTable.keys.contains(persistentWorkspacesKey) {
            errors += [.semantic(.rootKey(persistentWorkspacesKey), "This config option is only available since 'config-version = 2'")]
        }
        config.persistentWorkspaces = (config.modes.values.lazy
            .flatMap { (mode: Mode) -> [HotkeyBinding] in Array(mode.bindings.values) }
            .flatMap { (binding: HotkeyBinding) -> [String] in
                binding.commands.filterIsInstance(of: WorkspaceCommand.self).compactMap { $0.args.target.val.workspaceNameOrNil()?.raw } +
                    binding.commands.filterIsInstance(of: MoveNodeToWorkspaceCommand.self).compactMap { $0.args.target.val.workspaceNameOrNil()?.raw }
            }
            + (config.workspaceToMonitorForceAssignment).keys)
            .toOrderedSet()
    }

    if config.enableNormalizationFlattenContainers {
        let containsSplitCommand = config.modes.values.lazy.flatMap { $0.bindings.values }
            .flatMap { $0.commands }
            .contains { $0 is SplitCommand }
        if containsSplitCommand {
            errors += [.semantic(
                .emptyRoot, // todo Make 'split' + flatten normalization prettier
                """
                The config contains:
                1. usage of 'split' command
                2. enable-normalization-flatten-containers = true
                These two settings don't play nicely together. 'split' command has no effect when enable-normalization-flatten-containers is disabled.

                My recommendation: keep the normalizations enabled, and prefer 'join-with' over 'split'.
                """,
            )]
        }
    }
    config.onWindowDetected = synthesizeFloatingDefaults(config.floating) + config.onWindowDetected
    return (config, errors)
}

func parseIndentForNestedContainersWithTheSameOrientation(_ _: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<Void> {
    let msg = "Deprecated. Please drop it from the config. See https://github.com/nikitabobko/AeroSpace/issues/96"
    return .failure(.semantic(backtrace, msg))
}

func parseConfigVersion(_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<Int> {
    let min = 1
    let max = 2
    return parseInt(raw, backtrace)
        .filter(.semantic(backtrace, "Must be in [\(min), \(max)] range")) { (min ... max).contains($0) }
}

private let hudConfigParser: [String: any ParserProtocol<HUDConfig>] = [
    "active-on": Parser(\.activeOn, parseHUDActiveOn),
]

private let floatingConfigParser: [String: any ParserProtocol<FloatingConfig>] = [
    "app-ids": Parser(\.appIds, parseArrayOfStrings),
]

func parseFloatingConfig(_ raw: Json, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseError]) -> FloatingConfig {
    parseTable(raw, FloatingConfig(), floatingConfigParser, backtrace, &errors)
}

private func synthesizeFloatingDefaults(_ floating: FloatingConfig) -> [WindowDetectedCallback] {
    floating.appIds.map { appId in
        WindowDetectedCallback(
            matcher: WindowDetectedCallbackMatcher(
                appId: appId,
                appNameRegexSubstring: nil,
                windowTitleRegexSubstring: nil
            ),
            checkFurtherCallbacks: true,
            rawRun: [LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [.floating]))],
        )
    }
}

func parseHUDConfig(_ raw: Json, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseError]) -> HUDConfig {
    parseTable(raw, HUDConfig(), hudConfigParser, backtrace, &errors)
}

private func parseHUDActiveOn(_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<HUDActiveOn> {
    parseString(raw, backtrace).flatMap {
        HUDActiveOn(rawValue: $0)
            .orFailure(.semantic(backtrace, "Can't parse hud.active-on '\($0)'. Expected 'ultrawide', 'always', or 'never'"))
    }
}

private let borderConfigParser: [String: any ParserProtocol<BorderConfig>] = [
    "enabled": Parser(\.enabled, parseBool),
    "width": Parser(\.width, parseDouble),
    "corner-radius": Parser(\.cornerRadius, parseDouble),
    "active-color": Parser(\.activeColor, parseAeroColor),
    "inactive-color": Parser(\.inactiveColor, parseAeroColor),
    "ignore-app-ids": Parser(\.ignoredApps, parseArrayOfStrings),
]

func parseBorderConfig(_ raw: Json, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseError]) -> BorderConfig {
    parseTable(raw, BorderConfig(), borderConfigParser, backtrace, &errors)
}

private func parseAeroColor(_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<AeroColor> {
    raw.asIntOrNil
        .map { AeroColor(argb: $0) }
        .orFailure(expectedActualTypeError(expected: .int, actual: raw.tomlType, backtrace))
}

private let accordionConfigParser: [String: any ParserProtocol<AccordionConfig>] = [
    "mode": Parser(\.mode, parseAccordionMode),
    "padding": Parser(\.padding, parseInt),
    "offset-x": Parser(\.offsetX, parseInt),
    "offset-y": Parser(\.offsetY, parseInt),
]

func parseAccordionConfig(_ raw: Json, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseError]) -> AccordionConfig {
    parseTable(raw, AccordionConfig(), accordionConfigParser, backtrace, &errors)
}

private func parseAccordionMode(_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<AccordionMode> {
    parseString(raw, backtrace).flatMap {
        AccordionMode(rawValue: $0)
            .orFailure(.semantic(backtrace, "Can't parse accordion.mode '\($0)'. Expected 'overlap' or 'cascade'"))
    }
}

// Non-zone fields parsed by the standard table parser.
// "zone", "widths", "layouts" are intentionally skipped here — parseZonesConfig handles them
// manually after parseTable runs, so they must be listed to suppress "Unknown key" errors.
private let zonesConfigNonZoneParser: [String: any ParserProtocol<ZonesConfig>] = [
    "gap": Parser(\.gap, parseInt),
    "focus-mode-collapsed-width": Parser(\.focusModeCollapsedWidth, parseInt),
    "behavior": Parser(\.behavior, parseZoneBehaviorOverrides),
    "overrides": Parser(\.overrides, parseZoneGapOverrides),
    "zone":    Parser(\.zones, skipParsing([ZoneDefinition]())),  // handled manually below
    "widths":  Parser(\.zones, skipParsing([ZoneDefinition]())),  // legacy; handled manually below
    "layouts": Parser(\.zones, skipParsing([ZoneDefinition]())),  // legacy; handled manually below
]

func parseZonesConfig(_ raw: Json, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseError]) -> ZonesConfig {
    var result = parseTable(raw, ZonesConfig(), zonesConfigNonZoneParser, backtrace, &errors)
    let dict = raw.asDictOrNil ?? [:]

    if let rawZone = dict["zone"] {
        // New format: [[zones.zone]] array of zone definitions.
        if let zones = parseZoneDefinitions(rawZone, backtrace + .key("zone"), &errors) {
            result.zones = zones
        }
    } else if dict["widths"] != nil || dict["layouts"] != nil {
        // Legacy format: zones.widths and zones.layouts arrays. Deprecated; use [[zones.zone]].
        if let zones = parseLegacyZoneArrays(dict, backtrace, &errors) {
            result.zones = zones
        }
    }
    return result
}

private func parseZoneDefinitions(_ raw: Json, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseError]) -> [ZoneDefinition]? {
    guard let arr = raw.asArrayOrNil else {
        errors.append(expectedActualTypeError(expected: .array, actual: raw.tomlType, backtrace))
        return nil
    }
    guard !arr.isEmpty else {
        errors.append(.semantic(backtrace, "zones.zone must have at least 1 entry"))
        return nil
    }
    var defs: [ZoneDefinition] = []
    for (index, elem) in arr.enumerated() {
        let bt = backtrace + .index(index)
        guard let dict = elem.asDictOrNil else {
            errors.append(expectedActualTypeError(expected: .table, actual: elem.tomlType, bt))
            return nil
        }
        guard let rawId = dict["id"], let id = rawId.asStringOrNil, !id.isEmpty else {
            errors.append(.semantic(bt, "zone entry must have a non-empty 'id' string"))
            return nil
        }
        guard let rawWidth = dict["width"] else {
            errors.append(.semantic(bt, "zone entry '\(id)' must have a 'width' field"))
            return nil
        }
        guard case .success(let width) = parseDouble(rawWidth, bt + .key("width")), width > 0 else {
            errors.append(.semantic(bt + .key("width"), "zone '\(id)' width must be a positive number"))
            return nil
        }
        let layout: Layout
        if let rawLayout = dict["layout"] {
            switch parseLayout(rawLayout, bt + .key("layout")) {
                case .success(let l): layout = l
                case .failure(let e): errors.append(e); return nil
            }
        } else {
            layout = .tiles
        }
        defs.append(ZoneDefinition(id: id, width: width, layout: layout))
    }
    // Validate widths sum to 1.0.
    let total = defs.reduce(0.0) { $0 + $1.width }
    guard abs(total - 1.0) < 0.01 else {
        errors.append(.semantic(backtrace, "zone widths must sum to 1.0 (got \(total))"))
        return nil
    }
    // Validate unique IDs.
    let ids = defs.map(\.id)
    if Set(ids).count != ids.count {
        errors.append(.semantic(backtrace, "zone IDs must be unique"))
        return nil
    }
    return defs
}

/// Parse legacy `widths = [...]` + `layouts = [...]` arrays and synthesize ZoneDefinitions.
/// IDs default to ["left", "center", "right"] for 3 zones, or "zone1"..."zoneN" otherwise.
private func parseLegacyZoneArrays(
    _ dict: [String: Json],
    _ backtrace: ConfigBacktrace,
    _ errors: inout [ConfigParseError]
) -> [ZoneDefinition]? {
    let widths: [Double]
    if let rawWidths = dict["widths"] {
        switch parseZoneWidths(rawWidths, backtrace + .key("widths")) {
            case .success(let w): widths = w
            case .failure(let e): errors.append(e); return nil
        }
    } else {
        widths = [1.0/3, 1.0/3, 1.0/3]
    }
    let layouts: [Layout]
    if let rawLayouts = dict["layouts"] {
        switch parseZoneLayouts(rawLayouts, backtrace + .key("layouts"), widths.count) {
            case .success(let l): layouts = l
            case .failure(let e): errors.append(e); return nil
        }
    } else {
        layouts = Array(repeating: .tiles, count: widths.count)
    }
    let defaultIds = widths.count == 3 ? ["left", "center", "right"] : (1...widths.count).map { "zone\($0)" }
    return zip(zip(defaultIds, widths), layouts).map { ZoneDefinition(id: $0.0, width: $0.1, layout: $1) }
}

private func parseZoneGapOverrides(_ raw: Json, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseError]) -> [String: ZoneGapOverride] {
    guard let rawTable = raw.asDictOrNil else {
        errors.append(expectedActualTypeError(expected: .table, actual: raw.tomlType, backtrace))
        return [:]
    }
    var result: [String: ZoneGapOverride] = [:]
    for (zoneName, rawOverride) in rawTable {
        let bt = backtrace + .key(zoneName)
        result[zoneName] = parseTable(rawOverride, ZoneGapOverride(), zoneGapOverrideParser, bt, &errors)
    }
    return result
}

private func parseZoneBehaviorOverrides(_ raw: Json, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseError]) -> [String: ZoneBehavior] {
    guard let rawTable = raw.asDictOrNil else {
        errors.append(expectedActualTypeError(expected: .table, actual: raw.tomlType, backtrace))
        return [:]
    }
    var result: [String: ZoneBehavior] = [:]
    for (zoneName, rawBehavior) in rawTable {
        let bt = backtrace + .key(zoneName)
        result[zoneName] = parseTable(rawBehavior, ZoneBehavior(), zoneBehaviorParser, bt, &errors)
    }
    return result
}

/// Keys under [zones.overrides.<name>]: top/bottom/left/right are outer-gap pixel overrides.
private let zoneGapOverrideParser: [String: any ParserProtocol<ZoneGapOverride>] = [
    "top": Parser(\.top, parseOptionalInt),
    "bottom": Parser(\.bottom, parseOptionalInt),
    "left": Parser(\.left, parseOptionalInt),
    "right": Parser(\.right, parseOptionalInt),
]

private let zoneBehaviorParser: [String: any ParserProtocol<ZoneBehavior>] = [
    "new-window": Parser(\.newWindow, parseZoneNewWindowPolicy),
]

private func parseZoneNewWindowPolicy(_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<ZoneNewWindowPolicy> {
    parseString(raw, backtrace).flatMap {
        ZoneNewWindowPolicy(rawValue: $0)
            .orFailure(.semantic(backtrace, "Can't parse zones.behavior.new-window '\($0)'. Expected 'append', 'after-focused', or 'append-hidden'"))
    }
}

private func parseOptionalInt(_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<Int?> {
    parseInt(raw, backtrace).map(Optional.init)
}

private func parseZoneWidths(_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<[Double]> {
    parseTomlArray(raw, backtrace)
        .flatMap { arr -> ParsedConfig<[Double]> in
            guard !arr.isEmpty else {
                return .failure(.semantic(backtrace, "zones.widths must not be empty"))
            }
            return arr.enumerated().mapAllOrFailure { (index, elem) in
                parseDouble(elem, backtrace + .index(index))
            }
        }
        .flatMap { widths in
            guard abs(widths.reduce(0, +) - 1.0) < 0.01, widths.allSatisfy({ $0 > 0 }) else {
                return .failure(.semantic(backtrace, "zones.widths must be positive values summing to 1.0"))
            }
            return .success(widths)
        }
}

private func parseZoneLayouts(_ raw: Json, _ backtrace: ConfigBacktrace, _ expectedCount: Int) -> ParsedConfig<[Layout]> {
    parseTomlArray(raw, backtrace)
        .flatMap { arr -> ParsedConfig<[Layout]> in
            guard arr.count == expectedCount else {
                return .failure(.semantic(backtrace, "zones.layouts must have \(expectedCount) elements to match zones.widths, got \(arr.count)"))
            }
            return arr.enumerated().mapAllOrFailure { (index, elem) in
                parseLayout(elem, backtrace + .index(index))
            }
        }
}

private func parseMonitorProfilesArray(_ raw: Json, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseError]) -> [MonitorProfileRule] {
    guard let arr = raw.asArrayOrNil else {
        errors.append(expectedActualTypeError(expected: .array, actual: raw.tomlType, backtrace))
        return []
    }
    return arr.enumerated().compactMap { (index, elem) in
        parseMonitorProfileRule(elem, backtrace + .index(index), &errors)
    }
}

private func parseMonitorProfileRule(_ raw: Json, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseError]) -> MonitorProfileRule? {
    guard let dict = raw.asDictOrNil else {
        errors.append(expectedActualTypeError(expected: .table, actual: raw.tomlType, backtrace))
        return nil
    }
    var myErrors: [ConfigParseError] = []
    var rule = MonitorProfileRule()

    if let nameJson = dict["name"] {
        if let name = nameJson.asStringOrNil, !name.isEmpty {
            rule.name = name
        } else {
            myErrors.append(expectedActualTypeError(expected: .string, actual: nameJson.tomlType, backtrace + .key("name")))
        }
    } else {
        myErrors.append(.semantic(backtrace, "'name' is required in [[monitor-profiles]]"))
    }

    if let matchJson = dict["match"] {
        if let matchDict = matchJson.asDictOrNil {
            let matchBt = backtrace + .key("match")
            if let ratioJson = matchDict["min-aspect-ratio"] {
                if let ratio = ratioJson.asDoubleOrNil, ratio > 0 {
                    rule.matcher.minAspectRatio = ratio
                } else {
                    myErrors.append(expectedActualTypeError(expected: .float, actual: ratioJson.tomlType, matchBt + .key("min-aspect-ratio")))
                }
            }
            if let countJson = matchDict["monitor-count"] {
                if let count = countJson.asIntOrNil, count > 0 {
                    rule.matcher.monitorCount = count
                } else {
                    myErrors.append(expectedActualTypeError(expected: .int, actual: countJson.tomlType, matchBt + .key("monitor-count")))
                }
            }
        } else {
            myErrors.append(expectedActualTypeError(expected: .table, actual: matchJson.tomlType, backtrace + .key("match")))
        }
    }

    if let layoutJson = dict["apply-zone-layout"] {
        if let layout = layoutJson.asStringOrNil, !layout.isEmpty {
            rule.applyZoneLayout = layout
        } else {
            myErrors.append(expectedActualTypeError(expected: .string, actual: layoutJson.tomlType, backtrace + .key("apply-zone-layout")))
        }
    }

    if let snapshotJson = dict["restore-workspace-snapshot"] {
        if let snapshot = snapshotJson.asStringOrNil, !snapshot.isEmpty {
            rule.restoreWorkspaceSnapshot = snapshot
        } else {
            myErrors.append(expectedActualTypeError(expected: .string, actual: snapshotJson.tomlType, backtrace + .key("restore-workspace-snapshot")))
        }
    }

    if !myErrors.isEmpty {
        errors += myErrors
        return nil
    }
    return rule
}

private func parseOnMonitorChangedArray(_ raw: Json, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseError]) -> [MonitorChangedCallback] {
    guard let arr = raw.asArrayOrNil else {
        errors.append(expectedActualTypeError(expected: .array, actual: raw.tomlType, backtrace))
        return []
    }
    return arr.enumerated().compactMap { (index, elem) in
        parseOnMonitorChangedCallback(elem, backtrace + .index(index), &errors)
    }
}

private func parseOnMonitorChangedCallback(_ raw: Json, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseError]) -> MonitorChangedCallback? {
    guard let dict = raw.asDictOrNil else {
        errors.append(expectedActualTypeError(expected: .table, actual: raw.tomlType, backtrace))
        return nil
    }
    var myErrors: [ConfigParseError] = []
    var callback = MonitorChangedCallback()

    // Parse mandatory 'run' field
    if let runJson = dict["run"] {
        switch parseCommandOrCommands(runJson).toParsedConfig(backtrace + .key("run")) {
            case .success(let cmds): callback.rawRun = cmds
            case .failure(let e): myErrors.append(e)
        }
    } else {
        myErrors.append(.semantic(backtrace, "'run' is mandatory in [[on-monitor-changed]]"))
    }

    // Parse optional 'if' matcher
    if let ifJson = dict["if"], let ifDict = ifJson.asDictOrNil {
        let ifBt = backtrace + .key("if")
        if let ratioJson = ifDict["any-monitor-min-aspect-ratio"] {
            if let ratio = ratioJson.asDoubleOrNil {
                callback.matcher.anyMonitorMinAspectRatio = ratio
            } else {
                myErrors.append(expectedActualTypeError(expected: .float, actual: ratioJson.tomlType, ifBt + .key("any-monitor-min-aspect-ratio")))
            }
        }
    }

    if !myErrors.isEmpty {
        errors += myErrors
        return nil
    }
    return callback
}

private func parseZonePresetsArray(_ raw: Json, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseError]) -> [String: ZonePreset] {
    guard let arr = raw.asArrayOrNil else {
        errors.append(expectedActualTypeError(expected: .array, actual: raw.tomlType, backtrace))
        return [:]
    }
    var result: [String: ZonePreset] = [:]
    for (index, elem) in arr.enumerated() {
        let bt = backtrace + .index(index)
        guard let dict = elem.asDictOrNil else {
            errors.append(expectedActualTypeError(expected: .table, actual: elem.tomlType, bt))
            continue
        }
        guard let nameJson = dict["name"], let name = nameJson.asStringOrNil else {
            errors.append(.semantic(bt, "zone-preset must have a 'name' string field"))
            continue
        }
        var preset = ZonePreset(name: name, zones: [])
        if let rawZone = dict["zone"] {
            if let zones = parseZoneDefinitions(rawZone, bt + .key("zone"), &errors) {
                preset.zones = zones
            }
        } else if dict["widths"] != nil || dict["layouts"] != nil {
            // Legacy format: widths/layouts arrays in a preset.
            if let zones = parseLegacyZoneArrays(dict, bt, &errors) {
                preset.zones = zones
            }
        } else {
            errors.append(.semantic(bt, "zone-preset '\(name)' must have at least one [[zone-presets.zone]] entry"))
            continue
        }
        if !preset.zones.isEmpty {
            result[name] = preset
        }
    }
    return result
}

func parseDouble(_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<Double> {
    raw.asDoubleOrNil.orFailure(expectedActualTypeError(expected: .float, actual: raw.tomlType, backtrace))
}

func parseInt(_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<Int> {
    raw.asIntOrNil.orFailure(expectedActualTypeError(expected: .int, actual: raw.tomlType, backtrace))
}

func parseString(_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<String> {
    raw.asStringOrNil.orFailure(expectedActualTypeError(expected: .string, actual: raw.tomlType, backtrace))
}

func parseSimpleType<T>(_ raw: Json, ofType: T.Type) -> T? {
    (raw.asIntOrNil as? T) ?? (raw.asStringOrNil as? T) ?? (raw.asBoolOrNil as? T)
}

extension Json {
    func unwrapTableWithSingleKey(expectedKey: String? = nil, _ backtrace: inout ConfigBacktrace) -> ParsedConfig<(key: String, value: Json)> {
        guard let asDictOrNil else {
            return .failure(expectedActualTypeError(expected: .table, actual: tomlType, backtrace))
        }
        let singleKeyError: ConfigParseError = .semantic(
            backtrace,
            expectedKey != nil
                ? "The table is expected to have a single key '\(expectedKey.orDie())'"
                : "The table is expected to have a single key",
        )
        guard let (actualKey, value): (String, Json) = asDictOrNil.count == 1 ? asDictOrNil.first : nil else {
            return .failure(singleKeyError)
        }
        if expectedKey != nil && expectedKey != actualKey {
            return .failure(singleKeyError)
        }
        backtrace = backtrace + .key(actualKey)
        return .success((actualKey, value))
    }
}

func parseTomlArray(_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<Json.JsonArray> {
    raw.asArrayOrNil.orFailure(expectedActualTypeError(expected: .array, actual: raw.tomlType, backtrace))
}

func parseTable<T: ConvenienceCopyable>(
    _ raw: Json,
    _ initial: T,
    _ fieldsParser: [String: any ParserProtocol<T>],
    _ backtrace: ConfigBacktrace,
    _ errors: inout [ConfigParseError],
) -> T {
    guard let table = raw.asDictOrNil else {
        errors.append(expectedActualTypeError(expected: .table, actual: raw.tomlType, backtrace))
        return initial
    }
    return table.parseTable(initial, fieldsParser, backtrace, &errors)
}

private func parseStartupRootContainerLayout(_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<Void> {
    parseString(raw, backtrace)
        .filter(.semantic(backtrace, "'non-empty-workspaces-root-containers-layout-on-startup' is deprecated. Please drop it from your config")) { raw in raw == "smart" }
        .map { _ in () }
}

private func parseLayout(_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<Layout> {
    parseString(raw, backtrace)
        .flatMap { $0.parseLayout().orFailure(.semantic(backtrace, "Can't parse layout '\($0)'")) }
}

private func skipParsing<T: Sendable>(_ value: T) -> @Sendable (_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<T> {
    { _, _ in .success(value) }
}

private func parsePersistentWorkspaces(_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<OrderedSet<String>> {
    parseArrayOfStrings(raw, backtrace)
        .flatMap { arr in
            let set = arr.toOrderedSet()
            return set.count == arr.count ? .success(set) : .failure(.semantic(backtrace, "Contains duplicated workspace names"))
        }
}

private func parseArrayOfStrings(_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<[String]> {
    parseTomlArray(raw, backtrace)
        .flatMap { arr in
            arr.enumerated().mapAllOrFailure { (index, elem) in
                parseString(elem, backtrace + .index(index))
            }
        }
}

private func parseDefaultContainerOrientation(_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<DefaultContainerOrientation> {
    parseString(raw, backtrace).flatMap {
        DefaultContainerOrientation(rawValue: $0)
            .orFailure(.semantic(backtrace, "Can't parse default container orientation '\($0)'"))
    }
}

extension Parsed where Failure == String {
    func toParsedConfig(_ backtrace: ConfigBacktrace) -> ParsedConfig<Success> {
        mapError { .semantic(backtrace, $0) }
    }
}

func parseBool(_ raw: Json, _ backtrace: ConfigBacktrace) -> ParsedConfig<Bool> {
    raw.asBoolOrNil.orFailure(expectedActualTypeError(expected: .bool, actual: raw.tomlType, backtrace))
}

struct ConfigBacktrace: CustomStringConvertible, Equatable {
    private var path: [TomlBacktraceItem] = []
    private init(_ path: [TomlBacktraceItem]) {
        check(path.first?.isKey != false, "Tried to construct invalid TOML path: \(path)")
        self.path = path
    }

    static func rootKey(_ key: String) -> Self { .init([.key(key)]) }
    static let emptyRoot: Self = .init([])

    var description: String {
        var result = ""
        for (i, elem) in path.enumerated() {
            switch elem {
                case .key(let rootKey) where i == 0: result += rootKey
                case .key(let key): result += ".\(key)"
                case .index(let index): result += "[\(index)]"
            }
        }
        return result
    }

    var isRootKey: Bool { path.singleOrNil().map(\.isKey) == true }

    static func + (lhs: Self, rhs: TomlBacktraceItem) -> Self {
        var result = lhs
        result.path += [rhs]
        return result
    }
}

enum TomlBacktraceItem: Equatable {
    case key(String)
    case index(Int)

    var isKey: Bool {
        switch self {
            case .key: true
            case .index: false
        }
    }
}

extension Json.JsonDict {
    func parseTable<T: ConvenienceCopyable>(
        _ initial: T,
        _ fieldsParser: [String: any ParserProtocol<T>],
        _ backtrace: ConfigBacktrace,
        _ errors: inout [ConfigParseError],
    ) -> T {
        var raw = initial

        for (key, value) in self {
            let backtrace: ConfigBacktrace = backtrace + .key(key)
            switch fieldsParser[key] {
                case let parser?: raw = parser.transformRawConfig(raw, value, backtrace, &errors)
                case nil: errors.append(unknownKeyError(backtrace))
            }
        }

        return raw
    }
}

func unknownKeyError(_ backtrace: ConfigBacktrace) -> ConfigParseError {
    .semantic(backtrace, backtrace.isRootKey ? "Unknown top-level key" : "Unknown key")
}

func expectedActualTypeError(expected: TomlType, actual: TomlType, _ backtrace: ConfigBacktrace) -> ConfigParseError {
    .semantic(backtrace, expectedActualTypeError(expected: expected, actual: actual))
}

func expectedActualTypeError(expected: [TomlType], actual: TomlType, _ backtrace: ConfigBacktrace) -> ConfigParseError {
    .semantic(backtrace, expectedActualTypeError(expected: expected, actual: actual))
}
