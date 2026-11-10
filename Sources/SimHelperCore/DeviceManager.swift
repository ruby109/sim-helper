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
    /// Parked simulators deleted to stay within the parking limit.
    public var deleted: [String] = []
    /// Simulators that could not be deleted. Their records stay so `prune` can retry.
    public var deleteFailures: [String] = []
    /// The worktree's state directory, with its DerivedData, once removed.
    public var removed: String?
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

    /// For changes only. simctl calls that can take minutes (shutdown, delete,
    /// boot) run outside it, so one agent's cleanup does not stall every other.
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

    /// The registry as last saved, read without the lock. Saves are atomic renames,
    /// so this sees a whole file; use it to look, not to decide what to write.
    public func list() throws -> [OwnedDevice] {
        try Registry.load(paths).devices
    }

    private func assigned(to workspace: Workspace) throws -> OwnedDevice? {
        try list().first { $0.workspace == workspace.id && $0.state == .assigned }
    }

    /// Returns this workspace's simulator: the one it already has, else a parked
    /// match, else a new one. Asking for a different device type or runtime parks
    /// the current one and switches.
    public func acquire(_ workspace: Workspace, _ options: AcquireOptions = AcquireOptions()) throws -> OwnedDevice {
        // Checked before allocating: a stock simulator uses several times the memory,
        // which quietly limits how many agents fit on one Mac.
        if options.boot, options.slim, !runner.run("which", ["simslim"]).ok {
            throw HelperError(.simslimMissing, "SimSlim is not installed.",
                              remedy: "Install it with `brew install mobai-app/tap/simslim`, or pass --no-slim to use a stock simulator.")
        }
        let explicit = options.deviceType != nil || options.runtime != nil
        let target = explicit ? try resolveTarget(runtimes: simctl.runtimes(), deviceType: options.deviceType, runtime: options.runtime) : nil

        // Builds in this worktree hold the lock shared and `release` takes it
        // exclusively, so release cannot park the simulator mid-acquire. Switching or
        // slimming reboots the simulator, so those wait for no build to be running.
        var lock = try FileLock.acquire(paths.workspaceLock(workspace.id), .shared)
        defer { lock.release() }
        var current = try assigned(to: workspace)
        let switching = current.map { device in target.map { !device.matches($0) } ?? false } ?? false
        let slimming = options.boot && options.slim && !(current?.slimmed ?? false)
        if switching || slimming {
            lock.release()
            guard let exclusive = try FileLock.tryAcquire(paths.workspaceLock(workspace.id), .exclusive) else {
                throw HelperError(.workspaceBusy, "A build or another acquire is running in \(workspace.root), and this acquire would \(switching ? "switch" : "reboot") its simulator.",
                                  remedy: "Retry when the build has finished.")
            }
            lock = exclusive
            current = try assigned(to: workspace)
        }

        try workspace.record(in: paths)
        if let current, let target, !current.matches(target) {
            // Before parking: once parked, another worktree may take it and boot it.
            log("parking \(current.udid): this workspace now asks for a different device")
            shutdownQuietly(current.udid)
        }
        let (allocated, evicted) = try withRegistry { registry in
            try allocate(workspace, target, &registry)
        }
        _ = deletePending(evicted)
        var device = allocated
        guard options.boot else { return device }

        do {
            try ensureUsable(device.udid, alreadyVerified: device.slimmed || !options.slim)
            if options.slim, !device.slimmed, try slim(device, except: options.slimExcept) {
                device.slimmed = true
                try withRegistry { registry in
                    if let i = registry.devices.firstIndex(where: { $0.udid == device.udid }) { registry.devices[i].slimmed = true }
                }
                // simslim reboots the simulator to apply.
                try ensureUsable(device.udid, alreadyVerified: false)
            }
        } catch let error as HelperError where error.code == .bootStuck {
            discard(device.udid)
            throw HelperError(.bootStuck, error.message,
                              remedy: "The simulator was discarded. Wait for memory pressure to drop or other simulators to finish booting, then run `sim acquire` again; it creates a new one.")
        }
        return device
    }

    private func allocate(_ workspace: Workspace, _ target: Target?, _ registry: inout Registry) throws -> (OwnedDevice, evicted: [String]) {
        let existing = try simctl.devices()
        // Someone deleted these behind our back; the records point at nothing.
        registry.devices.removeAll { existing[$0.udid] == nil }

        var evicted: [String] = []
        if let i = registry.devices.firstIndex(where: { $0.workspace == workspace.id && $0.state == .assigned }) {
            let current = registry.devices[i]
            if target == nil || current.matches(target!) {
                return (current, [])
            }
            evicted = park(index: i, &registry)
        }

        let wanted = try target ?? resolveTarget(runtimes: simctl.runtimes(), deviceType: nil, runtime: nil)
        let parked = registry.devices.indices
            .filter { registry.devices[$0].state == .parked && registry.devices[$0].matches(wanted) }
            .max { (registry.devices[$0].parkedAt ?? .distantPast) < (registry.devices[$1].parkedAt ?? .distantPast) }
        if let parked {
            registry.devices[parked].state = .assigned
            registry.devices[parked].workspace = workspace.id
            registry.devices[parked].parkedAt = nil
            log("reusing parked simulator \(registry.devices[parked].udid)")
            return (registry.devices[parked], evicted)
        }

        let name = ownedDevicePrefix + UUID().uuidString.prefix(8).lowercased()
        let udid = try simctl.create(name: name, target: wanted)
        let device = OwnedDevice(udid: udid, name: name, deviceType: wanted.deviceType, runtime: wanted.runtime, state: .assigned, workspace: workspace.id)
        registry.devices.append(device)
        log("created simulator \(name) (\(udid))")
        return (device, evicted)
    }

    /// Boots and proves the simulator can start a process, restarting it once if not.
    /// A simulator that is already up and was verified before is left alone:
    /// launching the probe app could disturb a UI test running on it.
    private func ensureUsable(_ udid: String, alreadyVerified: Bool) throws {
        if alreadyVerified, try simctl.devices()[udid]?.state == "Booted" { return }
        for attempt in 1...2 {
            try simctl.boot(udid, timeout: bootTimeout)
            if simctl.waitForBoot(udid, timeout: bootTimeout), simctl.canLaunchProcess(udid, timeout: probeTimeout) {
                return
            }
            log("simulator \(udid) booted but cannot launch processes (attempt \(attempt))")
            try simctl.shutdown(udid)
        }
        throw HelperError(.bootStuck, "Simulator \(udid) reports booted but cannot launch a process.")
    }

    /// Returns whether the simulator was slimmed. A SimSlim failure, such as on a
    /// runtime older than iOS 18, leaves a working, if heavier, simulator.
    private func slim(_ device: OwnedDevice, except: String?) throws -> Bool {
        var args = ["on", device.udid]
        if let except { args += ["--except", except] }
        let result = runner.run("simslim", args, timeout: bootTimeout)
        if !result.ok {
            log("warning: simslim failed, continuing without it: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.ok
    }

    /// Takes a simulator that will not run anything out of service for good.
    private func discard(_ udid: String) {
        _ = try? withRegistry { registry in
            if let i = registry.devices.firstIndex(where: { $0.udid == udid }) {
                registry.devices[i].state = .deleting
                registry.devices[i].workspace = nil
            }
        }
        _ = deletePending([udid])
    }

    /// Parks the workspace's simulator for reuse. The caller holds the workspace
    /// lock exclusively.
    public func releaseDevice(of workspace: Workspace) throws -> ReleaseReport {
        var report = ReleaseReport(workspace: workspace.id)
        // Shut down while still assigned: once parked, another worktree may take it.
        if let current = try assigned(to: workspace) { shutdownQuietly(current.udid) }
        let evicted = try withRegistry { registry -> [String] in
            guard let i = registry.devices.firstIndex(where: { $0.workspace == workspace.id && $0.state == .assigned }) else { return [] }
            report.parked = registry.devices[i].udid
            return park(index: i, &registry)
        }
        (report.deleted, report.deleteFailures) = deletePending(evicted)
        return report
    }

    /// Marks the device parked and the oldest excess parked ones for deletion.
    /// Returns the UDIDs to delete once the registry lock is released.
    private func park(index: Int, _ registry: inout Registry) -> [String] {
        registry.devices[index].state = .parked
        registry.devices[index].workspace = nil
        registry.devices[index].parkedAt = Date()
        let parked = registry.devices.indices.filter { registry.devices[$0].state == .parked }
            .sorted { (registry.devices[$0].parkedAt ?? .distantPast) < (registry.devices[$1].parkedAt ?? .distantPast) }
        return parked.prefix(max(0, parked.count - maxParked)).map { i in
            registry.devices[i].state = .deleting
            return registry.devices[i].udid
        }
    }

    private func shutdownQuietly(_ udid: String) {
        do {
            try simctl.shutdown(udid)
        } catch {
            log("warning: could not shut down \(udid): \(error)")
        }
    }

    /// Deletes simulators marked for deletion: those in `only`, or all of them.
    /// A failed delete keeps its record, so a later prune can retry it.
    private func deletePending(_ only: [String]?) -> (deleted: [String], failures: [String]) {
        if let only, only.isEmpty { return ([], []) }
        let pending = ((try? list()) ?? []).filter { $0.state == .deleting && (only?.contains($0.udid) ?? true) }
        var deleted: [String] = []
        var failures: [String] = []
        for device in pending {
            try? simctl.shutdown(device.udid)
            do {
                try simctl.delete(device.udid)
                deleted.append(device.udid)
            } catch {
                // Another process cleaning up may have deleted it first.
                if let existing = try? simctl.devices(), existing[device.udid] == nil {
                    deleted.append(device.udid)
                } else {
                    failures.append("\(device.udid): \(error)")
                    log("warning: could not delete simulator \(device.udid); `sim-helper prune` retries it")
                }
            }
        }
        if !deleted.isEmpty {
            _ = try? withRegistry { $0.devices.removeAll { deleted.contains($0.udid) && $0.state == .deleting } }
        }
        return (deleted, failures)
    }

    public func retryPendingDeletes() throws -> [String] {
        let existing = try simctl.devices()
        try withRegistry { $0.devices.removeAll { existing[$0.udid] == nil } }
        let (deleted, failures) = deletePending(nil)
        if !failures.isEmpty {
            throw HelperError(.deleteFailed, "Could not delete: \(failures.joined(separator: "; ")).", remedy: "Run `sim-helper prune` to retry.")
        }
        return deleted
    }
}

extension OwnedDevice {
    func matches(_ target: Target) -> Bool {
        deviceType == target.deviceType && runtime == target.runtime
    }
}
