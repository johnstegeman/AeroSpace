@testable import AppBundle
import XCTest

@MainActor
final class TrayMenuModelTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testUpdateTrayTextShowsFocusedZoneInStatusBar() {
        let workspace = focus.workspace
        setTestMonitorsOverride([FakeMonitor.ultrawide])
        assertTrue(mainMonitor.setActiveWorkspace(workspace))
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)

        let centerWindow = TestWindow.new(id: 1, parent: workspace.zoneContainers["center"].orDie())
        assertTrue(centerWindow.focusWindow())

        updateTrayText()

        XCTAssertEqual(TrayMenuModel.shared.trayText, "setUpWorkspacesForTests : left [center] right")
        XCTAssertEqual(
            TrayMenuModel.shared.trayItems.map(\.type),
            [.workspace, .zone, .zone, .zone],
        )
        XCTAssertEqual(
            TrayMenuModel.shared.trayItems.filter { $0.type == .zone }.map(\.name),
            ["left", "center", "right"],
        )
        XCTAssertEqual(
            TrayMenuModel.shared.trayItems.filter { $0.type == .zone }.map(\.isActive),
            [false, true, false],
        )
    }

    func testUpdateTrayTextUsesFocusedZoneHintWhenWorkspaceIsEmpty() {
        let workspace = focus.workspace
        setTestMonitorsOverride([FakeMonitor.ultrawide])
        assertTrue(mainMonitor.setActiveWorkspace(workspace))
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        workspace.focusedZone = "left"

        updateTrayText()

        XCTAssertEqual(TrayMenuModel.shared.trayText, "setUpWorkspacesForTests : [left] center right")
        XCTAssertEqual(
            TrayMenuModel.shared.trayItems.filter { $0.type == .zone }.map(\.isActive),
            [true, false, false],
        )
    }
}
