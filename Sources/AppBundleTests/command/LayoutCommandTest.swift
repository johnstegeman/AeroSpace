@testable import AppBundle
import Common
import XCTest

@MainActor
final class LayoutCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testLayoutStackTogglesBackToTiles() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }

        let command = parseCommand("layout stack tiles").cmdOrDie as! LayoutCommand

        let firstResult = try await command.run(.defaultEnv, .emptyStdin)
        assertEquals(firstResult.exitCode.rawValue, 0)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .stack([.window(1), .window(2)]))

        let secondResult = try await command.run(.defaultEnv, .emptyStdin)
        assertEquals(secondResult.exitCode.rawValue, 0)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }
}
