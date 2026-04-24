@testable import AppBundle
import Common
import XCTest

@MainActor
final class MoveNodeToZoneCommandTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        setTestMonitorsOverride([FakeMonitor.ultrawide])
        XCTAssertTrue(mainMonitor.setActiveWorkspace(focus.workspace))
    }

    func testParse() {
        XCTAssertEqual((parseCommand("move-node-to-zone left").cmdOrDie as? MoveNodeToZoneCommand)?.args.zone.val, "left")
        XCTAssertEqual((parseCommand("move-node-to-zone center").cmdOrDie as? MoveNodeToZoneCommand)?.args.zone.val, "center")
        XCTAssertEqual((parseCommand("move-node-to-zone right").cmdOrDie as? MoveNodeToZoneCommand)?.args.zone.val, "right")
        XCTAssertEqual((parseCommand("move-node-to-zone foo").cmdOrDie as? MoveNodeToZoneCommand)?.args.zone.val, "foo")
        XCTAssertNotNil(parseCommand("move-node-to-zone").errorOrNil)
    }

    func testMoveToZone_respectsInsertionPolicy() async throws {
        config.zones.behavior["left"] = ZoneBehavior(newWindow: .afterFocused)

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let nested = TilingContainer.newVTiles(parent: left, adaptiveWeight: WEIGHT_AUTO)
        let existing = TestWindow.new(id: 1, parent: nested)
        let moved = TestWindow.new(id: 2, parent: workspace.zoneContainers["center"]!)
        _ = existing.focusWindow()
        _ = moved.focusWindow()

        let command = parseCommand("move-node-to-zone left").cmdOrDie as! MoveNodeToZoneCommand
        _ = try await command.run(.defaultEnv, .emptyStdin)

        XCTAssertTrue(moved.parent === nested, "Manual move should use the destination zone's insertion policy")
        XCTAssertEqual(moved.ownIndex, existing.ownIndex.orDie() + 1)
    }

    func testMoveToSameZone_afterFocused_doesNotCrashOnLastChild() async throws {
        config.zones.behavior["left"] = ZoneBehavior(newWindow: .afterFocused)

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let nested = TilingContainer.newVTiles(parent: left, adaptiveWeight: WEIGHT_AUTO)
        let existing = TestWindow.new(id: 1, parent: nested)
        let moved = TestWindow.new(id: 2, parent: nested)
        _ = existing.focusWindow()
        _ = moved.focusWindow()

        let command = parseCommand("move-node-to-zone left").cmdOrDie as! MoveNodeToZoneCommand
        _ = try await command.run(.defaultEnv, .emptyStdin)

        XCTAssertTrue(moved.parent === nested, "Moving into the current zone should keep the window in the same insertion parent")
        XCTAssertEqual(moved.ownIndex, 1, "Reapplying after-focused placement in the same parent should not shift the last child out of range")
    }
}
