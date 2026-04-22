import Common
import Foundation
import Network

private struct Subscriber {
    let connection: NWConnection
    let events: Set<ServerEventType>
}

@MainActor private var subscribers: [UniqueToken: Subscriber] = [:]
@MainActor var broadcastEventForTesting: ((ServerEvent) -> Void)? = nil

@MainActor
func handleSubscribeAndWaitTillError(_ connection: NWConnection, _ args: SubscribeCmdArgs) async {
    let id = UniqueToken()
    subscribers[id] = Subscriber(connection: connection, events: args.events)
    defer { subscribers.removeValue(forKey: id) }
    if args.sendInitial {
        let f = focus
        for eventType in args.events {
            let event: ServerEvent
            switch eventType {
                case .focusChanged:
                    let focusedZoneName: String? = f.windowOrNil.flatMap { window in
                        guard let zc = window.parents.first(where: { ($0 as? TilingContainer)?.isZoneContainer == true }) as? TilingContainer
                        else { return nil }
                        return f.workspace.zoneContainers.first(where: { $0.value === zc })?.key
                    }
                    event = .focusChanged(windowId: f.windowOrNil?.windowId, workspace: f.workspace.name, appName: f.windowOrNil?.app.name, zoneName: focusedZoneName)
                case .workspaceChanged:
                    event = .workspaceChanged(workspace: f.workspace.name, prevWorkspace: f.workspace.name)
                case .modeChanged:
                    event = .modeChanged(mode: activeMode)
                case .focusedMonitorChanged:
                    event = .focusedMonitorChanged(
                        workspace: f.workspace.name,
                        monitorId_oneBased: f.workspace.workspaceMonitor.monitorId_oneBased ?? 0,
                    )
                case .zoneFocused:
                    guard let zoneName = activeZoneName(in: f.workspace) else { continue }
                    event = .zoneFocused(workspace: f.workspace.name, zoneName: zoneName)
                case .zonePresetChanged:
                    event = .zonePresetChanged(workspace: f.workspace.name, presetName: activeZonePresetName)
                case .windowDetected, .bindingTriggered: continue
                case .monitorChanged:
                    event = .monitorChanged(monitorCount: monitors.count)
            }
            if await connection.writeAtomic(event, jsonEncoder).error != nil {
                return
            }
        }
    }

    // Keep connection alive - wait for client to disconnect
    await connection.readTillError()
}

private let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    return e
}()

func broadcastEvent(_ event: ServerEvent) {
    Task { @MainActor in
        broadcastEventForTesting?(event)
        for (id, subscriber) in subscribers {
            guard subscriber.events.contains(event.eventType) else { continue }
            if await subscriber.connection.writeAtomic(event, jsonEncoder).error != nil {
                _ = subscribers.removeValue(forKey: id)
            }
        }
    }
}
