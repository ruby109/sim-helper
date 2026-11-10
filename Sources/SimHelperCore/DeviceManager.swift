import Foundation

public struct AcquireOptions {
    public var deviceType: String?
    public var runtime: String?
    public var boot = true
    public var slim = true
    public var slimExcept: String?

    public init(deviceType: String? = nil, runtime: String? = nil, boot: Bool = true, slim: Bool = true, slimExcept: String? = nil) {
        self.deviceType = deviceType
        self.runtime = runtime
        self.boot = boot
        self.slim = slim
        self.slimExcept = slimExcept
    }
}

public struct ReleaseReport: Encodable, Equatable {
    public var workspace: String
    public var parked: String?
    public var deleted: [String] = []
}

public struct PruneReport: Encodable, Equatable {
    public var released: [ReleaseReport] = []
    public var skippedBusy: [String] = []
    public var deleted: [String] = []
    public var failures: [String] = []
}

public struct DeviceManager {
    public var paths: Paths
    public var runner: CommandRunner
    public var maxParked: Int
    public var bootTimeout: TimeInterval = 300
    public var probeTimeout: TimeInterval = 90
    public var log: (String) -> Void

    private var simctl: Simctl { Simctl(runner: runner) }

    public init(paths: Paths, runner: CommandRunner, maxParked: Int = 3, log: @escaping (String) -> Void = { _ in }) {
        self.paths = paths
        self.runner = runner
        self.maxParked = maxParked
        self.log = log
    }

    private func withRegistry<T>(_ body: (inout Registry) throws -> T) throws -> T {
        let lock = try FileLock.acquire(paths.registryLock, .exclusive)
        defer { lock.release() }
        var registry = try Registry.load(paths)
        // Save on the failure path too: a delete can fail after others succeeded.
        do {
            let result = try body(&registry)
            try registry.save(paths)
            return result
        } catch {
            try registry.save(paths)
            throw error
        }
    }

    public func list() throws -> [OwnedDevice] {
        try withRegistry { $0.devices }
    }

    /// Returns this workspace's simulator: the one it already has, else a parked
    /// match, else a new one.
    public func acquire(_ workspace: Workspace, _ options: AcquireOptions = AcquireOptions()) throws -> OwnedDevice {
        try workspace.record(in: paths)
        var device = try withRegistry { registry in
            try allocate(workspace, options, &registry)
        }
        guard options.boot else { return device }
        try ensureUsable(device.udid)
        if options.slim, !device.slimmed, try slim(device, except: options.slimExcept) {
            device.slimmed = true
            let slimmed = device
            try withRegistry { registry in
                if let i = registry.devices.firstIndex(where: { $0.udid == slimmed.udid }) { registry.devices[i].slimmed = true }
            }
            // simslim reboots the simulator to apply.
            try ensureUsable(device.udid)
        }
        return device
    }

    private func allocate(_ workspace: Workspace, _ options: AcquireOptions, _ registry: inout Registry) throws -> OwnedDevice {
        let existing = try simctl.devices()
        // Someone deleted these behind our back; the records point at nothing.
        registry.devices.removeAll { existing[$0.udid] == nil }

        let explicit = options.deviceType != nil || options.runtime != nil
        let target = explicit ? try resolveTarget(runtimes: simctl.runtimes(), deviceType: options.deviceType, runtime: options.runtime) : nil

        if let i = registry.devices.firstIndex(where: { $0.workspace == workspace.id && $0.state == .assigned }) {
            let current = registry.devices[i]
            if target == nil || (current.deviceType == target!.deviceType && current.runtime == target!.runtime) {
                return current
            }
            log("parking \(current.udid): this workspace now asks for a different device")
            _ = try park(index: i, &registry)
        }

        let wanted = try target ?? resolveTarget(runtimes: simctl.runtimes(), deviceType: nil, runtime: nil)
        let parked = registry.devices.indices
            .filter { registry.devices[$0].state == .parked && registry.devices[$0].deviceType == wanted.deviceType && registry.devices[$0].runtime == wanted.runtime }
            .max { (registry.devices[$0].parkedAt ?? .distantPast) < (registry.devices[$1].parkedAt ?? .distantPast) }
        if let parked {
            registry.devices[parked].state = .assigned
            registry.devices[parked].workspace = workspace.id
            registry.devices[parked].parkedAt = nil
            log("reusing parked simulator \(registry.devices[parked].udid)")
            return registry.devices[parked]
        }

        let name = ownedDevicePrefix + UUID().uuidString.prefix(8).lowercased()
        let udid = try simctl.create(name: name, target: wanted)
        let device = OwnedDevice(udid: udid, name: name, deviceType: wanted.deviceType, runtime: wanted.runtime, state: .assigned, workspace: workspace.id)
        registry.devices.append(device)
        log("created simulator \(name) (\(udid))")
        return device
    }

