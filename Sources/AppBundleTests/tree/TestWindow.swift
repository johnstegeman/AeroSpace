@testable import AppBundle
import AppKit

final class TestWindow: Window, CustomStringConvertible {
    private var _rect: Rect?
    private let customTitle: String?

    @MainActor
    private init(_ id: UInt32, _ parent: NonLeafTreeNodeObject, _ adaptiveWeight: CGFloat, _ rect: Rect?, title: String?) {
        _rect = rect
        customTitle = title
        super.init(id: id, TestApp.shared, lastFloatingSize: nil, parent: parent, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
    }

    @discardableResult
    @MainActor
    static func new(id: UInt32, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat = 1, rect: Rect? = nil, title: String? = nil) -> TestWindow {
        let wi = TestWindow(id, parent, adaptiveWeight, rect, title: title)
        TestApp.shared._windows.append(wi)
        return wi
    }

    nonisolated var description: String { "TestWindow(\(windowId))" }

    @MainActor
    override func nativeFocus() {
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = self
    }

    override func closeAxWindow() {
        unbindFromParent()
    }

    override var title: String {
        get async { // redundant async. todo create bug report to Swift
            customTitle ?? description
        }
    }

    @MainActor override func getAxRect() async throws -> Rect? { // todo change to not Optional
        _rect
    }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        guard let rect = _rect else { return }
        _rect = rect
            .copy(\.topLeftX, topLeft?.x ?? rect.topLeftX)
            .copy(\.topLeftY, topLeft?.y ?? rect.topLeftY)
            .copy(\.width, size?.width ?? rect.width)
            .copy(\.height, size?.height ?? rect.height)
    }
}
