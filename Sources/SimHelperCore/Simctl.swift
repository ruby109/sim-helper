import Foundation

public struct SimDevice: Decodable, Equatable {
    public var udid: String
    public var name: String
    public var state: String
    public var isAvailable: Bool
}

public struct SimRuntime: Decodable, Equatable {
    public struct DeviceType: Decodable, Equatable {
        public var name: String
        public var identifier: String
        public var productFamily: String?
    }

    public var identifier: String
    public var version: String
    public var isAvailable: Bool
    public var platform: String?
    public var supportedDeviceTypes: [DeviceType]
}

public struct Target: Equatable {
    public var deviceType: String
    public var runtime: String
}

public struct Simctl {
    public var runner: CommandRunner

    public init(runner: CommandRunner) { self.runner = runner }

    private func simctl(_ args: [String], timeout: TimeInterval = 120) -> CommandResult {
        runner.run("xcrun", ["simctl"] + args, timeout: timeout)
    }

    private func checked(_ args: [String], timeout: TimeInterval = 120) throws -> String {
        let result = simctl(args, timeout: timeout)
        guard result.ok else {
            let why = result.timedOut ? "timed out after \(Int(timeout))s" : result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HelperError(.simctlFailed, "simctl \(args.joined(separator: " ")): \(why)")
        }
        return result.output
    }

