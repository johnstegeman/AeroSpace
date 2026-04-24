@testable import AppBundle
import Common
import XCTest

@MainActor
final class ZoneSubscriptionEventTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func normalizeJson(_ json: String) -> String {
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func testRestoreZoneMemoryBroadcastsWindowRoutedEvent() async {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 1, parent: workspace.zoneContainers["right"].orDie())
        let profile = MonitorProfile([workspace.workspaceMonitor])
        ZoneMemory.shared.rememberZone("right", for: window, profile: profile)

        workspace.ensureZoneContainers(for: FakeMonitor.standard)

        var captured: [String] = []
        broadcastEventForTesting = { event in
            captured.append(JSONEncoder.aeroSpaceDefault.encodeToString(event).orDie())
        }

        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        await Task.yield()

        let routedEvents = captured
            .map(normalizeJson)
            .filter { $0.contains(#""_event":"window-routed""#) }
        assertEquals(routedEvents, [
            #"{"_event":"window-routed","appBundleId":"bobko.AeroSpace.test-app","source":"zoneMemory","windowId":1,"workspace":"setUpWorkspacesForTests","zoneName":"right"}"#,
        ])
    }
}
