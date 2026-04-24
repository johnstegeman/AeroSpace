import Common
import Foundation

indirect enum TelemetryValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([TelemetryValue])
    case object([String: TelemetryValue])

    fileprivate var jsonObject: Any {
        switch self {
            case .string(let value): value
            case .int(let value): value
            case .double(let value): value
            case .bool(let value): value
            case .array(let value): value.map(\.jsonObject)
            case .object(let value): value.mapValues(\.jsonObject)
        }
    }
}

extension TelemetryValue: ExpressibleByStringLiteral {
    init(stringLiteral value: StringLiteralType) { self = .string(value) }
}

extension TelemetryValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: IntegerLiteralType) { self = .int(value) }
}

extension TelemetryValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: FloatLiteralType) { self = .double(value) }
}

extension TelemetryValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: BooleanLiteralType) { self = .bool(value) }
}

extension TelemetryValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: TelemetryValue...) { self = .array(elements) }
}

extension TelemetryValue: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, TelemetryValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension TelemetryValue {
    init(_ value: String) { self = .string(value) }
    init(_ value: Int) { self = .int(value) }
    init(_ value: UInt32) { self = .int(Int(value)) }
    init(_ value: Bool) { self = .bool(value) }
}

func compactTelemetry(_ entries: (String, TelemetryValue?)...) -> [String: TelemetryValue] {
    Dictionary(uniqueKeysWithValues: entries.compactMap { key, value in
        value.map { (key, $0) }
    })
}

func telemetryString(_ value: String?) -> TelemetryValue? {
    value.map { .string($0) }
}

@MainActor
func telemetrySessionPayload() -> [String: TelemetryValue] {
    let zoneMemoryStats = ZoneMemory.shared.stats()
    let monitorPayloads: [TelemetryValue] = monitors.enumerated().map { index, monitor in
        .object(compactTelemetry(
            ("index", .int(index)),
            ("isMain", .bool(monitor.isMain)),
            ("name", .string(monitor.name)),
            ("width", .double(monitor.rect.width)),
            ("height", .double(monitor.rect.height)),
            ("aspectRatio", .double(monitor.rect.width / monitor.rect.height))
        ))
    }
    return compactTelemetry(
        ("activeZonePresetName", telemetryString(activeZonePresetName)),
        ("appRoutingRuleCount", .int(config.zones.appRouting.count)),
        ("monitorCount", .int(monitors.count)),
        ("monitorProfileCount", .int(config.monitorProfiles.count)),
        ("monitors", .array(monitorPayloads)),
        ("zoneDefinitionCount", .int(config.zones.zones.count)),
        ("zoneMemoryAppCount", .int(zoneMemoryStats.appCount)),
        ("zoneMemoryEntryCount", .int(zoneMemoryStats.entryCount)),
        ("zoneMemoryProfileCount", .int(zoneMemoryStats.profileCount)),
        ("zonePresetCount", .int(config.zonePresets.count))
    )
}

actor Telemetry {
    static let shared = Telemetry()

    private let fileHandle: FileHandle?
    private let fileURL: URL?
    private let sessionId: String
    private let processId: Int32
    private let encoder = JSONEncoder()
    private let timestampFormatter = ISO8601DateFormatter()

    init() {
        processId = ProcessInfo.processInfo.processIdentifier
        sessionId = UUID().uuidString.lowercased()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]

        let url = Telemetry.makeSessionLogURL(processId: processId)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            fileURL = url
            fileHandle = handle
        } catch {
            fileURL = nil
            fileHandle = nil
            eprint("telemetry: failed to initialize log file: \(error)")
        }
    }

    func log(_ type: String, payload: [String: TelemetryValue] = [:]) {
        guard let fileHandle else { return }

        var event: [String: Any] = [
            "pid": Int(processId),
            "sessionId": sessionId,
            "timestamp": timestampFormatter.string(from: Date()),
            "type": type,
        ]
        if let fileURL {
            event["logPath"] = fileURL.path
        }
        if !payload.isEmpty {
            event["payload"] = payload.mapValues(\.jsonObject)
        }
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        else {
            return
        }
        do {
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: data)
            try fileHandle.write(contentsOf: Data([0x0A]))
        } catch {
            eprint("telemetry: failed to write event: \(error)")
        }
    }

    func sessionMetadata() -> [String: TelemetryValue] {
        var result: [String: TelemetryValue] = [
            "pid": .int(Int(processId)),
            "sessionId": .string(sessionId),
        ]
        if let fileURL {
            result["logPath"] = .string(fileURL.path)
        }
        return result
    }

    private static func makeSessionLogURL(processId: Int32) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let fileName = "telemetry-\(timestamp)-pid-\(processId)-\(UUID().uuidString.lowercased()).jsonl"
        return baseDirectory.appendingPathComponent("telemetry/\(fileName)")
    }

    private static var baseDirectory: URL {
        if isUnitTest {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("AeroSpaceTests", isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AeroSpace", isDirectory: true)
    }
}

func telemetryLog(_ type: String, payload: [String: TelemetryValue] = [:]) {
    Task {
        await Telemetry.shared.log(type, payload: payload)
    }
}
