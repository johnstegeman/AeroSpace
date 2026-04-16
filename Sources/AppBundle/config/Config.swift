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
/// Original zones config from the last config file load. Used by `zone-preset --reset`.
@MainActor var defaultZonesConfig: ZonesConfig = ZonesConfig()

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
    var zonePresets: [String: ZonePreset] = [:]
    var onMonitorChanged: [MonitorChangedCallback] = []
    var hud: HUDConfig = HUDConfig()
    var borders: BorderConfig = BorderConfig()
}

/// Rule that fires when the monitor configuration changes (monitor connected or disconnected).
struct MonitorChangedCallback: ConvenienceCopyable, Equatable {
    var matcher: MonitorChangedMatcher = MonitorChangedMatcher()
    var rawRun: [any Command]? = nil

    var run: [any Command] { rawRun ?? dieT("ID-9A3F1C72 should have discarded nil") }

    static func == (lhs: MonitorChangedCallback, rhs: MonitorChangedCallback) -> Bool {
        lhs.matcher == rhs.matcher && zip(lhs.run, rhs.run).allSatisfy { $0.equals($1) }
    }
}

/// Matcher for [[on-monitor-changed]] rules. All fields are optional; omitting a field means
/// the rule always matches on that criterion.
struct MonitorChangedMatcher: ConvenienceCopyable, Equatable {
    /// If set, the rule only fires when at least one currently-connected monitor has
    /// width/height aspect ratio >= this value.
    var anyMonitorMinAspectRatio: Double? = nil
}

/// A named zone layout preset that can be switched to at runtime via `zone-preset <name>`.
struct ZonePreset: ConvenienceCopyable {
    var name: String
    var widths: [Double]
    var layouts: [Layout]
}

struct HUDConfig: ConvenienceCopyable {
    var activeOn: HUDActiveOn = .ultrawide
}

struct BorderConfig: ConvenienceCopyable {
    var enabled: Bool = false
    var width: Double = 2.0
    /// Corner radius in points. 10.0 matches macOS native window corners (Big Sur+).
    var cornerRadius: Double = 10.0
    /// Active (focused) window border color in 0xAARRGGBB format.
    var activeColor: AeroColor = AeroColor(argb: 0xff5e81ac)
    /// Inactive window border color. Transparent by default (no border for inactive windows).
    var inactiveColor: AeroColor = .transparent
}

/// An ARGB color stored as four UInt8 components. Sendable and TOML-parseable.
struct AeroColor: ConvenienceCopyable, Sendable {
    var alpha: UInt8
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    static let transparent = AeroColor(argb: 0x00000000)

    init(argb: Int) {
        alpha = UInt8((argb >> 24) & 0xFF)
        red   = UInt8((argb >> 16) & 0xFF)
        green = UInt8((argb >> 8)  & 0xFF)
        blue  = UInt8(argb         & 0xFF)
    }

    var cgColor: CGColor {
        CGColor(red: CGFloat(red)/255, green: CGFloat(green)/255, blue: CGFloat(blue)/255, alpha: CGFloat(alpha)/255)
    }

    var isTransparent: Bool { alpha == 0 }
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
    /// Width in pixels that non-focused zones are collapsed to when zone-focus-mode is active.
    /// Large enough to show notification badges (≥40) without being readable (≤120). Default 80.
    var focusModeCollapsedWidth: Int = 80
    /// Per-zone outer-gap overrides keyed by zone name. A nil side inherits the global gap unchanged.
    var overrides: [String: ZoneGapOverride] = [:]
}

/// Absolute outer-gap override for a single zone. Each non-nil side is the pixel distance from the
/// screen edge for that zone — it replaces (not adds to) the global outer-gap value for that side.
/// nil means inherit the global outer-gap value.
struct ZoneGapOverride: ConvenienceCopyable {
    var top: Int? = nil
    var bottom: Int? = nil
    var left: Int? = nil
    var right: Int? = nil
}

enum DefaultContainerOrientation: String {
    case horizontal, vertical, auto
}
