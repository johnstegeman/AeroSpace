import Common
import Foundation

struct WorkspaceSnapshotCommand: Command {
    let args: WorkspaceSnapshotCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        switch args.action.val {
            case .save:
                return await WorkspaceSnapshot.save(name: args.name.val, io: io)
            case .restore:
                return await WorkspaceSnapshot.restoreReturningExitCode(name: args.name.val, io: io)
        }
    }
}

enum WorkspaceSnapshot {
    private struct SnapshotWindowEntry {
        let bundleId: String
        let title: String?
    }

    struct RestoreSummary {
        let restoredFloatingCount: Int
        let restoredTilingCount: Int
        let skippedZoneAssignments: Int
        let workspaceCount: Int
    }

    enum SnapshotError: Error {
        case notFound
        case invalidFormat
    }

    private static var baseDirectory: URL {
        if isUnitTest {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("AeroSpaceTests", isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AeroSpace", isDirectory: true)
    }

    static func snapshotURL(name: String) -> URL {
        baseDirectory.appendingPathComponent("snapshots/\(name).json")
    }

    @MainActor
    static func save(name: String, io: CmdIo) async -> BinaryExitCode {
        let snapshot = await snapshotJson()
        telemetryLog("workspaceSnapshot.saveStarted", payload: [
            "name": .string(name),
            "workspaceCount": .int((snapshot["workspaces"] as? [[String: Any]])?.count ?? 0),
        ])
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) else {
            return .fail(io.err("workspace-snapshot: failed to serialize snapshot"))
        }
        let url = snapshotURL(name: name)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            telemetryLog("workspaceSnapshot.saveFinished", payload: [
                "name": .string(name),
                "path": .string(url.path),
                "sizeBytes": .int(data.count),
            ])
            return .succ(io.out("Snapshot '\(name)' saved."))
        } catch {
            telemetryLog("workspaceSnapshot.saveFailed", payload: [
                "error": .string(String(describing: error)),
                "name": .string(name),
                "path": .string(url.path),
            ])
            return .fail(io.err("workspace-snapshot: failed to write \(url.path): \(error)"))
        }
    }

    @MainActor
    static func restoreReturningExitCode(name: String, io: CmdIo) async -> BinaryExitCode {
        let (exitCode, _) = await restoreReturningResult(name: name, io: io)
        return exitCode
    }

    @MainActor
    static func restoreReturningResult(name: String, io: CmdIo) async -> (BinaryExitCode, RestoreSummary?) {
        do {
            let summary = try await restore(name: name, io: io)
            return (.succ(io.out("Snapshot '\(name)' restored.")), summary)
        } catch SnapshotError.notFound {
            return (.fail(io.err("workspace-snapshot: no snapshot named '\(name)' found at \(snapshotURL(name: name).path)")), nil)
        } catch SnapshotError.invalidFormat {
            return (.fail(io.err("workspace-snapshot: snapshot '\(name)' has an invalid format")), nil)
        } catch {
            return (.fail(io.err("workspace-snapshot: restore failed: \(error)")), nil)
        }
    }

    @MainActor
    static func restore(name: String, io: CmdIo = CmdIo(stdin: .emptyStdin)) async throws -> RestoreSummary {
        let url = snapshotURL(name: name)
        telemetryLog("workspaceSnapshot.restoreStarted", payload: [
            "name": .string(name),
            "path": .string(url.path),
        ])
        guard let data = try? Data(contentsOf: url) else { throw SnapshotError.notFound }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workspaces = root["workspaces"] as? [[String: Any]]
        else { throw SnapshotError.invalidFormat }

        var placed: Set<ObjectIdentifier> = []
        var skippedZoneAssignments = 0
        var restoredTilingCount = 0
        var restoredFloatingCount = 0
        for workspaceJson in workspaces {
            guard let workspaceName = workspaceJson["name"] as? String else { continue }
            let workspace = Workspace.get(byName: workspaceName)
            workspace.ensureZoneContainers(for: workspace.workspaceMonitor)

            if let zones = workspaceJson["zones"] as? [String: [[String: String]]] {
                for (zoneName, entries) in zones {
                    guard let zone = workspace.zoneContainers[zoneName] else {
                        skippedZoneAssignments += entries.count
                        continue
                    }
                    for entry in entries {
                        guard let parsed = parseSnapshotEntry(entry),
                              let window = await findWindow(entry: parsed, placed: &placed)
                        else { continue }
                        let binding = workspace.bindingDataForNewWindow(inZone: zoneName, zone: zone)
                        window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
                        binding.preferredMostRecentChildAfterBind?.markAsMostRecentChild()
                        restoredTilingCount += 1
                    }
                }
            }

            if let tiling = workspaceJson["tiling"] as? [[String: String]] {
                for entry in tiling {
                    guard let parsed = parseSnapshotEntry(entry),
                          let window = await findWindow(entry: parsed, placed: &placed)
                    else { continue }
                    let preferredZoneName = workspace.activeZoneDefinitions.isEmpty
                        ? nil
                        : workspace.activeZoneDefinitions[workspace.activeZoneDefinitions.count / 2].id
                    if let decision = workspace.resolveZonePlacement(
                        preferredZoneName: preferredZoneName,
                        source: .middleZoneFallback,
                    ) {
                        let binding = decision.bindingData
                        window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
                        binding.preferredMostRecentChildAfterBind?.markAsMostRecentChild()
                    } else {
                        window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
                    }
                    restoredTilingCount += 1
                }
            }

            if let floating = workspaceJson["floating"] as? [[String: String]] {
                for entry in floating {
                    guard let parsed = parseSnapshotEntry(entry),
                          let window = await findWindow(entry: parsed, placed: &placed)
                    else { continue }
                    window.bindAsFloatingWindow(to: workspace)
                    restoredFloatingCount += 1
                }
            }
        }
        if skippedZoneAssignments > 0 {
            io.err("workspace-snapshot: skipped \(skippedZoneAssignments) zone assignment(s) because the destination zones were not active")
        }
        telemetryLog("workspaceSnapshot.restoreFinished", payload: [
            "name": .string(name),
            "restoredFloatingCount": .int(restoredFloatingCount),
            "restoredTilingCount": .int(restoredTilingCount),
            "skippedZoneAssignments": .int(skippedZoneAssignments),
            "workspaceCount": .int(workspaces.count),
        ])
        return RestoreSummary(
            restoredFloatingCount: restoredFloatingCount,
            restoredTilingCount: restoredTilingCount,
            skippedZoneAssignments: skippedZoneAssignments,
            workspaceCount: workspaces.count,
        )
    }

