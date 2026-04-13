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
}
