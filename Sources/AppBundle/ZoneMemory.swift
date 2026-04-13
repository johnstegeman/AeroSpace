import Foundation

/// A stable fingerprint of the current monitor configuration.
/// Encodes all monitors sorted by origin so the same physical setup always produces the same key,
/// regardless of `CGDirectDisplayID` (which changes across reboots/reconnects).
struct MonitorProfile: Codable, Hashable {
    struct MonitorEntry: Codable, Hashable {
        let width: CGFloat
        let height: CGFloat
        let originX: CGFloat
        let originY: CGFloat
    }
    let entries: [MonitorEntry]

    init(_ monitors: [any Monitor]) {
        entries = monitors
            .map { MonitorEntry(width: $0.rect.width, height: $0.rect.height, originX: $0.rect.minX, originY: $0.rect.minY) }
            .sorted { ($0.originX, $0.originY) < ($1.originX, $1.originY) }
    }

    /// A stable string key for use as a dictionary key in persisted JSON.
    var key: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(entries),
              let str = String(data: data, encoding: .utf8)
        else { return "unknown" }
        return str
    }
}

/// Persists window-to-zone assignments keyed by monitor profile.
/// Window key is the app's bundle ID (Phase 2 uses bundleID-only; title-based disambiguation deferred).
/// Corrupt or missing JSON silently resets to an empty state.
final class ZoneMemory {
    @MainActor static var shared = ZoneMemory()

    // [profileKey: [windowKey: zoneName]]
    private var data: [String: [String: String]] = [:]
    let storageURL: URL

    private static var defaultURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AeroSpace/zone-memory.json")
    }

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultURL
        load()
    }

    /// Returns the window key for a window, or nil if the app has no bundle ID.
    func windowKey(for window: Window) -> String? {
        window.app.rawAppBundleId
    }

    /// Records that `window` belongs to `zoneName` under the given monitor profile.
    func rememberZone(_ zoneName: String, for window: Window, profile: MonitorProfile) {
        guard let key = windowKey(for: window) else { return }
        let profileKey = profile.key
        if data[profileKey] == nil { data[profileKey] = [:] }
        data[profileKey]![key] = zoneName
        save()
    }

    /// Returns the remembered zone name for `window` under the given profile, or nil.
    func rememberedZone(for window: Window, profile: MonitorProfile) -> String? {
        guard let key = windowKey(for: window) else { return nil }
        return data[profile.key]?[key]
    }

    private func load() {
        guard let raw = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: raw)
        else {
            data = [:]
            return
        }
        data = decoded
    }

    private func save() {
        guard let raw = try? JSONEncoder().encode(data) else { return }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try? raw.write(to: storageURL)
    }
}
