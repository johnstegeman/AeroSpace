import AppKit
import Common
import HotKey
import OrderedCollections

func getDefaultConfigUrlFromProject() -> URL {
    var url = URL(filePath: #filePath)
    check(FileManager.default.fileExists(atPath: url.path))
    while !FileManager.default.fileExists(atPath: url.appending(component: ".git").path) {
        url.deleteLastPathComponent()
    }
    let projectRoot: URL = url
    return projectRoot.appending(component: "docs/config-examples/default-config.toml")
}

var defaultConfigUrl: URL {
    if isUnitTest {
        return getDefaultConfigUrlFromProject()
    } else {
        return Bundle.main.url(forResource: "default-config", withExtension: "toml")
            // Useful for debug builds that are not app bundles
            ?? getDefaultConfigUrlFromProject()
    }
}
@MainActor let defaultConfig: Config = {
    let parsedConfig = parseConfig(Result { try String(contentsOf: defaultConfigUrl, encoding: .utf8) }.getOrDie())
    if !parsedConfig.errors.isEmpty {
        die("Can't parse default config: \(parsedConfig.errors)")
    }
    return parsedConfig.config
}()
@MainActor var config: Config = defaultConfig // todo move to Ctx?
@MainActor var configUrl: URL = defaultConfigUrl

struct Config: ConvenienceCopyable {
    var configVersion: Int = 1
    var afterLoginCommand: [any Command] = []
    var afterStartupCommand: [any Command] = []
    var _indentForNestedContainersWithTheSameOrientation: Void = ()
    var enableNormalizationFlattenContainers: Bool = true
    var _nonEmptyWorkspacesRootContainersLayoutOnStartup: Void = ()
    var defaultRootContainerLayout: Layout = .tiles
    var defaultRootContainerOrientation: DefaultContainerOrientation = .auto
    var startAtLogin: Bool = false
    var autoReloadConfig: Bool = false
    var automaticallyUnhideMacosHiddenApps: Bool = false
    var accordion: AccordionConfig = AccordionConfig()
    var enableNormalizationOppositeOrientationForNestedContainers: Bool = true
    var persistentWorkspaces: OrderedSet<String> = []
    var execOnWorkspaceChange: [String] = [] // todo deprecate
    var keyMapping = KeyMapping()
    var execConfig: ExecConfig = ExecConfig()

    var onFocusChanged: [any Command] = []
    // var onFocusedWorkspaceChanged: [any Command] = []
    var onFocusedMonitorChanged: [any Command] = []

    var gaps: Gaps = .zero
    var workspaceToMonitorForceAssignment: [String: [MonitorDescription]] = [:]
    var modes: [String: Mode] = [:]
    var onWindowDetected: [WindowDetectedCallback] = []
    var onModeChanged: [any Command] = []
    var zones: ZonesConfig = ZonesConfig()
    var hud: HUDConfig = HUDConfig()
}

struct HUDConfig: ConvenienceCopyable {
    var activeOn: HUDActiveOn = .ultrawide
}

enum HUDActiveOn: String {
    case ultrawide, always, never
}

struct AccordionConfig: ConvenienceCopyable {
    var mode: AccordionMode = .overlap
    var padding: Int = 30
    var offsetX: Int = 24
    var offsetY: Int = 0
}

enum AccordionMode: String {
    case overlap, cascade
}

struct ZonesConfig: ConvenienceCopyable {
    /// Proportional widths for left/center/right zones. Must have exactly 3 elements summing to 1.0.
    /// Falls back to equal thirds if absent or invalid.
    var widths: [Double] = [1.0 / 3, 1.0 / 3, 1.0 / 3]
    /// Default layout for left/center/right zones. Must have exactly 3 elements.
    /// Falls back to tiles if absent or invalid.
    var layouts: [Layout] = [.tiles, .tiles, .tiles]
    /// Gap in pixels between zone containers. Does not affect gaps within zones.
    var gap: Int = 0
    /// Per-zone outer-gap overrides keyed by zone name. A nil side means use the global gap.
    var overrides: [String: ZoneGapOverride] = [:]
}

/// Outer-gap overrides for a single zone. nil on any side means use the global outer-gap value.
struct ZoneGapOverride: ConvenienceCopyable {
    var top: Int? = nil
    var bottom: Int? = nil
    var left: Int? = nil
    var right: Int? = nil
}

enum DefaultContainerOrientation: String {
    case horizontal, vertical, auto
}
