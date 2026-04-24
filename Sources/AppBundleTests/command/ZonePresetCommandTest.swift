@testable import AppBundle
import Common
import XCTest

@MainActor
final class ZonePresetCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        XCTAssertEqual((parseCommand("zone-preset balanced").cmdOrDie as? ZonePresetCommand)?.args.presetName, "balanced")
        XCTAssertTrue((parseCommand("zone-preset --reset").cmdOrDie as? ZonePresetCommand)?.args.reset ?? false)
        XCTAssertEqual((parseCommand("zone-preset --save dev").cmdOrDie as? ZonePresetCommand)?.args.saveName, "dev")
        XCTAssertTrue((parseCommand("zone-preset --export").cmdOrDie as? ZonePresetCommand)?.args.export ?? false)
        XCTAssertEqual(
            parseCommand("zone-preset balanced --reset").errorOrNil,
            "Provide exactly one of: <preset-name>, --reset, --save <name>, or --export",
        )
    }

    func testSaveCapturesLiveZoneWeightsAndLayouts() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        workspace.zoneContainers["left"]?.setWeight(.h, 1)
        workspace.zoneContainers["center"]?.setWeight(.h, 2)
        workspace.zoneContainers["right"]?.setWeight(.h, 3)
        workspace.zoneContainers["center"]?.layout = .accordion

        let io = CmdIo(stdin: .emptyStdin)
        let args = (parseCommand("zone-preset --save balanced").cmdOrDie as! ZonePresetCommand).args
        let result = ZonePresetCommand(args: args).run(.defaultEnv, io)

        XCTAssertEqual(result.rawValue, 0)
        XCTAssertEqual(io.stdout, ["Saved zone preset 'balanced' (3 zones)"])
        guard let preset = config.zonePresets["balanced"] else {
            return XCTFail("Expected saved runtime preset")
        }
        XCTAssertEqual(preset.zones.map(\.id), ["left", "center", "right"])
        XCTAssertEqual(preset.zones[0].width, 1.0 / 6.0, accuracy: 0.000_001)
        XCTAssertEqual(preset.zones[1].width, 2.0 / 6.0, accuracy: 0.000_001)
        XCTAssertEqual(preset.zones[2].width, 3.0 / 6.0, accuracy: 0.000_001)
        XCTAssertEqual(preset.zones[1].layout, .accordion)
    }

    func testExportUsesSavedZoneWeightsWhenZoneFocusModeIsActive() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        workspace.zoneContainers["left"]?.setWeight(.h, 0.1)
        workspace.zoneContainers["center"]?.setWeight(.h, 0.8)
        workspace.zoneContainers["right"]?.setWeight(.h, 0.1)
        workspace.zoneContainers["right"]?.layout = .accordion
        workspace.savedZoneWeights = ["left": 2, "center": 3, "right": 5]
        activeZonePresetName = "focused"

        let io = CmdIo(stdin: .emptyStdin)
        let args = (parseCommand("zone-preset --export").cmdOrDie as! ZonePresetCommand).args
        let result = ZonePresetCommand(args: args).run(.defaultEnv, io)

        XCTAssertEqual(result.rawValue, 0)
        XCTAssertEqual(io.stdout, [[
            "[[zone-presets]]",
            "name = \"focused\"",
            "",
            "[[zone-presets.zone]]",
            "id = \"left\"",
            "width = 0.2",
            "layout = \"tiles\"",
            "",
            "[[zone-presets.zone]]",
            "id = \"center\"",
            "width = 0.3",
            "layout = \"tiles\"",
            "",
            "[[zone-presets.zone]]",
            "id = \"right\"",
            "width = 0.5",
            "layout = \"accordion\"",
        ].joined(separator: "\n")])
    }

    func testResetClearsMonitorProfileDisabledState() {
        setTestMonitorsOverride([FakeMonitor.ultrawide])
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        zonesDisabledByProfile = true
        monitorProfileManagedZoneLayout = true
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide, force: true)
        XCTAssertTrue(workspace.zoneContainers.isEmpty)

        let io = CmdIo(stdin: .emptyStdin)
        let args = (parseCommand("zone-preset --reset").cmdOrDie as! ZonePresetCommand).args
        let result = ZonePresetCommand(args: args).run(.defaultEnv, io)

        XCTAssertEqual(result.rawValue, 0)
        XCTAssertFalse(zonesDisabledByProfile)
        XCTAssertFalse(monitorProfileManagedZoneLayout)
        XCTAssertFalse(workspace.zoneContainers.isEmpty)
    }

    func testSaveUsesTargetWorkspaceFromCommandEnv() {
        let focusedWorkspace = focus.workspace
        focusedWorkspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        focusedWorkspace.zoneContainers["left"]?.setWeight(.h, 1)
        focusedWorkspace.zoneContainers["center"]?.setWeight(.h, 1)
        focusedWorkspace.zoneContainers["right"]?.setWeight(.h, 1)

        let targetWorkspace = Workspace.get(byName: "2")
        targetWorkspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        targetWorkspace.zoneContainers["left"]?.setWeight(.h, 1)
        targetWorkspace.zoneContainers["center"]?.setWeight(.h, 2)
        targetWorkspace.zoneContainers["right"]?.setWeight(.h, 3)

        let io = CmdIo(stdin: .emptyStdin)
        let args = (parseCommand("zone-preset --save balanced").cmdOrDie as! ZonePresetCommand).args
        let result = ZonePresetCommand(args: args).run(.defaultEnv.copy(\.workspaceName, "2"), io)

        XCTAssertEqual(result.rawValue, 0)
        XCTAssertEqual(config.zonePresets["balanced"]?.zones.map(\.width), [1.0 / 6.0, 2.0 / 6.0, 3.0 / 6.0])
    }

    func testExportEscapesTomlStringsAndUsesTargetWorkspaceFromCommandEnv() {
        config.zones.zones = [
            ZoneDefinition(id: "left\"\\zone", width: 0.25, layout: .tiles),
            ZoneDefinition(id: "center", width: 0.75, layout: .accordion),
        ]
        let targetWorkspace = Workspace.get(byName: "2")
        targetWorkspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        activeZonePresetName = "focus\"\\preset"

        let io = CmdIo(stdin: .emptyStdin)
        let args = (parseCommand("zone-preset --export").cmdOrDie as! ZonePresetCommand).args
        let result = ZonePresetCommand(args: args).run(.defaultEnv.copy(\.workspaceName, "2"), io)

        XCTAssertEqual(result.rawValue, 0)
        XCTAssertEqual(io.stdout, [[
            "[[zone-presets]]",
            "name = \"focus\\\"\\\\preset\"",
            "",
            "[[zone-presets.zone]]",
            "id = \"left\\\"\\\\zone\"",
            "width = 0.25",
            "layout = \"tiles\"",
            "",
            "[[zone-presets.zone]]",
            "id = \"center\"",
            "width = 0.75",
            "layout = \"accordion\"",
        ].joined(separator: "\n")])
    }
}
