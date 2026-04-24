@testable import AppBundle
import Common
import XCTest

@MainActor
final class ZoneNewWindowPlacementTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

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
}
