@testable import AppBundle
import Common
import Foundation
import XCTest

final class ZoneCommandTest: XCTestCase {
    private func decodeObject(_ json: String) throws -> [String: AnyHashable] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: AnyHashable])
    }

    func testParseZoneCommand() {
        testParseCommandSucc("zone --json", ZoneCmdArgs(rawArgs: []).copy(\.json, true))
        assertEquals(parseCommand("zone").errorOrNil, "--json is required")
    }

    @MainActor
    func testZoneCommandFailsWithoutZones() async throws {
        setUpWorkspacesForTests()

        let result = try await ZoneCommand(args: ZoneCmdArgs(rawArgs: []).copy(\.json, true)).run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stdout, [])
        assertEquals(result.stderr, ["zone: zones not active on this workspace"])
    }

    @MainActor
    func testZoneCommandJsonOutput() async throws {
        setUpWorkspacesForTests()
        setTestMonitorsOverride([FakeMonitor.ultrawide])
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)

        _ = TestWindow.new(id: 1, parent: workspace.zoneContainers["left"].orDie())
        let focusedWindow = TestWindow.new(id: 2, parent: workspace.zoneContainers["center"].orDie())
        assertTrue(focusedWindow.focusWindow())

        let result = try await ZoneCommand(args: ZoneCmdArgs(rawArgs: []).copy(\.json, true)).run(.defaultEnv, .emptyStdin)
        let decoded = try decodeObject(result.stdout.joined())

        assertEquals(result.exitCode.rawValue, 0)
        XCTAssertEqual(decoded["workspace"], workspace.name)
        XCTAssertEqual(decoded["monitor-id"], workspace.workspaceMonitor.monitorId_oneBased)
        XCTAssertEqual(decoded["monitor-name"], workspace.workspaceMonitor.name)
        XCTAssertEqual(decoded["zone-id"], "center")
        XCTAssertEqual(decoded["layout"], "h_tiles")
        XCTAssertEqual(decoded["is-focused"], true)
        XCTAssertEqual(decoded["window-count"], 1)
        assertEquals(result.stderr, [])
    }
}
