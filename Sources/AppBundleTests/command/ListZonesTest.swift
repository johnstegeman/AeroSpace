@testable import AppBundle
import Common
import Foundation
import XCTest

final class ListZonesTest: XCTestCase {
    private func decodeArray(_ json: String) throws -> [[String: AnyHashable]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: AnyHashable]])
    }

    func testParseListZonesCommand() {
        testParseCommandSucc("list-zones", ListZonesCmdArgs(rawArgs: []))
        testParseCommandSucc("list-zones --json", ListZonesCmdArgs(rawArgs: []).copy(\.json, true))
        testParseCommandSucc("list-zones --count", ListZonesCmdArgs(rawArgs: []).copy(\.outputOnlyCount, true))
        assertEquals(parseCommand("list-zones --count --json").errorOrNil, "ERROR: Conflicting options: --count, --json")
    }

    @MainActor
    func testListZonesOutputWithoutZones() async throws {
        setUpWorkspacesForTests()

        let result = try await ListZonesCommand(args: ListZonesCmdArgs(rawArgs: [])).run(.defaultEnv, .emptyStdin)
        let decoded = try decodeArray(result.stdout.joined())
        assertEquals(result.exitCode.rawValue, 0)
        XCTAssertEqual(decoded, [])
        assertEquals(result.stderr, [])
    }

    @MainActor
    func testListZonesOutputWithZones() async throws {
        setUpWorkspacesForTests()
        setTestMonitorsOverride([FakeMonitor.ultrawide])
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)

        let left = workspace.zoneContainers["left"].orDie()
        let center = workspace.zoneContainers["center"].orDie()
        _ = TestWindow.new(id: 1, parent: left)
        let focusedWindow = TestWindow.new(id: 2, parent: center)
        assertTrue(focusedWindow.focusWindow())

        let result = try await ListZonesCommand(args: ListZonesCmdArgs(rawArgs: [])).run(.defaultEnv, .emptyStdin)
        let decoded = try decodeArray(result.stdout.joined())

        assertEquals(result.exitCode.rawValue, 0)
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0]["zone-id"], "left")
        XCTAssertEqual(decoded[0]["is-focused"], false)
        XCTAssertEqual(decoded[0]["window-count"], 1)
        XCTAssertEqual(decoded[1]["zone-id"], "center")
        XCTAssertEqual(decoded[1]["is-focused"], true)
        XCTAssertEqual(decoded[1]["window-count"], 1)
        XCTAssertEqual(decoded[2]["zone-id"], "right")
        XCTAssertEqual(decoded[2]["window-count"], 0)
        assertEquals(result.stderr, [])

        let countResult = try await ListZonesCommand(args: ListZonesCmdArgs(rawArgs: []).copy(\.outputOnlyCount, true)).run(.defaultEnv, .emptyStdin)
        assertEquals(countResult.exitCode.rawValue, 0)
        assertEquals(countResult.stdout, ["3"])
        assertEquals(countResult.stderr, [])
    }
}
