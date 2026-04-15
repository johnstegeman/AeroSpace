import AppKit
import SwiftUI

@MainActor
final class ZoneHUDController: NSPanelHud {
    static var shared = ZoneHUDController()

    private var hostingView: NSHostingView<ZoneHUDView>

    override private init() {
        let initialView = ZoneHUDView(zones: [], totalWindowCount: 0)
        hostingView = NSHostingView(rootView: initialView)
        super.init()
        // Remove .hudWindow so SwiftUI's material background controls the look
        self.styleMask = [.nonactivatingPanel, .borderless, .utilityWindow]
        self.isOpaque = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.ignoresMouseEvents = true

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentView?.addSubview(hostingView)
        if let contentView {
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }
    }

    func update(workspace: Workspace) {
        let zoneContainers = workspace.zoneContainers

        let activeZoneName: String? = if let window = focus.windowOrNil,
                                         let container = window.parent as? TilingContainer,
                                         container.isZoneContainer
        {
            zoneContainers.first { $0.value === container }?.key
        } else {
            workspace.focusedZone
        }

        let zones: [ZoneHUDView.ZoneEntry] = if zoneContainers.isEmpty {
            []
        } else {
            ["left", "center", "right"].compactMap { name in
                guard let container = zoneContainers[name] else { return nil }
                return ZoneHUDView.ZoneEntry(
                    name: name,
                    count: container.allLeafWindowsRecursive.count,
                    isActive: activeZoneName == name,
                )
            }
        }

        hostingView.rootView = ZoneHUDView(
            zones: zones,
            totalWindowCount: workspace.allLeafWindowsRecursive.count,
        )
        reposition()
    }

    func setVisible(_ visible: Bool) {
        if visible {
            orderFront(nil)
        } else {
            orderOut(nil)
        }
    }

    private func reposition() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let fitting = hostingView.fittingSize
        let hudWidth = min(fitting.width + 24, 400)
        let hudHeight = fitting.height + 8
        let origin = CGPoint(
            x: vf.midX - hudWidth / 2,
            y: vf.minY + 20,
        )
        setFrame(NSRect(origin: origin, size: CGSize(width: hudWidth, height: hudHeight)), display: true)
    }
}

@MainActor
func hudShouldBeVisible() -> Bool {
    switch config.hud.activeOn {
        case .never: return false
        case .always: return true
        case .ultrawide: return !mainMonitor.activeWorkspace.zoneContainers.isEmpty
    }
}

private struct ZoneHUDView: View {
    struct ZoneEntry: Identifiable {
        var id: String { name }
        let name: String
        let count: Int
        let isActive: Bool
    }

    let zones: [ZoneEntry]
    let totalWindowCount: Int

    var body: some View {
        HStack(spacing: 2) {
            if zones.isEmpty {
                Text("\(totalWindowCount) windows")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                ForEach(zones) { zone in
                    HStack(spacing: 6) {
                        Text(zone.name)
                            .fontWeight(zone.isActive ? .semibold : .regular)
                        Text("\(zone.count)")
                            .monospacedDigit()
                            .foregroundStyle(zone.isActive ? .secondary : .quaternary)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(zone.isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(zone.isActive ? Color.primary.opacity(0.1) : Color.clear),
                    )
                }
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}
