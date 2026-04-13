@testable import AppBundle
import XCTest

@MainActor
final class ZoneContainerNormalizationTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testNormalizationSurvivesEmptyZone() {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        let left = TilingContainer.newHTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 1)
        left.isZoneContainer = true
        let center = TilingContainer.newHTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 1)
        center.isZoneContainer = true
        let right = TilingContainer.newHTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 1)
        right.isZoneContainer = true
        // All zones empty — normalizeContainers must not remove them
        workspace.normalizeContainers()
        XCTAssertEqual(workspace.rootTilingContainer.children.count, 3)
        XCTAssertTrue(workspace.rootTilingContainer.children.contains { $0 === left })
        XCTAssertTrue(workspace.rootTilingContainer.children.contains { $0 === center })
        XCTAssertTrue(workspace.rootTilingContainer.children.contains { $0 === right })
    }

    func testNormalizationSurvivesSingleWindow() {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        let left = TilingContainer.newHTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 1)
        left.isZoneContainer = true
        TestWindow.new(id: 1, parent: left)
        let center = TilingContainer.newHTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 1)
        center.isZoneContainer = true
        let right = TilingContainer.newHTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 1)
        right.isZoneContainer = true
        // left has exactly 1 window — must NOT be flattened up
        workspace.normalizeContainers()
        XCTAssertEqual(workspace.rootTilingContainer.children.count, 3)
        XCTAssertTrue(workspace.rootTilingContainer.children.contains { $0 === left })
        XCTAssertEqual(left.children.count, 1)
        XCTAssertTrue(left.children.first is TestWindow)
    }
}
