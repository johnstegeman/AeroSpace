@testable import AppBundle
import Common
import XCTest

private struct FakeMonitor: Monitor {
    let monitorAppKitNsScreenScreensId: Int = 1
    let name: String = "Fake"
    let rect: Rect
    let visibleRect: Rect
    let width: CGFloat
    let height: CGFloat
    let isMain: Bool = false

    init(width: CGFloat, height: CGFloat) {
        let r = Rect(topLeftX: 0, topLeftY: 0, width: width, height: height)
        self.rect = r
        self.visibleRect = r
        self.width = width
        self.height = height
    }

    static var ultrawide: FakeMonitor { FakeMonitor(width: 3440, height: 1440) }
    static var standard: FakeMonitor { FakeMonitor(width: 1920, height: 1080) }
}

@MainActor
final class ZoneEnsureContainersTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testEnsureZoneContainers_split() {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        XCTAssertEqual(workspace.rootTilingContainer.children.count, 3)
        XCTAssertNotNil(workspace.zoneContainers["left"])
        XCTAssertNotNil(workspace.zoneContainers["center"])
        XCTAssertNotNil(workspace.zoneContainers["right"])
        XCTAssertTrue(workspace.zoneContainers["left"]!.isZoneContainer)
        XCTAssertTrue(workspace.zoneContainers["center"]!.isZoneContainer)
        XCTAssertTrue(workspace.zoneContainers["right"]!.isZoneContainer)
        XCTAssertEqual(workspace.rootTilingContainer.orientation, .h)
    }

    func testEnsureZoneContainers_noOp_alreadyHasZones() {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let leftBefore = workspace.zoneContainers["left"]
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        XCTAssertTrue(workspace.zoneContainers["left"] === leftBefore, "Should be same container ref (no-op)")
        XCTAssertEqual(workspace.rootTilingContainer.children.count, 3)
    }

    func testEnsureZoneContainers_flatten() {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let center = workspace.zoneContainers["center"]!
        TestWindow.new(id: 1, parent: left)
        TestWindow.new(id: 2, parent: center)
        TestWindow.new(id: 3, parent: center)
        workspace.ensureZoneContainers(for: FakeMonitor.standard)
        XCTAssertTrue(workspace.zoneContainers.isEmpty)
        // All windows re-parented to root; zone containers removed
        let rootChildren = workspace.rootTilingContainer.children
        XCTAssertEqual(rootChildren.count, 3)
        XCTAssertFalse(rootChildren.contains { $0 is TilingContainer })
        // Windows appear in left→center→right order
        XCTAssertEqual((rootChildren[0] as? TestWindow)?.windowId, 1)
        XCTAssertEqual((rootChildren[1] as? TestWindow)?.windowId, 2)
        XCTAssertEqual((rootChildren[2] as? TestWindow)?.windowId, 3)
    }

    func testEnsureZoneContainers_flattenNoOp_noZones() {
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        workspace.ensureZoneContainers(for: FakeMonitor.standard)
        XCTAssertTrue(workspace.zoneContainers.isEmpty)
        XCTAssertEqual(workspace.rootTilingContainer.children.count, 1)
    }

    func testEnsureZoneContainers_orientation_forcedHorizontal() {
        config.defaultRootContainerOrientation = .vertical
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        XCTAssertEqual(workspace.rootTilingContainer.orientation, .h)
    }
}