    /// Boots and proves the simulator can start a process, restarting it once if not.
    private func ensureUsable(_ udid: String) throws {
        for attempt in 1...2 {
            try simctl.boot(udid, timeout: bootTimeout)
            if simctl.waitForBoot(udid, timeout: bootTimeout), simctl.canLaunchProcess(udid, timeout: probeTimeout) {
                return
            }
            log("simulator \(udid) booted but cannot launch processes (attempt \(attempt))")
            try simctl.shutdown(udid)
        }
        throw HelperError(.bootStuck, "Simulator \(udid) reports booted but cannot launch a process.", remedy: "Check host memory pressure, then retry. Deleting it with `xcrun simctl delete \(udid)` makes the next acquire create a new one.")
    }

    /// Returns whether the simulator was slimmed. SimSlim is an optimization, so its
    /// absence or failure leaves a working, if heavier, simulator.
    private func slim(_ device: OwnedDevice, except: String?) throws -> Bool {
        guard runner.run("which", ["simslim"]).ok else { return false }
        var args = ["on", device.udid]
        if let except { args += ["--except", except] }
        let result = runner.run("simslim", args, timeout: bootTimeout)
        if !result.ok {
            log("warning: simslim failed, continuing without it: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.ok
    }

    /// Parks the workspace's simulator for reuse. Nothing else is touched.
    public func releaseDevice(of workspace: Workspace) throws -> ReleaseReport {
        try withRegistry { registry in
            var report = ReleaseReport(workspace: workspace.id, parked: nil)
            if let i = registry.devices.firstIndex(where: { $0.workspace == workspace.id && $0.state == .assigned }) {
                report = ReleaseReport(workspace: workspace.id, parked: registry.devices[i].udid, deleted: try park(index: i, &registry))
            }
            return report
        }
    }

    private func park(index: Int, _ registry: inout Registry) throws -> [String] {
        // Parked first: if the shutdown fails the workspace has still let go of it.
        registry.devices[index].state = .parked
        registry.devices[index].workspace = nil
        registry.devices[index].parkedAt = Date()
        let udid = registry.devices[index].udid
        do {
            try simctl.shutdown(udid)
        } catch {
            log("warning: could not shut down \(udid): \(error)")
        }
        return try evictParked(&registry)
    }

    private func evictParked(_ registry: inout Registry) throws -> [String] {
        let parked = registry.devices.filter { $0.state == .parked }
            .sorted { ($0.parkedAt ?? .distantPast) < ($1.parkedAt ?? .distantPast) }
        let excess = parked.prefix(max(0, parked.count - maxParked))
        for device in excess {
            if let i = registry.devices.firstIndex(where: { $0.udid == device.udid }) { registry.devices[i].state = .deleting }
        }
        return try deletePending(&registry)
    }

    /// A failed delete keeps its record, so a later prune can retry it.
    private func deletePending(_ registry: inout Registry) throws -> [String] {
        var deleted: [String] = []
        var failures: [String] = []
        for device in registry.devices where device.state == .deleting {
            do {
                try? simctl.shutdown(device.udid)
                try simctl.delete(device.udid)
                registry.devices.removeAll { $0.udid == device.udid }
                deleted.append(device.udid)
            } catch {
                failures.append("\(device.udid): \(error)")
            }
        }
        if !failures.isEmpty {
            throw HelperError(.deleteFailed, "Could not delete: \(failures.joined(separator: "; ")).", remedy: "Run `sim-helper prune` to retry.")
        }
        return deleted
    }

    public func retryPendingDeletes() throws -> [String] {
        try withRegistry { registry in
            let existing = try simctl.devices()
            registry.devices.removeAll { existing[$0.udid] == nil }
            return try deletePending(&registry)
        }
    }
}
