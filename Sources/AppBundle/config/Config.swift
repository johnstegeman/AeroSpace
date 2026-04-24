import AppKit
import Common
import HotKey
import OrderedCollections

func getDefaultConfigUrlFromProject() -> URL {
    var url = URL(filePath: #filePath)
    check(FileManager.default.fileExists(atPath: url.path))
    while !FileManager.default.fileExists(atPath: url.appending(component: "Package.swift").path) {
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
    var accordionPadding: Int = 30
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
    var floating: FloatingConfig = FloatingConfig()
    var onModeChanged: [any Command] = []
    var zones: ZonesConfig = ZonesConfig()
    var zonePresets: [String: ZonePreset] = [:]
    var monitorProfiles: [MonitorProfileRule] = []
    var onMonitorChanged: [MonitorChangedCallback] = []
}

/// A single zone in a zone layout: stable ID, proportional width, and default layout.
struct ZoneDefinition {
    var id: String
    var width: Double
    var layout: Layout
}

struct FloatingConfig: ConvenienceCopyable, Equatable {
    /// App bundle IDs whose windows should float by default.
    var appIds: [String] = []
}

struct ZoneBehavior: ConvenienceCopyable, Equatable {
    var newWindow: ZoneNewWindowPolicy = .afterFocused
}

enum ZoneNewWindowPolicy: String, Equatable {
    case append = "append"
    case afterFocused = "after-focused"
    case appendHidden = "append-hidden"
}

/// A named zone layout preset that can be switched to at runtime via `zone-preset <name>`.
struct ZonePreset: ConvenienceCopyable {
    var zones: [ZoneDefinition]
}

struct MonitorProfileRule: ConvenienceCopyable, Equatable {
    var name: String = ""
    var matcher: MonitorProfileRuleMatcher = MonitorProfileRuleMatcher()
    var applyZoneLayout: String? = nil
    var restoreWorkspaceSnapshot: String? = nil
}

struct MonitorProfileRuleMatcher: ConvenienceCopyable, Equatable {
    var minAspectRatio: Double? = nil
    var monitorCount: Int? = nil
}

/// Rule that fires when the monitor configuration changes (connect/disconnect/rearrange).
struct MonitorChangedCallback: ConvenienceCopyable, Equatable {
    var matcher: MonitorChangedMatcher = MonitorChangedMatcher()
    var rawRun: [any Command]? = nil

    var run: [any Command] { rawRun ?? dieT("ID-9A3F1C72 should have discarded nil") }

    static func == (lhs: MonitorChangedCallback, rhs: MonitorChangedCallback) -> Bool {
        lhs.matcher == rhs.matcher && zip(lhs.run, rhs.run).allSatisfy { $0.equals($1) }
    }
}

/// Matcher for [[on-monitor-changed]] rules. All fields are optional.
struct MonitorChangedMatcher: ConvenienceCopyable, Equatable {
    /// Fire only if at least one changed monitor has width/height aspect ratio >= this value.
    var anyMonitorMinAspectRatio: Double? = nil
}

struct ZonesConfig: ConvenienceCopyable {
    /// Ordered zone definitions. Each entry has a stable ID, a proportional width, and a layout.
    /// Widths must sum to 1.0. Defaults to three equal tiles named left/center/right.
    var zones: [ZoneDefinition] = [
        ZoneDefinition(id: "left",   width: 1.0 / 3, layout: .tiles),
        ZoneDefinition(id: "center", width: 1.0 / 3, layout: .tiles),
        ZoneDefinition(id: "right",  width: 1.0 / 3, layout: .tiles),
    ]
    /// Gap in pixels between zone containers. Does not affect gaps within zones.
    var gap: Int = 0
    /// Width in pixels that non-focused zones are collapsed to when zone-focus-mode is active.
    var focusModeCollapsedWidth: Int = 80
    /// Per-zone insertion behavior for newly created tiling windows.
    /// Unspecified zones default to `.afterFocused`.
    var behavior: [String: ZoneBehavior] = [:]
    /// Declarative app-bundle-id to zone routing defaults.
    /// These apply only when the target zone exists in the active layout.
    var appRouting: [String: String] = [:]
}

enum DefaultContainerOrientation: String {
    case horizontal, vertical, auto
}
