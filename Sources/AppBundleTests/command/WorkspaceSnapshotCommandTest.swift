@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class WorkspaceSnapshotCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        XCTAssertEqual((parseCommand("workspace-snapshot save dev").cmdOrDie as? WorkspaceSnapshotCommand)?.args.action.val, .save)
        XCTAssertEqual((parseCommand("workspace-snapshot save dev").cmdOrDie as? WorkspaceSnapshotCommand)?.args.name.val, "dev")
        XCTAssertEqual(parseCommand("workspace-snapshot save bad/name").errorOrNil, "ERROR: Snapshot name must match [a-zA-Z0-9_-]+, got 'bad/name'")
    }

    func testSaveSnapshotWritesZonesAndFloatingWindows() async throws {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        _ = TestWindow.new(id: 1, parent: workspace.zoneContainers["left"].orDie())
        _ = TestWindow.new(id: 2, parent: workspace)

        let args = (parseCommand("workspace-snapshot save dev").cmdOrDie as! WorkspaceSnapshotCommand).args
        let result = try await WorkspaceSnapshotCommand(args: args).run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode.rawValue, 0)

        let data = try Data(contentsOf: WorkspaceSnapshot.snapshotURL(name: "dev"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]])
        let savedWorkspace = try XCTUnwrap(workspaces.first)
        let zones = try XCTUnwrap(savedWorkspace["zones"] as? [String: [[String: String]]])
        XCTAssertEqual(zones["left"]?.first?["bundleId"], TestApp.shared.rawAppBundleId)
        XCTAssertEqual(zones["left"]?.first?["title"], "TestWindow(1)")
        let floating = try XCTUnwrap(savedWorkspace["floating"] as? [[String: String]])
        XCTAssertEqual(floating.first?["bundleId"], TestApp.shared.rawAppBundleId)
        XCTAssertEqual(floating.first?["title"], "TestWindow(2)")
    }

    func testRestoreSnapshotRebindsWindows() async throws {
        setTestMonitorsOverride([FakeMonitor.ultrawide])
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"].orDie()
        let center = workspace.zoneContainers["center"].orDie()
        let window = TestWindow.new(id: 3, parent: center)

        let snapshot: [String: Any] = [
            "version": 1,
            "workspaces": [[
                "name": workspace.name,
                "zones": [
                    "left": [["bundleId": TestApp.shared.rawAppBundleId]],
                ],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        let url = WorkspaceSnapshot.snapshotURL(name: "restore-me")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)

        let args = (parseCommand("workspace-snapshot restore restore-me").cmdOrDie as! WorkspaceSnapshotCommand).args
        let result = try await WorkspaceSnapshotCommand(args: args).run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode.rawValue, 0)
        XCTAssertTrue(window.parent === left)
        XCTAssertFalse(window.parent === center)
    }

    func testRestoreSnapshotEnsuresZonesBeforeRebinding() async throws {
        setTestMonitorsOverride([FakeMonitor.ultrawide])
        let workspace = focus.workspace
        XCTAssertTrue(workspace.zoneContainers.isEmpty)
        let window = TestWindow.new(id: 4, parent: workspace.rootTilingContainer)

        let snapshot: [String: Any] = [
            "version": 1,
            "workspaces": [[
                "name": workspace.name,
                "zones": [
                    "left": [["bundleId": TestApp.shared.rawAppBundleId]],
                ],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        let url = WorkspaceSnapshot.snapshotURL(name: "restore-zones")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)

        let args = (parseCommand("workspace-snapshot restore restore-zones").cmdOrDie as! WorkspaceSnapshotCommand).args
        let result = try await WorkspaceSnapshotCommand(args: args).run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode.rawValue, 0)
        XCTAssertTrue(window.parent === workspace.zoneContainers["left"])
    }

    func testRestoreSnapshotWarnsWhenZoneAssignmentsAreSkipped() async throws {
        setTestMonitorsOverride([FakeMonitor.standard])
        let workspace = focus.workspace
        let window = TestWindow.new(id: 5, parent: workspace.rootTilingContainer)

        let snapshot: [String: Any] = [
            "version": 1,
            "workspaces": [[
                "name": workspace.name,
                "zones": [
                    "left": [["bundleId": TestApp.shared.rawAppBundleId]],
                ],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        let url = WorkspaceSnapshot.snapshotURL(name: "restore-skip")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)

        let io = CmdIo(stdin: .emptyStdin)
        let args = (parseCommand("workspace-snapshot restore restore-skip").cmdOrDie as! WorkspaceSnapshotCommand).args
        let result = try await WorkspaceSnapshotCommand(args: args).run(.defaultEnv, io)

        XCTAssertEqual(result.rawValue, 0)
        XCTAssertTrue(window.parent === workspace.rootTilingContainer)
        XCTAssertEqual(io.stderr, ["workspace-snapshot: skipped 1 zone assignment(s) because the destination zones were not active"])
    }

    func testRestoreSnapshotMatchesSameAppWindowsByTitleWhenAvailable() async throws {
        setTestMonitorsOverride([FakeMonitor.ultrawide])
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"].orDie()
        let right = workspace.zoneContainers["right"].orDie()
        let first = TestWindow.new(id: 10, parent: right, title: "first")
        let second = TestWindow.new(id: 11, parent: left, title: "second")

        let snapshot: [String: Any] = [
            "version": 2,
            "workspaces": [[
                "name": workspace.name,
                "zones": [
                    "left": [["bundleId": TestApp.shared.rawAppBundleId!, "title": "first"]],
                    "right": [["bundleId": TestApp.shared.rawAppBundleId!, "title": "second"]],
                ],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        let url = WorkspaceSnapshot.snapshotURL(name: "restore-titles")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)

        let args = (parseCommand("workspace-snapshot restore restore-titles").cmdOrDie as! WorkspaceSnapshotCommand).args
        let result = try await WorkspaceSnapshotCommand(args: args).run(.defaultEnv, .emptyStdin)

        XCTAssertEqual(result.exitCode.rawValue, 0)
        XCTAssertTrue(first.parent === left)
        XCTAssertTrue(second.parent === right)
    }

    func testSaveSnapshotIncludesNonZonedTilingWindows() async throws {
        let workspace = focus.workspace
        _ = TestWindow.new(id: 20, parent: workspace.rootTilingContainer, title: "tiling")

        let args = (parseCommand("workspace-snapshot save plain").cmdOrDie as! WorkspaceSnapshotCommand).args
        let result = try await WorkspaceSnapshotCommand(args: args).run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode.rawValue, 0)

        let data = try Data(contentsOf: WorkspaceSnapshot.snapshotURL(name: "plain"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]])
        let savedWorkspace = try XCTUnwrap(workspaces.first)
        let tiling = try XCTUnwrap(savedWorkspace["tiling"] as? [[String: String]])
        XCTAssertEqual(tiling.first?["bundleId"], TestApp.shared.rawAppBundleId)
        XCTAssertEqual(tiling.first?["title"], "tiling")
    }

    func testRestoreSnapshotRebindsNonZonedTilingWindows() async throws {
        let workspace = focus.workspace
        let window = TestWindow.new(id: 21, parent: workspace, title: "plain-tiling")

        let snapshot: [String: Any] = [
            "version": 2,
            "workspaces": [[
                "name": workspace.name,
                "tiling": [
                    ["bundleId": TestApp.shared.rawAppBundleId!, "title": "plain-tiling"],
                ],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        let url = WorkspaceSnapshot.snapshotURL(name: "restore-plain")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)

        let args = (parseCommand("workspace-snapshot restore restore-plain").cmdOrDie as! WorkspaceSnapshotCommand).args
        let result = try await WorkspaceSnapshotCommand(args: args).run(.defaultEnv, .emptyStdin)

        XCTAssertEqual(result.exitCode.rawValue, 0)
        XCTAssertTrue(window.parent === workspace.rootTilingContainer)
    }

    func testRestoreSnapshotSupportsLegacyEntryFormatWithoutTitle() async throws {
        setTestMonitorsOverride([FakeMonitor.ultrawide])
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"].orDie()
        let center = workspace.zoneContainers["center"].orDie()
        let window = TestWindow.new(id: 22, parent: center)

        let snapshot: [String: Any] = [
            "version": 1,
            "workspaces": [[
                "name": workspace.name,
                "zones": [
                    "left": [["bundleId": TestApp.shared.rawAppBundleId!]],
                ],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        let url = WorkspaceSnapshot.snapshotURL(name: "restore-legacy")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)

        let args = (parseCommand("workspace-snapshot restore restore-legacy").cmdOrDie as! WorkspaceSnapshotCommand).args
        let result = try await WorkspaceSnapshotCommand(args: args).run(.defaultEnv, .emptyStdin)

        XCTAssertEqual(result.exitCode.rawValue, 0)
        XCTAssertTrue(window.parent === left)
    }
}
