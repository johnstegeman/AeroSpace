import AppKit
import Foundation

struct MonitorProfile: Codable, Hashable {
    struct MonitorEntry: Codable, Hashable {
        let width: CGFloat
        let height: CGFloat
    }

    let entries: [MonitorEntry]

    init(_ monitors: [any Monitor]) {
        entries = monitors
            .map { MonitorEntry(width: $0.rect.width, height: $0.rect.height) }
            .sorted { ($0.width, $0.height) < ($1.width, $1.height) }
    }

    var key: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(entries),
              let str = String(data: data, encoding: .utf8)
        else { return "unknown" }
        return str
    }
}

final class ZoneMemory {
    @MainActor static var shared = ZoneMemory()

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

    func windowKey(for window: Window) -> String? {
        window.app.rawAppBundleId
    }

    func rememberZone(_ zoneName: String, for window: Window, profile: MonitorProfile) {
        guard let key = windowKey(for: window) else { return }
        let profileKey = profile.key
        if data[profileKey] == nil { data[profileKey] = [:] }
        data[profileKey]![key] = zoneName
        save()
    }

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
