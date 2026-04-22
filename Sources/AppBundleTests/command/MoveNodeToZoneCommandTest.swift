@testable import AppBundle
import Common
import XCTest

@MainActor
final class MoveNodeToZoneCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        testParseCommandSucc("move-node-to-zone left", MoveNodeToZoneCmdArgs(rawArgs: [], "left"))
        testParseCommandSucc("move-node-to-zone center", MoveNodeToZoneCmdArgs(rawArgs: [], "center"))
        testParseCommandSucc("move-node-to-zone right", MoveNodeToZoneCmdArgs(rawArgs: [], "right"))
        // Any zone name is accepted at parse time; validation against active zones happens at run time.
        testParseCommandSucc("move-node-to-zone foo", MoveNodeToZoneCmdArgs(rawArgs: [], "foo"))
        XCTAssertNotNil(parseCommand("move-node-to-zone").errorOrNil)
    }

    func testMoveToZone_basic() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let center = workspace.zoneContainers["center"]!
        let window = TestWindow.new(id: 1, parent: center)
        _ = window.focusWindow()
        assertEquals(workspace.focusWorkspace(), true)

        try await MoveNodeToZoneCommand(args: MoveNodeToZoneCmdArgs(rawArgs: [], "left")).run(.defaultEnv, .emptyStdin)

        XCTAssertTrue(window.parent === left, "Window should be in left zone")
    }

    func testMoveToZone_noZones() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        _ = window.focusWindow()
        assertEquals(workspace.focusWorkspace(), true)

        let io = CmdIo(stdin: .emptyStdin)
        let result = try await MoveNodeToZoneCommand(args: MoveNodeToZoneCmdArgs(rawArgs: [], "center")).run(.defaultEnv, io)

        XCTAssertEqual(result, .fail, "Should fail when zones not active")
        XCTAssertTrue(io.stderr.joined().contains("zones not active"), "Should report error to stderr")
    }
}
