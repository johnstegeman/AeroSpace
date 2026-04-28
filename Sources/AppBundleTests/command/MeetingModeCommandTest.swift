@testable import AppBundle
import Common
import XCTest

@MainActor
final class MeetingModeCommandTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        setTestMonitorsOverride([FakeMonitor.ultrawide])
        XCTAssertTrue(FakeMonitor.ultrawide.setActiveWorkspace(focus.workspace))
    }

    func testParseMeetingModeCommand() {
        testParseCommandSucc("meeting-mode on", MeetingModeCmdArgs(rawArgs: []).copy(\.action, .initialized(.on)))
        testParseCommandSucc("meeting-mode off", MeetingModeCmdArgs(rawArgs: []).copy(\.action, .initialized(.off)))
        testParseCommandSucc("meeting-mode toggle", MeetingModeCmdArgs(rawArgs: []).copy(\.action, .initialized(.toggle)))
        testParseCommandFail(
            "meeting-mode",
            msg: "ERROR: Argument '(on|off|toggle)' is mandatory",
            exitCode: 2
        )
    }

    func testMeetingModeOnOff_appliesPresetRoutesConfiguredAppsAndRestoresPreviousZones() async throws {
        let workspace = focus.workspace
        config.zones.zones = [
            ZoneDefinition(id: "chat", width: 0.2, layout: .tiles),
            ZoneDefinition(id: "main", width: 0.6, layout: .tiles),
            ZoneDefinition(id: "tools", width: 0.2, layout: .accordion),
        ]
        config.zonePresets["meeting"] = ZonePreset(zones: [
            ZoneDefinition(id: "left", width: 0.2, layout: .tiles),
            ZoneDefinition(id: "center", width: 0.55, layout: .tiles),
            ZoneDefinition(id: "right", width: 0.25, layout: .stack),
        ])
        config.meeting = MeetingConfig(
            preset: "meeting",
            appIds: ["com.example.dia"],
            supportAppIds: ["com.example.granola"],
            meetingZone: "center",
            supportZone: "right"
        )
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide, force: true)

        let browserApp = TestApp(bundleId: "com.example.dia")
        let supportApp = TestApp(bundleId: "com.example.granola")
        let otherApp = TestApp(bundleId: "com.example.notes")
        let browser = TestWindow.new(id: 1, parent: try XCTUnwrap(workspace.zoneContainers["chat"]), app: browserApp)
        let support = TestWindow.new(id: 2, parent: try XCTUnwrap(workspace.zoneContainers["main"]), app: supportApp)
        let other = TestWindow.new(id: 3, parent: try XCTUnwrap(workspace.zoneContainers["tools"]), app: otherApp)
        XCTAssertTrue(browser.focusWindow())
        let io = CmdIo(stdin: .emptyStdin)

        let onResult = try await enableMeetingMode(on: workspace, monitor: FakeMonitor.ultrawide, io)
        XCTAssertEqual(onResult.rawValue, 0)
        XCTAssertEqual(workspace.activeZoneDefinitions.map(\.id), ["left", "center", "right"])
        XCTAssertEqual(workspace.zoneContaining(browser)?.name, "center")
        XCTAssertEqual(workspace.zoneContaining(support)?.name, "right")
        XCTAssertNotNil(workspace.meetingModeSnapshot)
        XCTAssertEqual(activeZonePresetName, "meeting")

        let offResult = disableMeetingMode(on: workspace, io)
        XCTAssertEqual(offResult.rawValue, 0)
        XCTAssertEqual(workspace.activeZoneDefinitions.map(\.id), ["chat", "main", "tools"])
        XCTAssertEqual(workspace.zoneContaining(browser)?.name, "chat")
        XCTAssertEqual(workspace.zoneContaining(support)?.name, "main")
        XCTAssertEqual(workspace.zoneContaining(other)?.name, "tools")
        XCTAssertNil(workspace.meetingModeSnapshot)
    }

    func testMeetingMode_forceRebuildKeepsMeetingModeActive() async throws {
        let workspace = focus.workspace
        config.meeting = MeetingConfig(preset: nil, appIds: ["com.example.dia"], supportAppIds: [], meetingZone: "center", supportZone: "right")
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let io = CmdIo(stdin: .emptyStdin)

        _ = try await enableMeetingMode(on: workspace, monitor: FakeMonitor.ultrawide, io)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide, force: true)

        XCTAssertNotNil(workspace.meetingModeSnapshot)
        XCTAssertEqual(workspace.activeZoneDefinitions.map(\.id), ["left", "center", "right"])
    }

    func testMeetingMode_restorePreservesPerZoneLeafOrder() async throws {
        let workspace = focus.workspace
        config.meeting = MeetingConfig(preset: nil, appIds: ["com.example.placeholder"], supportAppIds: [], meetingZone: "center", supportZone: "right")
        config.zones.zones = [
            ZoneDefinition(id: "left", width: 0.34, layout: .tiles),
            ZoneDefinition(id: "center", width: 0.33, layout: .tiles),
            ZoneDefinition(id: "right", width: 0.33, layout: .tiles),
        ]
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let center = try XCTUnwrap(workspace.zoneContainers["center"])
        let first = TestWindow.new(id: 1, parent: center)
        let second = TestWindow.new(id: 2, parent: center)
        let third = TestWindow.new(id: 3, parent: center)
        XCTAssertTrue(second.focusWindow())
        let io = CmdIo(stdin: .emptyStdin)

        _ = try await enableMeetingMode(on: workspace, monitor: FakeMonitor.ultrawide, io)
        _ = disableMeetingMode(on: workspace, io)

        let restored = try XCTUnwrap(workspace.zoneContainers["center"]).allLeafWindowsRecursive.map(\.windowId)
        XCTAssertEqual(restored, [first.windowId, second.windowId, third.windowId])
    }

    func testMeetingMode_updatesAndRestoresActivePresetName() async throws {
        let workspace = focus.workspace
        config.zonePresets["meeting"] = ZonePreset(zones: workspace.currentLiveZoneDefinitions())
        config.meeting = MeetingConfig(preset: "meeting", appIds: [], supportAppIds: [], meetingZone: "center", supportZone: "right")
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        activeZonePresetName = "balanced"
        let io = CmdIo(stdin: .emptyStdin)

        _ = try await enableMeetingMode(on: workspace, monitor: FakeMonitor.ultrawide, io)
        XCTAssertEqual(activeZonePresetName, "meeting")

        _ = disableMeetingMode(on: workspace, io)
        XCTAssertEqual(activeZonePresetName, "balanced")
    }

    func testMeetingMode_activatesConfiguredWorkspace() async throws {
        let currentWorkspace = focus.workspace
        let targetWorkspace = Workspace.get(byName: "2")
        XCTAssertTrue(FakeMonitor.ultrawide.setActiveWorkspace(currentWorkspace))
        config.meeting = MeetingConfig(
            preset: nil,
            workspace: "2",
            appIds: ["com.example.dia"],
            supportAppIds: [],
            meetingZone: "center",
            supportZone: "right"
        )
        targetWorkspace.ensureZoneContainers(for: FakeMonitor.ultrawide)

        let command = MeetingModeCommand(args: MeetingModeCmdArgs(rawArgs: []).copy(\.action, .initialized(.on)))
        let result = try await command.run(.defaultEnv, CmdIo(stdin: .emptyStdin))

        XCTAssertEqual(result.rawValue, 0)
        XCTAssertEqual(focus.workspace.name, "2")
        XCTAssertNotNil(targetWorkspace.meetingModeSnapshot)
    }

    func testMeetingMode_disconnectClearsSnapshotAndRestoresPresetName() async throws {
        let workspace = focus.workspace
        config.meeting = MeetingConfig(preset: nil, appIds: ["com.example.dia"], supportAppIds: [], meetingZone: "center", supportZone: "right")
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        activeZonePresetName = "balanced"
        let io = CmdIo(stdin: .emptyStdin)

        _ = try await enableMeetingMode(on: workspace, monitor: FakeMonitor.ultrawide, io)
        workspace.ensureZoneContainers(for: FakeMonitor.standard)

        XCTAssertTrue(workspace.zoneContainers.isEmpty)
        XCTAssertNil(workspace.meetingModeSnapshot)
        XCTAssertEqual(activeZonePresetName, "balanced")
    }
}
