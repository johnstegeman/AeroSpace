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
        XCTAssertTrue(window.parent === workspace.zoneContainers["center"], "No MRU window → should land in center zone")
    }

    func testNewWindow_followsMruZone() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let windowA = TestWindow.new(id: 1, parent: left)
        let windowB = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await windowB.relayoutWindow(on: workspace, forceTile: true)
        XCTAssertTrue(windowA.parent === left, "Existing window should stay in left zone")
        XCTAssertTrue(windowB.parent === left, "New window should follow MRU zone (left)")
    }

    func testNewWindow_fallbackToRoot_whenNoZones() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await window.relayoutWindow(on: workspace, forceTile: true)
        XCTAssertTrue(window.parent === workspace.rootTilingContainer, "No zones → should fall back to rootTilingContainer")
    }

    /// With a 2-zone layout (no "center"), a new window with no MRU should fall back to
    /// defs[count/2] — the second zone — rather than rootTilingContainer.
    func testNewWindow_fallbackToMiddleZone_twoZoneLayout() async throws {
        config.zones.zones = [
            ZoneDefinition(id: "main",      width: 0.6, layout: .tiles),
            ZoneDefinition(id: "secondary", width: 0.4, layout: .tiles),
        ]
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        XCTAssertNil(workspace.zoneContainers["center"], "2-zone layout must not have a center zone")
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await window.relayoutWindow(on: workspace, forceTile: true)
        let secondary = workspace.zoneContainers["secondary"]!
        XCTAssertTrue(window.parent === secondary, "No MRU + no center → should land in defs[count/2] = secondary zone")
    }

    func testFloatingWindow_doesNotOccupyZone() {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let center = workspace.zoneContainers["center"]!

        // Window starts in center zone (simulates tiling placement before float rule fires)
        let window = TestWindow.new(id: 1, parent: center)
        XCTAssertTrue(window.parent === center)

        // Float rule fires (on-window-detected runs 'layout floating')
        window.bindAsFloatingWindow(to: workspace)

        // Window is now a direct child of workspace (floating), not inside any zone
        XCTAssertTrue(window.parent === workspace, "Floating window should be direct workspace child")
        XCTAssertFalse(center.children.contains { $0 === window }, "Center zone should no longer contain the window")
        // Zone containers survive even though one is now empty
        XCTAssertNotNil(workspace.zoneContainers["center"], "Empty zone should still exist after window floated away")
    }
}
