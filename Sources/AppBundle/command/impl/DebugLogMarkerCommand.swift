import Common

struct DebugLogMarkerCommand: Command {
    let args: DebugLogMarkerCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        AeroLog.marker(args._label ?? "")
        io.out("Marker written to \(AeroLog.logFileURL.path)")
        return .succ
    }
}
