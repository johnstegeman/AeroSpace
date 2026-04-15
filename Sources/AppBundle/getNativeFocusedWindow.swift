import AppKit
import Common

@MainActor
var appForTests: (any AbstractApp)? = nil

@MainActor
func getNativeFocusedWindow() async throws -> Window? {
    if isUnitTest {
        return try await appForTests?.getFocusedWindow()
    }
    check(appForTests == nil)
    guard let frontmostNsApp = NSWorkspace.shared.frontmostApplication else { return nil }
    guard let macApp = try await MacApp.getOrRegister(frontmostNsApp) else { return nil }
    if let window = try await macApp.getFocusedWindow(),
       !(window.parent is MacosPopupWindowsContainer)
    {
        return window
    }
    // Fallback 1: the AX kAXFocusedWindowAttr can lag behind NSWorkspace.frontmostApplication
    // immediately after an app-activation event (e.g. user clicks a window and presses a
    // hotkey before the AX attribute propagates). In that case getFocusedWindow() returns nil
    // or a transient popup window even though the app is clearly frontmost. Using the last
    // window AeroSpace successfully observed for this app avoids acting on whichever stale
    // window was previously focused.
    if let lastId = macApp.lastNativeFocusedWindowId,
       let window = Window.get(byId: lastId),
       !(window.parent is MacosPopupWindowsContainer)
    {
        return window
    }
    // Fallback 2: lastNativeFocusedWindowId is nil (e.g. after AeroSpace restart, first time
    // focusing this app). Find any real (non-popup) window that belongs to the frontmost app.
    // This prevents commands from acting on whatever was focused before the app switch.
    return MacWindow.allWindows.first { $0.macApp === macApp && !($0.parent is MacosPopupWindowsContainer) }
}
