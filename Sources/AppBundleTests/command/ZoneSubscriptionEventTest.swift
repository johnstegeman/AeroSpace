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

    func testFocusZoneOnEmptyZoneBroadcastsZoneFocusedEvent() async throws {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)

        let center = workspace.zoneContainers["center"].orDie()
        let focusedWindow = TestWindow.new(id: 1, parent: center)
        assertTrue(focusedWindow.focusWindow())

        var captured: [String] = []
        broadcastEventForTesting = { event in
            captured.append(JSONEncoder.aeroSpaceDefault.encodeToString(event).orDie())
        }

        let args = parseCmdArgs(["focus-zone", "left"].slice).cmdOrDie as! FocusZoneCmdArgs
        let result = try await FocusZoneCommand(args: args).run(.defaultEnv, .emptyStdin)
        await Task.yield()

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(captured.map(normalizeJson), [#"{"_event":"zone-focused","workspace":"setUpWorkspacesForTests","zoneName":"left"}"#])
    }

    func testZonePresetBroadcastsZonePresetChangedEvent() async throws {
        config.zonePresets["balanced"] = ZonePreset(name: "balanced", widths: [25, 50, 25], layouts: [.tiles, .tiles, .tiles])
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)

        var captured: [String] = []
        broadcastEventForTesting = { event in
            captured.append(JSONEncoder.aeroSpaceDefault.encodeToString(event).orDie())
        }

        let result = try await ZonePresetCommand(args: ZonePresetCmdArgs(rawArgs: ["balanced"]).copy(\.presetName, "balanced")).run(.defaultEnv, .emptyStdin)
        await Task.yield()

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(captured.map(normalizeJson), [#"{"_event":"zone-preset-changed","presetName":"balanced","workspace":"setUpWorkspacesForTests"}"#])
    }
}
