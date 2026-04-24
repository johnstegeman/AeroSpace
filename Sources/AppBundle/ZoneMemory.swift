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

    struct Entry: Equatable {
        let profileKey: String
        let appId: String
        let zoneName: String
    }

    private var data: [String: [String: String]] = [:]
    let storageURL: URL
    private let onSave: (() -> Void)?
    private var batchDepth = 0
    private var pendingSave = false

    private static var defaultURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AeroSpace/zone-memory.json")
    }

    init(storageURL: URL? = nil, onSave: (() -> Void)? = nil) {
        self.storageURL = storageURL ?? Self.defaultURL
        self.onSave = onSave
        load()
    }

    func windowKey(for window: Window) -> String? {
        window.app.rawAppBundleId
    }

    func rememberZone(_ zoneName: String, for window: Window, profile: MonitorProfile) {
        guard let key = windowKey(for: window) else { return }
        rememberZone(zoneName, forBundleId: key, profile: profile)
    }

    func rememberZone(_ zoneName: String, forBundleId bundleId: String, profile: MonitorProfile) {
        let profileKey = profile.key
        if data[profileKey] == nil { data[profileKey] = [:] }
        data[profileKey]![bundleId] = zoneName
        saveOrDefer()
    }

    func rememberedZone(for window: Window, profile: MonitorProfile) -> String? {
        guard let key = windowKey(for: window) else { return nil }
        return data[profile.key]?[key]
    }

    func rememberedZone(forBundleId bundleId: String, profile: MonitorProfile) -> String? {
        data[profile.key]?[bundleId]
    }

    func entries() -> [Entry] {
        data
            .flatMap { profileKey, appToZone in
                appToZone.map { appId, zoneName in
                    Entry(profileKey: profileKey, appId: appId, zoneName: zoneName)
                }
            }
            .sorted { ($0.profileKey, $0.appId, $0.zoneName) < ($1.profileKey, $1.appId, $1.zoneName) }
    }

    @discardableResult
    func clearAll() -> Int {
        let removed = data.values.reduce(0) { $0 + $1.count }
        data = [:]
        saveOrDefer()
        return removed
    }

    @discardableResult
    func clear(bundleId: String) -> Int {
        var removed = 0
        for profileKey in Array(data.keys) {
            let previous = data[profileKey]?.removeValue(forKey: bundleId)
            if previous != nil { removed += 1 }
            if data[profileKey]?.isEmpty == true {
                data.removeValue(forKey: profileKey)
            }
        }
        if removed > 0 { saveOrDefer() }
        return removed
    }

    func withBatchUpdate<T>(_ body: () throws -> T) rethrows -> T {
        batchDepth += 1
        defer {
            batchDepth -= 1
            if batchDepth == 0, pendingSave {
                pendingSave = false
                save()
            }
        }
        return try body()
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
        onSave?()
    }

    private func saveOrDefer() {
        if batchDepth > 0 {
            pendingSave = true
        } else {
            save()
        }
    }
}
