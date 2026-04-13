@testable import AppBundle
import Foundation
import XCTest

@MainActor
final class ZoneMemoryTests: XCTestCase {
    private var tempURL: URL!
    private var savedShared: ZoneMemory!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zone-memory-test-\(UUID().uuidString).json")
        savedShared = ZoneMemory.shared
        ZoneMemory.shared = ZoneMemory(storageURL: tempURL)
    }

    override func tearDown() async throws {
        ZoneMemory.shared = savedShared
        try? FileManager.default.removeItem(at: tempURL)
    }

    // MARK: - MonitorProfile fingerprint

    func testMonitorProfile_sameLayout_sameKey() {
        let p1 = MonitorProfile([AnyMonitor(width: 3440, height: 1440)])
        let p2 = MonitorProfile([AnyMonitor(width: 3440, height: 1440)])
        XCTAssertEqual(p1.key, p2.key)
    }

    func testMonitorProfile_differentResolution_differentKey() {
        let p1 = MonitorProfile([AnyMonitor(width: 3440, height: 1440)])
        let p2 = MonitorProfile([AnyMonitor(width: 2560, height: 1440)])
        XCTAssertNotEqual(p1.key, p2.key)
    }

    func testMonitorProfile_multiMonitor_sortedByOrigin() {
        let left  = AnyMonitor(width: 1920, height: 1080, originX: 0,    originY: 0)
        let right = AnyMonitor(width: 1920, height: 1080, originX: 1920, originY: 0)
        let p1 = MonitorProfile([left, right])
        let p2 = MonitorProfile([right, left]) // reversed input order
        XCTAssertEqual(p1.key, p2.key, "Profile key must be stable regardless of input order")
    }

    // MARK: - ZoneMemory record/lookup

    func testRememberAndRecall() {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 1, parent: workspace.zoneContainers["left"]!)
        let profile = MonitorProfile([AnyMonitor(width: 3440, height: 1440)])
        ZoneMemory.shared.rememberZone("left", for: window, profile: profile)
        XCTAssertEqual(ZoneMemory.shared.rememberedZone(for: window, profile: profile), "left")
    }

    func testUnknownWindow_returnsNil() {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 99, parent: workspace.zoneContainers["center"]!)
        let profile = MonitorProfile([AnyMonitor(width: 3440, height: 1440)])
        XCTAssertNil(ZoneMemory.shared.rememberedZone(for: window, profile: profile))
    }

    func testDifferentProfile_noMatch() {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 1, parent: workspace.zoneContainers["right"]!)
        let profileA = MonitorProfile([AnyMonitor(width: 3440, height: 1440)])
        let profileB = MonitorProfile([AnyMonitor(width: 2560, height: 1440)])
        ZoneMemory.shared.rememberZone("right", for: window, profile: profileA)
        XCTAssertNil(ZoneMemory.shared.rememberedZone(for: window, profile: profileB))
    }

    // MARK: - Persistence

    func testPersistAndReload() {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 1, parent: workspace.zoneContainers["right"]!)
        let profile = MonitorProfile([AnyMonitor(width: 3440, height: 1440)])
        ZoneMemory.shared.rememberZone("right", for: window, profile: profile)

        let reloaded = ZoneMemory(storageURL: tempURL)
        XCTAssertEqual(reloaded.rememberedZone(for: window, profile: profile), "right")
    }

    func testCorruptJson_silentlyResetsToEmpty() {
        try! "not json at all".data(using: .utf8)!.write(to: tempURL)
        let memory = ZoneMemory(storageURL: tempURL)
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 1, parent: workspace.zoneContainers["center"]!)
        let profile = MonitorProfile([AnyMonitor(width: 3440, height: 1440)])
        XCTAssertNil(memory.rememberedZone(for: window, profile: profile))
    }

    func testMissingFile_treatsAsEmpty() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        let memory = ZoneMemory(storageURL: missingURL)
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 1, parent: workspace.zoneContainers["center"]!)
        XCTAssertNil(memory.rememberedZone(for: window, profile: MonitorProfile([AnyMonitor(width: 3440, height: 1440)])))
    }

    // MARK: - Restore on zone activation

    /// Simulate a monitor reconnect: zones activate and windows are moved to their remembered zones.
    func testRestoreZoneMemory_windowMovedToRememberedZone() {
        let workspace = Workspace.get(byName: name)

        // Activate zones and put a window in the right zone
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 1, parent: workspace.zoneContainers["right"]!)

        // Record the assignment using the same profile that `activateZones` will use
        // (activateZones calls MonitorProfile(monitors); in tests, monitors = [testMonitor 1920×1080])
        let testProfile = MonitorProfile(monitors)
        ZoneMemory.shared.rememberZone("right", for: window, profile: testProfile)

        // Deactivate zones (simulate monitor disconnect) – window lands in rootTilingContainer
        workspace.ensureZoneContainers(for: FakeMonitor.standard)
        XCTAssertTrue(workspace.zoneContainers.isEmpty)
        XCTAssertTrue(workspace.rootTilingContainer.children.contains { $0 === window })

        // Re-activate zones (simulate reconnect) – restoreZoneMemory should fire
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)

        XCTAssertFalse(workspace.zoneContainers.isEmpty)
        let rightZone = workspace.zoneContainers["right"]!
        XCTAssertTrue(rightZone.children.contains { $0 === window },
                      "Window should be restored to right zone on reconnect")
    }
}

// MARK: - AnyMonitor

/// A test monitor with configurable origin, unlike FakeMonitor which is always at (0,0).
private struct AnyMonitor: Monitor {
    let monitorAppKitNsScreenScreensId: Int = 1
    let name: String = "AnyMonitor"
    let rect: Rect
    var visibleRect: Rect { rect }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    let isMain: Bool = false

    init(width: CGFloat, height: CGFloat, originX: CGFloat = 0, originY: CGFloat = 0) {
        rect = Rect(topLeftX: originX, topLeftY: originY, width: width, height: height)
    }
}
