@testable import AppBundle
import Common
import XCTest

@MainActor
final class ListWindowsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        assertEquals(parseCommand("list-windows --pid 1").errorOrNil, "Mandatory option is not specified (--focused|--all|--monitor|--workspace)")
        assertNil(parseCommand("list-windows --workspace M --pid 1").errorOrNil)
        assertEquals(parseCommand("list-windows --pid 1 --focused").errorOrNil, "--focused conflicts with other \"filtering\" flags")
        assertEquals(parseCommand("list-windows --pid 1 --all").errorOrNil, "--all conflicts with \"filtering\" flags. Please use '--monitor all' instead of '--all' alias")
        assertNil(parseCommand("list-windows --all").errorOrNil)
        assertEquals(parseCommand("list-windows --all --workspace M").errorOrNil, "ERROR: Conflicting options: --all, --workspace")
        assertEquals(parseCommand("list-windows --all --focused").errorOrNil, "ERROR: Conflicting options: --all, --focused")
        assertEquals(parseCommand("list-windows --all --count --format %{window-title}").errorOrNil, "ERROR: Conflicting options: --count, --format")
        assertEquals(
            parseCommand("list-windows --all --focused --monitor mouse").errorOrNil,
            "ERROR: Conflicting options: --all, --focused")
        assertEquals(
            parseCommand("list-windows --all --focused --monitor mouse --workspace focused").errorOrNil,
            "ERROR: Conflicting options: --all, --focused, --workspace")
        assertEquals(
            parseCommand("list-windows --all --workspace focused").errorOrNil,
            "ERROR: Conflicting options: --all, --workspace")
        assertNil(parseCommand("list-windows --monitor mouse").errorOrNil)

        // --json
        assertEquals(parseCommand("list-windows --all --count --json").errorOrNil, "ERROR: Conflicting options: --count, --json")
        assertEquals(parseCommand("list-windows --all --format '%{right-padding}' --json").errorOrNil, "%{right-padding} interpolation variable is not allowed when --json is used")
        assertEquals(parseCommand("list-windows --all --format '%{window-title} |' --json").errorOrNil, "Only interpolation variables and spaces are allowed in \'--format\' when \'--json\' is used")
        assertNil(parseCommand("list-windows --all --format '%{window-title}' --json").errorOrNil)
        assertNil(parseCommand("list-windows --all --format '%{zone-layout}'").errorOrNil)
        assertNil(parseCommand("list-windows --all --format '%{window-zone}' --json").errorOrNil)
    }

    func testInterpolationVariablesConsistency() {
        for kind in AeroObjKind.allCases {
            switch kind {
                case .window:
                    assertTrue(FormatVar.WindowFormatVar.allCases.allSatisfy { $0.rawValue.starts(with: "window-") })
                case .app:
                    assertTrue(FormatVar.AppFormatVar.allCases.allSatisfy { $0.rawValue.starts(with: "app-") })
                case .workspace:
                    assertTrue(FormatVar.WorkspaceFormatVar.allCases.allSatisfy {
                        $0.rawValue.starts(with: "workspace") || $0.rawValue.starts(with: "zone")
                    })
                case .monitor:
                    assertTrue(FormatVar.MonitorFormatVar.allCases.allSatisfy { $0.rawValue.starts(with: "monitor-") })
            }
        }
    }

    func testFormat() {
        Workspace.get(byName: name).rootTilingContainer.apply {
            let windows = [
                AeroObj.window(.forTest(window: TestWindow.new(id: 2, parent: $0), title: "non-empty")),
                AeroObj.window(.forTest(window: TestWindow.new(id: 1, parent: $0), title: "")),
            ]
            assertEquals(windows.format([.interVar("window-title")]), .success(["non-empty", ""]))
        }

        Workspace.get(byName: name).rootTilingContainer.apply {
            let windows = [
                AeroObj.window(.forTest(window: TestWindow.new(id: 2, parent: $0), title: "non-empty")),
                AeroObj.window(.forTest(window: TestWindow.new(id: 10, parent: $0), title: "")),
            ]
            assertEquals(windows.format([.interVar("window-id"), .interVar("right-padding"), .interVar("window-title")]), .success(["2 non-empty", "10"]))
        }

        Workspace.get(byName: name).rootTilingContainer.apply {
            let windows = [
                AeroObj.window(.forTest(window: TestWindow.new(id: 2, parent: $0), title: "title1")),
                AeroObj.window(.forTest(window: TestWindow.new(id: 10, parent: $0), title: "title2")),
            ]
            assertEquals(windows.format([.interVar("window-id"), .interVar("right-padding"), .literal(" | "), .interVar("window-title")]), .success(["2  | title1", "10 | title2"]))
        }

        let workspace = Workspace.get(byName: "zones")
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let center = workspace.zoneContainers["center"].orDie()
        _ = TestWindow.new(id: 20, parent: workspace.zoneContainers["left"].orDie())
        let focusedWindow = TestWindow.new(id: 21, parent: center)
        assertTrue(focusedWindow.focusWindow())

        assertEquals([AeroObj.workspace(workspace)].format([
            .interVar("zone"),
            .literal(" "),
            .interVar("zone-layout"),
            .literal(" "),
            .interVar("zone-window-count"),
        ]), .success(["center h_tiles 1"]))

        let emptyWorkspace = Workspace.get(byName: "empty")
        assertEquals([AeroObj.workspace(emptyWorkspace)].format([
            .interVar("zone"),
            .literal(" "),
            .interVar("zone-layout"),
            .literal(" "),
            .interVar("zone-window-count"),
        ]), .success(["NULL-ZONE NULL-ZONE-LAYOUT 0"]))

        assertEquals([
            AeroObj.window(.forTest(window: focusedWindow, title: "focused")),
            AeroObj.window(.forTest(window: TestWindow.new(id: 22, parent: emptyWorkspace.rootTilingContainer), title: "plain")),
        ].format([.interVar("window-zone")]), .success(["center", "NULL-ZONE"]))
    }

    func testJsonFormatIncludesWindowZone() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)

        _ = TestWindow.new(id: 1, parent: workspace.zoneContainers["left"].orDie())
        let centerWindow = TestWindow.new(id: 2, parent: workspace.zoneContainers["center"].orDie())
        assertTrue(centerWindow.focusWindow())

        let args = parseCmdArgs(["list-windows", "--all", "--format", "%{window-id} %{window-zone}", "--json"].slice).cmdOrDie as! ListWindowsCmdArgs
        let result = try await ListWindowsCommand(args: args).run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stdout, ["""
[
  {
    "window-id" : 1,
    "window-zone" : "left"
  },
  {
    "window-id" : 2,
    "window-zone" : "center"
  }
]
"""])
        assertEquals(result.stderr, [])
    }
}
