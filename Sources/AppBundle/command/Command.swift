import AppKit
import Common

protocol Command: AeroAny, Equatable, Sendable {
    associatedtype T: CmdArgs

    var args: T { get }
    @MainActor
    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> T.ExitCodeType

    /// We should reset closedWindowsCache when the command can potentially change the tree
    var shouldResetClosedWindowsCache: Bool { get }
}

extension Command {
    static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.args.equals(rhs.args)
    }

    nonisolated func equals(_ other: any Command) -> Bool {
        (other as? Self).flatMap { self == $0 } ?? false
    }
}

extension Command {
    var info: CmdStaticInfo { T.info }
}

extension Command {
    @MainActor
    @discardableResult
    func run(_ env: CmdEnv, _ stdin: consuming CmdStdin) async throws -> CmdResult {
        return try await [self].runCmdSeq(env, stdin)
    }

    var isExec: Bool { self is ExecAndForgetCommand }
}

// There are 4 entry points for running commands:
// 1. config keybindings
// 2. CLI requests to server
// 3. on-window-detected callback
// 4. Tray icon buttons
extension [Command] {
    @MainActor
    func runCmdSeq(_ env: CmdEnv, _ io: sending CmdIo) async throws -> Int32ExitCode {
        var exitCode = Int32ExitCode(rawValue: EXIT_CODE_ZERO)
        for command in self {
            let stdoutStart = io.stdout.count
            let stderrStart = io.stderr.count
            let payload = commandTelemetryPayload(command, env)
            telemetryLog("command.started", payload: payload)
            do {
                exitCode = Int32ExitCode(rawValue: (try await command.run(env, io)).rawValue)
                let stderrLines: [String] = Swift.Array(io.stderr.dropFirst(stderrStart))
                let stdoutLines: [String] = Swift.Array(io.stdout.dropFirst(stdoutStart))
                var finishedPayload = payload
                finishedPayload["exitCode"] = .int(Int(exitCode.rawValue))
                finishedPayload["stderr"] = .array(stderrLines.map { .string($0) })
                finishedPayload["stdout"] = .array(stdoutLines.map { .string($0) })
                telemetryLog("command.finished", payload: finishedPayload)
            } catch {
                let stderrLines: [String] = Swift.Array(io.stderr.dropFirst(stderrStart))
                let stdoutLines: [String] = Swift.Array(io.stdout.dropFirst(stdoutStart))
                var failedPayload = payload
                failedPayload["error"] = .string(String(describing: error))
                failedPayload["stderr"] = .array(stderrLines.map { .string($0) })
                failedPayload["stdout"] = .array(stdoutLines.map { .string($0) })
                telemetryLog("command.failed", payload: failedPayload)
                throw error
            }
            if command.shouldResetClosedWindowsCache { resetClosedWindowsCache() }
            refreshModel()
        }
        return exitCode
    }

    @MainActor
    func runCmdSeq(_ env: CmdEnv, _ stdin: consuming CmdStdin) async throws -> CmdResult {
        let io: CmdIo = CmdIo(stdin: stdin)
        let exitCode = try await runCmdSeq(env, io)
        return CmdResult(stdout: io.stdout, stderr: io.stderr, exitCode: exitCode)
    }
}

private func commandTelemetryPayload(_ command: any Command, _ env: CmdEnv) -> [String: TelemetryValue] {
    var payload: [String: TelemetryValue] = [
        "command": .string(command.info.kind.rawValue),
        "description": .string(String(describing: command)),
    ]
    if let commandSource = env.commandSource {
        payload["commandSource"] = .string(commandSource.rawValue)
        payload["commandIsAutomation"] = .bool(commandSource != .hotkey && commandSource != .trayMenu && commandSource != .cli)
    }
    if let windowId = env.windowId {
        payload["windowId"] = .int(Int(windowId))
    }
    if let workspaceName = env.workspaceName {
        payload["workspace"] = .string(workspaceName)
    }
    return payload
}
