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

    func testFloatingWindow_doesNotOccupyZone() async throws {
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