    @MainActor
    private static func snapshotJson() async -> [String: Any] {
        var workspaces: [[String: Any]] = []
        for workspace in Workspace.all {
            var zoneEntries: [String: [[String: String]]] = [:]
            for def in workspace.activeZoneDefinitions {
                guard let zone = workspace.zoneContainers[def.id] else { continue }
                let entries = await zone.allLeafWindowsRecursive.asyncCompactMap(snapshotEntryJson(for:))
                if !entries.isEmpty {
                    zoneEntries[def.id] = entries
                }
            }
            let tilingEntries = workspace.activeZoneDefinitions.isEmpty
                ? await workspace.rootTilingContainer.allLeafWindowsRecursive.asyncCompactMap(snapshotEntryJson(for:))
                : []
            let floatingEntries = await workspace.children
                .compactMap { $0 as? Window }
                .asyncCompactMap(snapshotEntryJson(for:))
            guard !zoneEntries.isEmpty || !tilingEntries.isEmpty || !floatingEntries.isEmpty else { continue }
            var json: [String: Any] = ["name": workspace.name]
            if !zoneEntries.isEmpty { json["zones"] = zoneEntries }
            if !tilingEntries.isEmpty { json["tiling"] = tilingEntries }
            if !floatingEntries.isEmpty { json["floating"] = floatingEntries }
            workspaces.append(json)
        }
        return [
            "version": 1,
            "created": ISO8601DateFormatter().string(from: Date()),
            "workspaces": workspaces,
        ]
    }

    @MainActor
    private static func parseSnapshotEntry(_ raw: [String: String]) -> SnapshotWindowEntry? {
        guard let bundleId = raw["bundleId"] else { return nil }
        return SnapshotWindowEntry(bundleId: bundleId, title: raw["title"])
    }

    @MainActor
    private static func snapshotEntryJson(for window: Window) async -> [String: String]? {
        guard let bundleId = window.app.rawAppBundleId else { return nil }
        var result = ["bundleId": bundleId]
        if let rawTitle = try? await window.title,
           let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).takeIf({ !$0.isEmpty })
        {
            result["title"] = title
        }
        return result
    }

    @MainActor
    private static func findWindow(entry: SnapshotWindowEntry, placed: inout Set<ObjectIdentifier>) async -> Window? {
        var best: (window: Window, score: Int)? = nil
        for window in Workspace.all.flatMap(\.allLeafWindowsRecursive) {
            guard window.app.rawAppBundleId == entry.bundleId else { continue }
            let id = ObjectIdentifier(window)
            guard !placed.contains(id) else { continue }
            let score = await snapshotMatchScore(saved: entry, current: window)
            if let best, best.score >= score {
                continue
            }
            best = (window, score)
        }
        if let best {
            _ = placed.insert(ObjectIdentifier(best.window))
            let matchedTitle = try? await best.window.title
            telemetryLog("workspaceSnapshot.windowMatched", payload: compactTelemetry(
                ("bundleId", .string(entry.bundleId)),
                ("matchedTitle", telemetryString(matchedTitle)),
                ("savedTitle", telemetryString(entry.title)),
                ("score", .int(best.score)),
                ("windowId", .int(Int(best.window.windowId)))
            ))
            return best.window
        }
        telemetryLog("workspaceSnapshot.windowMatchMissed", payload: compactTelemetry(
            ("bundleId", .string(entry.bundleId)),
            ("savedTitle", telemetryString(entry.title))
        ))
        return nil
    }

    @MainActor
    private static func snapshotMatchScore(saved: SnapshotWindowEntry, current: Window) async -> Int {
        guard let savedTitle = normalizeSnapshotTitle(saved.title) else { return 0 }
        let currentTitle = normalizeSnapshotTitle(try? await current.title)
        guard let currentTitle else { return 0 }
        if currentTitle == savedTitle { return 100 }
        if currentTitle.contains(savedTitle) || savedTitle.contains(currentTitle) { return 50 }
        return 0
    }

    private static func normalizeSnapshotTitle(_ title: String?) -> String? {
        title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .takeIf { !$0.isEmpty }
    }
}

extension Sequence {
    fileprivate func asyncCompactMap<T>(
        _ transform: (Element) async -> T?
    ) async -> [T] {
        var result: [T] = []
        for element in self {
            if let mapped = await transform(element) {
                result.append(mapped)
            }
        }
        return result
    }
}
