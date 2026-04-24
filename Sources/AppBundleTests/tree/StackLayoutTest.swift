@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class StackLayoutTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testLayoutStackLaysOutActiveChildLast() async throws {
        let workspace = focus.workspace
        let stack = TilingContainer(parent: workspace.rootTilingContainer, adaptiveWeight: 1, .v, .stack, index: INDEX_BIND_LAST)
        LayoutOrderWindow.layoutOrder = []
        _ = LayoutOrderWindow.new(id: 1, parent: stack)
        let active = LayoutOrderWindow.new(id: 2, parent: stack)
        _ = LayoutOrderWindow.new(id: 3, parent: stack)
        XCTAssertTrue(active.focusWindow())

        try await workspace.layoutWorkspace()

        XCTAssertEqual(LayoutOrderWindow.layoutOrder, [1, 3, 2])
    }
}

private final class LayoutOrderWindow: Window {
    nonisolated(unsafe) static var layoutOrder: [UInt32] = []

    @MainActor
    private init(_ id: UInt32, _ parent: NonLeafTreeNodeObject) {
        super.init(id: id, TestApp.shared, lastFloatingSize: nil, parent: parent, adaptiveWeight: 1, index: INDEX_BIND_LAST)
    }

    @discardableResult
    @MainActor
    static func new(id: UInt32, parent: NonLeafTreeNodeObject) -> LayoutOrderWindow {
        let window = LayoutOrderWindow(id, parent)
        TestApp.shared._windows.append(window)
        return window
    }

    @MainActor
    override func nativeFocus() {
        TestApp.shared.focusedWindow = self
    }

    override func closeAxWindow() {
        unbindFromParent()
    }

    override var title: String {
        get async { "LayoutOrderWindow(\(windowId))" }
    }

    @MainActor
    override func getAxRect() async throws -> Rect? { nil }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        Self.layoutOrder.append(windowId)
    }
}