    public func devices() throws -> [String: SimDevice] {
        struct Listing: Decodable { var devices: [String: [SimDevice]] }
        let output = try checked(["list", "-j", "devices"])
        let listing = try decodeJSON(Listing.self, output)
        return Dictionary(listing.devices.values.joined().map { ($0.udid, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func runtimes() throws -> [SimRuntime] {
        struct Listing: Decodable { var runtimes: [SimRuntime] }
        return try decodeJSON(Listing.self, try checked(["list", "-j", "runtimes"])).runtimes
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, _ output: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(output.utf8))
        } catch {
            throw HelperError(.simctlFailed, "Unexpected simctl output: \(error)")
        }
    }

    public func create(name: String, target: Target) throws -> String {
        try checked(["create", name, target.deviceType, target.runtime]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func boot(_ udid: String, timeout: TimeInterval) throws {
        let result = simctl(["boot", udid], timeout: timeout)
        if result.ok || result.output.contains("current state: Booted") { return }
        throw HelperError(.simctlFailed, "simctl boot \(udid): \(result.timedOut ? "timed out" : result.output)")
    }

    /// Returns once the boot has finished; false on timeout.
    public func waitForBoot(_ udid: String, timeout: TimeInterval) -> Bool {
        simctl(["bootstatus", udid, "-b"], timeout: timeout).ok
    }

    /// A simulator can report Booted with SpringBoard up while launches hang,
    /// so the only real proof it is usable is launching something.
    public func canLaunchProcess(_ udid: String, timeout: TimeInterval) -> Bool {
        let ok = simctl(["launch", udid, "com.apple.Preferences"], timeout: timeout).ok
        if ok { _ = simctl(["terminate", udid, "com.apple.Preferences"], timeout: 30) }
        return ok
    }

    public func shutdown(_ udid: String) throws {
        let result = simctl(["shutdown", udid], timeout: 60)
        if result.ok || result.output.contains("current state: Shutdown") { return }
        throw HelperError(.simctlFailed, "simctl shutdown \(udid): \(result.timedOut ? "timed out" : result.output)")
    }

    public func delete(_ udid: String) throws {
        _ = try checked(["delete", udid])
    }
}

extension SimRuntime {
    var isIOS: Bool { identifier.contains(".iOS-") }

    var versionParts: [Int] { version.split(separator: ".").compactMap { Int($0) } }
}

public func compareVersions(_ a: [Int], _ b: [Int]) -> Int {
    for i in 0..<max(a.count, b.count) {
        let (x, y) = (i < a.count ? a[i] : 0, i < b.count ? b[i] : 0)
        if x != y { return x < y ? -1 : 1 }
    }
    return 0
}

/// Picks what to create. `deviceType` and `runtime` match an identifier or display
/// name; defaults are the newest iOS runtime and its newest non-Max iPhone Pro.
public func resolveTarget(runtimes: [SimRuntime], deviceType: String?, runtime: String?) throws -> Target {
    let usable = usableRuntimes(runtimes)
    let ordered = runtime.map { wanted in
        usable.filter { $0.identifier == wanted || $0.version == wanted || "iOS \($0.version)" == wanted }
    } ?? usable
    guard let chosen = ordered.first else {
        throw HelperError(
            .noRuntime, "No available iOS runtime\(runtime.map { " matching \($0)" } ?? "").",
            remedy: "Pick an installed version, or install one: xcodebuild -downloadPlatform iOS",
            available: unique(usable.map(\.version)))
    }
    if let deviceType {
        for candidate in ordered {
            if let match = candidate.supportedDeviceTypes.first(where: { $0.identifier == deviceType || $0.name == deviceType }) {
                return Target(deviceType: match.identifier, runtime: candidate.identifier)
            }
        }
        throw HelperError(
            .noDeviceType, "No available iOS runtime\(runtime.map { " matching \($0)" } ?? "") supports device type \(deviceType).",
            remedy: "Pick an available device type; `sim-helper sim targets` shows which runtimes support each.",
            available: unique(ordered.flatMap { byNameDescending($0.supportedDeviceTypes).map(\.name) }))
    }
    let phones = chosen.supportedDeviceTypes.filter { $0.name.hasPrefix("iPhone") }
    // simctl's list is not ordered by age, so compare the model numbers in the names.
    let sortedPhones = byNameDescending(phones)
    let pick = sortedPhones.first { $0.name.range(of: #"^iPhone \d+ Pro$"#, options: .regularExpression) != nil } ?? sortedPhones.first
    guard let pick else {
        throw HelperError(.noDeviceType, "\(chosen.identifier) supports no iPhone.", remedy: "Pass --device-type.")
    }
    return Target(deviceType: pick.identifier, runtime: chosen.identifier)
}

/// Available iOS runtimes, newest first. Single-device runtimes share a version with
/// the general one, so the general one comes first.
func usableRuntimes(_ runtimes: [SimRuntime]) -> [SimRuntime] {
    runtimes.filter { $0.isAvailable && $0.isIOS }.sorted {
        let order = compareVersions($0.versionParts, $1.versionParts)
        return order != 0 ? order > 0 : $0.supportedDeviceTypes.count > $1.supportedDeviceTypes.count
    }
}

/// Natural name order, so higher model numbers sort first. Not a true age order:
/// names without a number, such as iPhone SE and iPhone Air, come before all of them.
private func byNameDescending(_ types: [SimRuntime.DeviceType]) -> [SimRuntime.DeviceType] {
    types.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
}

private func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
}

/// What `sim acquire` can be asked for on this machine.
public struct TargetListing: Encodable, Equatable {
    public struct Runtime: Encodable, Equatable {
        public var version: String
        public var identifier: String
        public var deviceTypes: [DeviceType]
    }

    public struct DeviceType: Encodable, Equatable {
        public var name: String
        public var identifier: String
    }

    public struct Default: Encodable, Equatable {
        public var deviceType: String
        public var runtime: String

        public init(deviceType: String, runtime: String) {
            self.deviceType = deviceType
            self.runtime = runtime
        }
    }

    public var defaultTarget: Default?
    public var runtimes: [Runtime]
}

public func listTargets(runtimes: [SimRuntime]) -> TargetListing {
    let target = try? resolveTarget(runtimes: runtimes, deviceType: nil, runtime: nil)
    return TargetListing(
        defaultTarget: target.map { TargetListing.Default(deviceType: $0.deviceType, runtime: $0.runtime) },
        runtimes: usableRuntimes(runtimes).map { runtime in
            TargetListing.Runtime(
                version: runtime.version, identifier: runtime.identifier,
                deviceTypes: byNameDescending(runtime.supportedDeviceTypes).map { .init(name: $0.name, identifier: $0.identifier) })
        })
}
