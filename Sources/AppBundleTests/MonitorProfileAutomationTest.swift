@testable import AppBundle
import XCTest

@MainActor
final class MonitorProfileAutomationTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testApplyMatchingMonitorProfileCanDisableZones() async {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        XCTAssertFalse(workspace.zoneContainers.isEmpty)

        config.monitorProfiles = [
            MonitorProfileRule(
                name: "single-monitor-disabled",
                matcher: MonitorProfileRuleMatcher(minAspectRatio: nil, monitorCount: 1),
                applyZoneLayout: "disabled",
                restoreWorkspaceSnapshot: nil,
            ),
        ]

        await applyMatchingMonitorProfile()

        XCTAssertEqual(activeMonitorProfileName, "single-monitor-disabled")
        XCTAssertTrue(zonesDisabledByProfile)
        XCTAssertTrue(workspace.zoneContainers.isEmpty)
    }

    func testApplyMatchingMonitorProfileAppliesPreset() async {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        config.zonePresets["wide"] = ZonePreset(zones: [
            ZoneDefinition(id: "main", width: 0.7, layout: .tiles),
            ZoneDefinition(id: "side", width: 0.3, layout: .accordion),
        ])
        config.monitorProfiles = [
            MonitorProfileRule(
                name: "single-monitor-wide",
                matcher: MonitorProfileRuleMatcher(minAspectRatio: nil, monitorCount: 1),
                applyZoneLayout: "wide",
                restoreWorkspaceSnapshot: nil,
            ),
        ]

        await applyMatchingMonitorProfile()

        XCTAssertEqual(activeMonitorProfileName, "single-monitor-wide")
        XCTAssertEqual(activeZonePresetName, "wide")
        XCTAssertEqual(config.zones.zones.map(\.id), ["main", "side"])
        XCTAssertFalse(zonesDisabledByProfile)
    }

    func testGcMonitorsReevaluatesProfilesWhenMonitorCountStaysTheSameButResolutionChanges() async {
        config.monitorProfiles = [
            MonitorProfileRule(
                name: "ultrawide-only",
                matcher: MonitorProfileRuleMatcher(minAspectRatio: 2.0, monitorCount: 1),
                applyZoneLayout: "disabled",
                restoreWorkspaceSnapshot: nil,
            ),
        ]

        setTestMonitorsOverride([FakeMonitor.standard])
        await gcMonitors()
        XCTAssertNil(activeMonitorProfileName)

        setTestMonitorsOverride([FakeMonitor.ultrawide])
        await gcMonitors()
        XCTAssertEqual(activeMonitorProfileName, "ultrawide-only")
        XCTAssertTrue(zonesDisabledByProfile)
    }

    func testGcMonitorsRefreshesHiddenWorkspaceZonesOnTopologyChange() async {
        let hiddenWorkspace = Workspace.get(byName: "P")
        hiddenWorkspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        XCTAssertFalse(hiddenWorkspace.zoneContainers.isEmpty)

        setTestMonitorsOverride([FakeMonitor.standard])
        await gcMonitors()
        XCTAssertTrue(hiddenWorkspace.zoneContainers.isEmpty)

        setTestMonitorsOverride([FakeMonitor.ultrawide])
        await gcMonitors()
        XCTAssertFalse(hiddenWorkspace.zoneContainers.isEmpty)
    }

    func testGcMonitorsFocusedWorkspaceFollowsRemovedFocusedMonitorWithoutLosingRememberedSplit() async {
        let ultrawide = FakeMonitor.ultrawide
        let laptop = FakeMonitor(width: 1920, height: 1080, topLeftX: 3440, name: "Laptop", monitorAppKitNsScreenScreensId: 2)
        let workspace1 = Workspace.get(byName: "1")
        let workspaceP = Workspace.get(byName: "P")

        setTestMonitorsOverride([ultrawide, laptop])
        XCTAssertTrue(ultrawide.setActiveWorkspace(workspace1))
        XCTAssertTrue(laptop.setActiveWorkspace(workspaceP))
        XCTAssertTrue(workspace1.focusWorkspace())
        workspace1.ensureZoneContainers(for: ultrawide)
        XCTAssertFalse(workspace1.zoneContainers.isEmpty)

        setTestMonitorsOverride([laptop])
        await gcMonitors()

        XCTAssertEqual(laptop.activeWorkspace, workspace1)
        XCTAssertTrue(workspace1.isVisible)
        XCTAssertFalse(workspaceP.isVisible)
        XCTAssertTrue(workspace1.zoneContainers.isEmpty)

        setTestMonitorsOverride([ultrawide, laptop])
        await gcMonitors()

        XCTAssertEqual(ultrawide.activeWorkspace, workspace1)
        XCTAssertEqual(laptop.activeWorkspace, workspaceP)
        XCTAssertFalse(workspace1.zoneContainers.isEmpty)
    }

    func testGcMonitorsRemovingNonFocusedMonitorPreservesSurvivorAndRestoresRemovedWorkspaceWhenReadded() async {
        let ultrawide = FakeMonitor.ultrawide
        let laptop = FakeMonitor(width: 1920, height: 1080, topLeftX: 3440, name: "Laptop", monitorAppKitNsScreenScreensId: 2)
        let workspace1 = Workspace.get(byName: "1")
        let workspaceP = Workspace.get(byName: "P")

        setTestMonitorsOverride([ultrawide, laptop])
        XCTAssertTrue(ultrawide.setActiveWorkspace(workspace1))
        XCTAssertTrue(laptop.setActiveWorkspace(workspaceP))
        XCTAssertTrue(workspace1.focusWorkspace())

        setTestMonitorsOverride([ultrawide])
        await gcMonitors()

        XCTAssertEqual(ultrawide.activeWorkspace, workspace1)
        XCTAssertFalse(workspaceP.isVisible)

        setTestMonitorsOverride([ultrawide, laptop])
        await gcMonitors()

        XCTAssertEqual(ultrawide.activeWorkspace, workspace1)
        XCTAssertEqual(laptop.activeWorkspace, workspaceP)
    }

    func testGcMonitorsIgnoresTransientUnnamedMonitorAndPreservesZoneAssignments() async {
        let ultrawide = FakeMonitor.ultrawide
        let transient = FakeMonitor(width: 1728, height: 1117, name: "", monitorAppKitNsScreenScreensId: 1, isMain: true)
        let workspace = Workspace.get(byName: "1")

        setTestMonitorsOverride([ultrawide])
        XCTAssertTrue(ultrawide.setActiveWorkspace(workspace))
        XCTAssertTrue(workspace.focusWorkspace())
        workspace.ensureZoneContainers(for: ultrawide)

        let left = workspace.zoneContainers["left"].orDie()
        let center = workspace.zoneContainers["center"].orDie()
        let leftWindow = TestWindow.new(id: 1, parent: left)
        let centerWindow = TestWindow.new(id: 2, parent: center)

        setTestMonitorsOverride([transient])
        await gcMonitors()

        XCTAssertTrue(workspace.isVisible)
        XCTAssertFalse(workspace.zoneContainers.isEmpty, "Transient unnamed monitors should not tear down zones")
        XCTAssertTrue(leftWindow.parent === left, "Existing windows should stay in their prior zone containers during transient monitor loss")
        XCTAssertTrue(centerWindow.parent === center, "Existing windows should not be rebound through root fallback during transient monitor loss")

        setTestMonitorsOverride([ultrawide])
        await gcMonitors()

        XCTAssertTrue(workspace.isVisible)
        XCTAssertFalse(workspace.zoneContainers.isEmpty)
        XCTAssertTrue(leftWindow.parent === left)
        XCTAssertTrue(centerWindow.parent === center)
    }

    func testApplyMatchingMonitorProfileClearsManagedPresetWhenNoProfileMatches() async {
        config.zonePresets["wide"] = ZonePreset(zones: [
            ZoneDefinition(id: "main", width: 0.7, layout: .tiles),
            ZoneDefinition(id: "side", width: 0.3, layout: .accordion),
        ])
        config.monitorProfiles = [
            MonitorProfileRule(
                name: "single-monitor-wide",
                matcher: MonitorProfileRuleMatcher(minAspectRatio: nil, monitorCount: 1),
                applyZoneLayout: "wide",
                restoreWorkspaceSnapshot: nil,
            ),
        ]

        await applyMatchingMonitorProfile()
        XCTAssertEqual(activeZonePresetName, "wide")
        XCTAssertEqual(config.zones.zones.map(\.id), ["main", "side"])

        config.monitorProfiles = []
        await applyMatchingMonitorProfile()

        XCTAssertNil(activeMonitorProfileName)
        XCTAssertNil(activeZonePresetName)
        XCTAssertFalse(monitorProfileManagedZoneLayout)
        XCTAssertFalse(zonesDisabledByProfile)
        XCTAssertEqual(config.zones.zones.map(\.id), defaultZonesConfig.zones.map(\.id))
    }
}
