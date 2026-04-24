import AppKit
import Common

struct ConfigLoadFailure: Error {
    let message: String
    let configUrl: URL?
    let errorCount: Int
}

struct ReloadConfigCommand: Command {
    let args: ReloadConfigCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        var stdout = ""
        let isOk = try await reloadConfig(args: args, stdout: &stdout)
        if !stdout.isEmpty {
            io.out(stdout)
        }
        return .from(bool: isOk)
    }
}

@MainActor func reloadConfig(forceConfigUrl: URL? = nil) async throws -> Bool {
    var devNull = ""
    return try await reloadConfig(forceConfigUrl: forceConfigUrl, stdout: &devNull)
}

@MainActor func reloadConfig(
    args: ReloadConfigCmdArgs = ReloadConfigCmdArgs(rawArgs: []),
    forceConfigUrl: URL? = nil,
    stdout: inout String,
) async throws -> Bool {
    let result: Bool
    switch readConfig(forceConfigUrl: forceConfigUrl) {
        case .success(let (parsedConfig, url)):
            telemetryLog("config.reloadFinished", payload: compactTelemetry(
                ("configPath", .string(url.path)),
                ("dryRun", .bool(args.dryRun)),
                ("monitorProfileCount", .int(parsedConfig.monitorProfiles.count)),
                ("ok", .bool(true)),
                ("zoneDefinitionCount", .int(parsedConfig.zones.zones.count)),
                ("zonePresetCount", .int(parsedConfig.zonePresets.count))
            ))
            if !args.dryRun {
                resetHotKeys()
                config = parsedConfig
                defaultZonesConfig = parsedConfig.zones
                configUrl = url
                try await activateMode(activeMode)
                syncStartAtLogin()
                MessageModel.shared.message = nil
                for workspace in Workspace.all {
                    workspace.ensureZoneContainers(for: workspace.workspaceMonitor, force: true)
                }
                await applyMatchingMonitorProfile()
            }
            result = true
        case .failure(let failure):
            stdout.append(failure.message)
            telemetryLog("config.reloadFailed", payload: compactTelemetry(
                ("configPath", failure.configUrl.map { .string($0.path) }),
                ("dryRun", .bool(args.dryRun)),
                ("errorCount", .int(failure.errorCount)),
                ("message", .string(failure.message))
            ))
            if !args.noGui {
                Task { @MainActor in
                    MessageModel.shared.message = Message(description: "AeroSpace Config Error", body: failure.message)
                }
            }
            result = false
    }
    if !args.dryRun {
        syncConfigFileWatcher()
    }
    return result
}
