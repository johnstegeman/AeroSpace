@testable import AppBundle
import Foundation
import XCTest

@MainActor
final class ZoneMemoryTests: XCTestCase {
    private var tempURL: URL!
    private var savedShared: ZoneMemory!
    private var saveCount: Int!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zone-memory-test-\(UUID().uuidString).json")
        savedShared = ZoneMemory.shared
        saveCount = 0
        ZoneMemory.shared = ZoneMemory(storageURL: tempURL, onSave: { [weak self] in
            self?.saveCount += 1
        })
    }

    override func tearDown() async throws {
        ZoneMemory.shared = savedShared
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testRestoreZoneMemory_respectsInsertionPolicy() {
        config.zones.behavior["right"] = ZoneBehavior(newWindow: .afterFocused)

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let right = workspace.zoneContainers["right"]!
        let existing = TestWindow.new(id: 1, parent: right)
        let window = TestWindow.new(id: 2, parent: right)

        let profile = MonitorProfile(monitors)
        ZoneMemory.shared.rememberZone("right", for: existing, profile: profile)
        ZoneMemory.shared.rememberZone("right", for: window, profile: profile)

        workspace.ensureZoneContainers(for: FakeMonitor.standard)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)

        let restoredRight = workspace.zoneContainers["right"]!
        XCTAssertTrue(window.parent === restoredRight, "Zone-memory restore should rebind into the destination zone")
        XCTAssertEqual(window.ownIndex, existing.ownIndex.orDie() + 1)
    }

    func testBatchUpdateSavesOnce() {
        let profile = MonitorProfile(monitors)

        ZoneMemory.shared.withBatchUpdate {
            ZoneMemory.shared.rememberZone("left", forBundleId: "com.example.one", profile: profile)
            ZoneMemory.shared.rememberZone("right", forBundleId: "com.example.two", profile: profile)
        }

        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(ZoneMemory.shared.entries().count, 2)
    }
}
