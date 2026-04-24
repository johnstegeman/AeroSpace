@testable import AppBundle
import Common
import XCTest

@MainActor
final class MoveFloatingToZoneCommandTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        setTestMonitorsOverride([FakeMonitor.ultrawide])
    }

    private func assertRect(_ rect: Rect?, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rect?.topLeftX, x, file: file, line: line)
        XCTAssertEqual(rect?.topLeftY, y, file: file, line: line)
        XCTAssertEqual(rect?.width, width, file: file, line: line)
        XCTAssertEqual(rect?.height, height, file: file, line: line)
    }

    func testParse() {
        XCTAssertEqual((parseCommand("move-floating-to-zone left").cmdOrDie as? MoveFloatingToZoneCommand)?.args.zone.val, .left)
        XCTAssertEqual((parseCommand("move-floating-to-zone center").cmdOrDie as? MoveFloatingToZoneCommand)?.args.zone.val, .center)
        XCTAssertEqual((parseCommand("move-floating-to-zone right").cmdOrDie as? MoveFloatingToZoneCommand)?.args.zone.val, .right)
        XCTAssertNotNil(parseCommand("move-floating-to-zone").errorOrNil)
    }

    func testMoveFloatingWindowToZonePreservesRelativeOffset() async throws {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        workspace.zoneContainers["left"]?.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 800)
        workspace.zoneContainers["center"]?.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 300, topLeftY: 0, width: 400, height: 800)
        workspace.zoneContainers["right"]?.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 700, topLeftY: 0, width: 300, height: 800)

        let window = TestWindow.new(
            id: 1,
            parent: workspace,
            rect: Rect(topLeftX: 320, topLeftY: 40, width: 120, height: 100),
        )
        XCTAssertTrue(window.focusWindow())

        let command = parseCommand("move-floating-to-zone right").cmdOrDie as! MoveFloatingToZoneCommand
        let result = try await command.run(.defaultEnv, .emptyStdin)

        XCTAssertEqual(result.exitCode.rawValue, 0)
        assertRect(try await window.getAxRect(), x: 720, y: 40, width: 120, height: 100)

        let profile = MonitorProfile([workspace.workspaceMonitor])
        XCTAssertEqual(ZoneMemory.shared.rememberedZone(for: window, profile: profile), "right")
    }

    func testMoveFloatingToZoneConvertsTilingWindowToFloating() async throws {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        workspace.zoneContainers["left"]?.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 800)
        workspace.zoneContainers["center"]?.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 300, topLeftY: 0, width: 400, height: 800)
        workspace.zoneContainers["right"]?.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 700, topLeftY: 0, width: 300, height: 800)

        let window = TestWindow.new(
            id: 2,
            parent: workspace.zoneContainers["center"].orDie(),
            rect: Rect(topLeftX: 350, topLeftY: 60, width: 160, height: 120),
        )
        XCTAssertTrue(window.focusWindow())

        let command = parseCommand("move-floating-to-zone left").cmdOrDie as! MoveFloatingToZoneCommand
        let result = try await command.run(.defaultEnv, .emptyStdin)

        XCTAssertEqual(result.exitCode.rawValue, 0)
        XCTAssertTrue(window.parent === workspace)
        assertRect(try await window.getAxRect(), x: 50, y: 60, width: 160, height: 120)
    }

    func testMoveFloatingToZoneUsesTheoreticalRectAndClampsInsideTargetZone() async throws {
        setTestMonitorsOverride([FakeMonitor.ultrawide])
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        workspace.zoneContainers.values.forEach { $0.lastAppliedLayoutPhysicalRect = nil }
        workspace.zoneContainers["left"]?.setWeight(.h, 1)
        workspace.zoneContainers["center"]?.setWeight(.h, 1)
        workspace.zoneContainers["right"]?.setWeight(.h, 1)

        let window = TestWindow.new(
            id: 3,
            parent: workspace,
            rect: Rect(topLeftX: 1500, topLeftY: 30, width: 900, height: 300),
        )
        XCTAssertTrue(window.focusWindow())

        let command = parseCommand("move-floating-to-zone left").cmdOrDie as! MoveFloatingToZoneCommand
        let result = try await command.run(.defaultEnv, .emptyStdin)

        XCTAssertEqual(result.exitCode.rawValue, 0)
        let rect = try await window.getAxRect()
        XCTAssertNotNil(rect)
        XCTAssertEqual(rect!.topLeftX, 246.66666666666663, accuracy: 0.0001)
        XCTAssertEqual(rect!.topLeftY, 30)
        XCTAssertEqual(rect!.width, 900)
        XCTAssertEqual(rect!.height, 300)
    }
}
