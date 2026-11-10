import Foundation

public let ownedDevicePrefix = "simh-"

/// A simulator this tool created. Devices not listed here are never booted,
/// shut down or deleted, even if their name happens to match the prefix.
public struct OwnedDevice: Codable, Equatable {
    public enum State: String, Codable { case assigned, parked, deleting }

    public var udid: String
    public var name: String
    public var deviceType: String
    public var runtime: String
    public var state: State
    public var workspace: String?
    public var slimmed: Bool
    public var parkedAt: Date?

    public init(udid: String, name: String, deviceType: String, runtime: String, state: State, workspace: String?, slimmed: Bool = false, parkedAt: Date? = nil) {
        self.udid = udid
        self.name = name
        self.deviceType = deviceType
        self.runtime = runtime
        self.state = state
        self.workspace = workspace
        self.slimmed = slimmed
        self.parkedAt = parkedAt
    }
}

public struct Registry: Codable, Equatable {
    public var devices: [OwnedDevice] = []

    public init() {}

    static func load(_ paths: Paths) throws -> Registry {
        guard let data = FileManager.default.contents(atPath: paths.registry) else { return Registry() }
        do {
            return try decoder.decode(Registry.self, from: data)
        } catch {
            // Starting over would orphan every simulator we own.
            throw HelperError(.stateCorrupt, "Could not read \(paths.registry): \(error).", remedy: "Repair or remove the file; removing it leaves its simulators behind for manual deletion.")
        }
    }

    func save(_ paths: Paths) throws {
        try attempt(.stateCorrupt, "Could not write \(paths.registry)") {
            try FileManager.default.createDirectory(atPath: paths.home, withIntermediateDirectories: true)
            try encoder.encode(self).write(to: URL(fileURLWithPath: paths.registry), options: .atomic)
        }
    }
}

let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}()
