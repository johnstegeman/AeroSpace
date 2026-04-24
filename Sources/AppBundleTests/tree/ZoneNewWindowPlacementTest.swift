@testable import AppBundle
import Common
import XCTest

@MainActor
final class ZoneNewWindowPlacementTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testNewWindow_fallbackToCenter() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await window.relayoutWindow(on: workspace, forceTile: true)
        XCTAssertTrue(window.parent === workspace.zoneContainers["center"], "No MRU window -> should land in center zone")
    }

    func testNewWindow_followsMruZone() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let windowA = TestWindow.new(id: 1, parent: left)
        let windowB = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await windowB.relayoutWindow(on: workspace, forceTile: true)
        XCTAssertTrue(windowA.parent === left, "Existing window should stay in left zone")
        XCTAssertTrue(windowB.parent === left, "New window should follow MRU zone")
    }

    func testNewWindow_fallbackToRoot_whenNoZones() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await window.relayoutWindow(on: workspace, forceTile: true)
        XCTAssertTrue(window.parent === workspace.rootTilingContainer, "No zones -> should fall back to rootTilingContainer")
    }

    func testNewWindow_fallbackToMiddleZone_twoZoneLayout() async throws {
        config.zones.zones = [
            ZoneDefinition(id: "main", width: 0.6, layout: .tiles),
            ZoneDefinition(id: "secondary", width: 0.4, layout: .tiles),
        ]
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        XCTAssertNil(workspace.zoneContainers["center"])
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await window.relayoutWindow(on: workspace, forceTile: true)
        XCTAssertTrue(window.parent === workspace.zoneContainers["secondary"]!)
    }

    func testFloatingWindow_doesNotOccupyZone() {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let center = workspace.zoneContainers["center"]!
        let window = TestWindow.new(id: 1, parent: center)

        window.bindAsFloatingWindow(to: workspace)

        XCTAssertTrue(window.parent === workspace)
        XCTAssertFalse(center.children.contains { $0 === window })
        XCTAssertNotNil(workspace.zoneContainers["center"])
    }

    func testFloatingDefaults_areAppliedByRuntimePlacementPipeline() {
        config.floating.appIds = [TestApp.shared.rawAppBundleId.orDie()]

        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

        applyRuntimePlacementDefaults(window)

        XCTAssertTrue(window.parent === workspace, "[floating] should float matching apps without callback sugar")
    }

    func testAppRouting_routesNewWindowToConfiguredZone() {
        let appId = TestApp.shared.rawAppBundleId.orDie()
        config.zones.appRouting[appId] = "right"

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let decision = resolveNewTilingWindowPlacement(in: workspace, appBundleId: appId)

        XCTAssertTrue(decision.bindingData.parent === workspace.zoneContainers["right"]!)
        XCTAssertEqual(decision.source, .appRouting)
    }

    func testAppRouting_winsOverZoneMemory() {
        let appId = TestApp.shared.rawAppBundleId.orDie()
        config.zones.appRouting[appId] = "left"

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let profile = workspace.activeZoneProfile.orDie()
        let existing = TestWindow.new(id: 1, parent: workspace.zoneContainers["right"]!)
        ZoneMemory.shared.rememberZone("right", for: existing, profile: profile)

        let decision = resolveNewTilingWindowPlacement(in: workspace, appBundleId: appId)

        XCTAssertTrue(decision.bindingData.parent === workspace.zoneContainers["left"]!, "Explicit app routing should win over zone memory")
        XCTAssertEqual(decision.source, .appRouting)
    }

    func testAppRouting_missingZoneFallsBackToNormalPlacement() async throws {
        config.zones.zones = [
            ZoneDefinition(id: "main", width: 0.6, layout: .tiles),
            ZoneDefinition(id: "secondary", width: 0.4, layout: .tiles),
        ]
        config.zones.appRouting[TestApp.shared.rawAppBundleId.orDie()] = "right"

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let main = workspace.zoneContainers["main"]!
        _ = TestWindow.new(id: 1, parent: main)

        let newWindow = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await newWindow.relayoutWindow(on: workspace, forceTile: true)

        XCTAssertTrue(newWindow.parent === main, "Routes to missing zones should fall through to normal MRU placement")
    }

    func testAppRouting_noZonesFallsBackToRootPlacement() async throws {
        config.zones.appRouting[TestApp.shared.rawAppBundleId.orDie()] = "right"

        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

        try await window.relayoutWindow(on: workspace, forceTile: true)

        XCTAssertTrue(window.parent === workspace.rootTilingContainer, "App routing should be a no-op when zones are inactive")
    }

    func testNewWindow_appendPolicy_appendsToZoneRoot() async throws {
        config.zones.behavior["left"] = ZoneBehavior(newWindow: .append)

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let nested = TilingContainer.newVTiles(parent: left, adaptiveWeight: WEIGHT_AUTO)
        _ = TestWindow.new(id: 1, parent: nested)

        workspace.focusedZone = "left"
        let newWindow = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await newWindow.relayoutWindow(on: workspace, forceTile: true)

        XCTAssertTrue(newWindow.parent === left, "append policy should place the new window at the zone root")
    }

    func testNewWindow_afterFocusedPolicy_usesZoneLocalMruPlacement() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let nested = TilingContainer.newVTiles(parent: left, adaptiveWeight: WEIGHT_AUTO)
        let existing = TestWindow.new(id: 1, parent: nested)

        workspace.focusedZone = "left"
        let newWindow = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await newWindow.relayoutWindow(on: workspace, forceTile: true)

        XCTAssertTrue(newWindow.parent === nested, "after-focused policy should insert relative to the zone-local MRU window")
        XCTAssertEqual(newWindow.ownIndex, existing.ownIndex.orDie() + 1)
    }

    func testNewWindow_appendHiddenPolicy_preservesActiveStackChild() async throws {
        config.zones.zones = [
            ZoneDefinition(id: "left", width: 0.25, layout: .stack),
            ZoneDefinition(id: "center", width: 0.5, layout: .tiles),
            ZoneDefinition(id: "right", width: 0.25, layout: .tiles),
        ]
        config.zones.behavior["left"] = ZoneBehavior(newWindow: .appendHidden)

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let existing = TestWindow.new(id: 1, parent: left)

        workspace.focusedZone = "left"
        let newWindow = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await newWindow.relayoutWindow(on: workspace, forceTile: true)

        XCTAssertTrue(newWindow.parent === left, "append-hidden should still add the window to the target stack zone")
        XCTAssertTrue(left.mostRecentWindowRecursive === existing, "append-hidden should preserve the visible stack child")
    }

    func testNewWindow_staleFocusedZoneHint_isDroppedBeforeMruPlacement() async throws {
        config.zones.zones = [
            ZoneDefinition(id: "left", width: 0.25, layout: .tiles),
            ZoneDefinition(id: "center", width: 0.5, layout: .tiles),
            ZoneDefinition(id: "right", width: 0.25, layout: .tiles),
        ]

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        workspace.focusedZone = "left"

        config.zones.zones = [
            ZoneDefinition(id: "main", width: 0.6, layout: .tiles),
            ZoneDefinition(id: "secondary", width: 0.4, layout: .tiles),
        ]
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide, force: true)

        let main = workspace.zoneContainers["main"]!
        _ = TestWindow.new(id: 1, parent: main)

        let newWindow = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await newWindow.relayoutWindow(on: workspace, forceTile: true)

        XCTAssertEqual(workspace.focusedZone, "left")
        XCTAssertTrue(newWindow.parent === main, "Stale hints should not override MRU placement")
    }

    func testRememberedZoneFallback_reportsMiddleZoneSource() {
        config.zones.zones = [
            ZoneDefinition(id: "main", width: 0.6, layout: .tiles),
            ZoneDefinition(id: "secondary", width: 0.4, layout: .tiles),
        ]

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)

        let profile = workspace.activeZoneProfile.orDie()
        let window = TestWindow.new(id: 1, parent: workspace.zoneContainers["main"]!)
        ZoneMemory.shared.rememberZone("right", for: window, profile: profile)

        let decision = resolveNewTilingWindowPlacement(
            in: workspace,
            appBundleId: TestApp.shared.rawAppBundleId.orDie(),
        )

        XCTAssertEqual(decision.source, .middleZoneFallback)
        XCTAssertTrue(decision.bindingData.parent === workspace.zoneContainers["secondary"]!)
    }
}
