@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class ZoneMemoryCommandTest: XCTestCase {
    private var tempURL: URL!
    private var savedShared: ZoneMemory!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zone-memory-command-test-\(UUID().uuidString).json")
        savedShared = ZoneMemory.shared
        ZoneMemory.shared = ZoneMemory(storageURL: tempURL)
    }

    override func tearDown() async throws {
        ZoneMemory.shared = savedShared
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testParseZoneMemoryCommand() {
        testParseCommandSucc("zone-memory list", ZoneMemoryCmdArgs(rawArgs: ["list"].slice).copy(\.action, .initialized(.list)))
        testParseCommandSucc("zone-memory list --json", ZoneMemoryCmdArgs(rawArgs: ["list", "--json"].slice).copy(\.action, .initialized(.list)).copy(\.json, true))
        testParseCommandSucc("zone-memory list --count", ZoneMemoryCmdArgs(rawArgs: ["list", "--count"].slice).copy(\.action, .initialized(.list)).copy(\.outputOnlyCount, true))
        testParseCommandSucc(
            "zone-memory clear --app-id com.example.app",
            ZoneMemoryCmdArgs(rawArgs: ["clear", "--app-id", "com.example.app"].slice)
                .copy(\.action, .initialized(.clear))
                .copy(\.appId, "com.example.app"),
        )
        testParseCommandSucc("zone-memory clear --all", ZoneMemoryCmdArgs(rawArgs: ["clear", "--all"].slice).copy(\.action, .initialized(.clear)).copy(\.clearAll, true))

        assertEquals(parseCommand("zone-memory list --all").errorOrNil, "zone-memory list doesn't support --all or --app-id")
        assertEquals(parseCommand("zone-memory clear").errorOrNil, "zone-memory clear requires --app-id <app-bundle-id> or --all")
        assertEquals(parseCommand("zone-memory clear --count").errorOrNil, "zone-memory clear doesn't support --count or --json")
        assertEquals(parseCommand("zone-memory list --count --json").errorOrNil, "ERROR: Conflicting options: --count, --json")
    }

    func testZoneMemoryListOutputsPersistedEntries() async throws {
        let ultrawide = MonitorProfile([FakeMonitor.ultrawide])
        let standard = MonitorProfile([FakeMonitor.standard])
        ZoneMemory.shared.rememberZone("left", forBundleId: "com.example.mail", profile: ultrawide)
        ZoneMemory.shared.rememberZone("right", forBundleId: "com.example.chat", profile: ultrawide)
        ZoneMemory.shared.rememberZone("center", forBundleId: "com.example.mail", profile: standard)

        let result = try await ZoneMemoryCommand(args: ZoneMemoryCmdArgs(rawArgs: ["list"].slice).copy(\.action, .initialized(.list)))
            .run(.defaultEnv, .emptyStdin)

        let expected = [
            ["profile-key": standard.key, "app-id": "com.example.mail", "zone-id": "center"],
            ["profile-key": ultrawide.key, "app-id": "com.example.chat", "zone-id": "right"],
            ["profile-key": ultrawide.key, "app-id": "com.example.mail", "zone-id": "left"],
        ]
        assertEquals(result.exitCode.rawValue, 0)
        let decoded = try JSONDecoder().decode([[String: String]].self, from: Data(result.stdout.joined().utf8))
        XCTAssertEqual(decoded, expected)
        assertEquals(result.stderr, [])
    }

    func testZoneMemoryClearByAppIdRemovesEntriesAcrossProfiles() async throws {
        let ultrawide = MonitorProfile([FakeMonitor.ultrawide])
        let standard = MonitorProfile([FakeMonitor.standard])
        ZoneMemory.shared.rememberZone("left", forBundleId: "com.example.mail", profile: ultrawide)
        ZoneMemory.shared.rememberZone("center", forBundleId: "com.example.mail", profile: standard)
        ZoneMemory.shared.rememberZone("right", forBundleId: "com.example.chat", profile: ultrawide)

        let args = ZoneMemoryCmdArgs(rawArgs: ["clear", "--app-id", "com.example.mail"].slice)
            .copy(\.action, .initialized(.clear))
            .copy(\.appId, "com.example.mail")
        let result = try await ZoneMemoryCommand(args: args).run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stdout, ["2"])
        XCTAssertEqual(ZoneMemory.shared.entries(), [
            ZoneMemory.Entry(profileKey: ultrawide.key, appId: "com.example.chat", zoneName: "right"),
        ])
    }

    func testZoneMemoryClearAllRemovesEverything() async throws {
        let ultrawide = MonitorProfile([FakeMonitor.ultrawide])
        let standard = MonitorProfile([FakeMonitor.standard])
        ZoneMemory.shared.rememberZone("left", forBundleId: "com.example.mail", profile: ultrawide)
        ZoneMemory.shared.rememberZone("center", forBundleId: "com.example.mail", profile: standard)

        let result = try await ZoneMemoryCommand(args: ZoneMemoryCmdArgs(rawArgs: ["clear", "--all"].slice).copy(\.action, .initialized(.clear)).copy(\.clearAll, true))
            .run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stdout, ["2"])
        XCTAssertEqual(ZoneMemory.shared.entries(), [])
    }
}
