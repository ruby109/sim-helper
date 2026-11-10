import Foundation

public struct BuildResult: Encodable, Equatable {
    public var workspace: String
    public var derivedData: String
    public var udid: String?
    public var log: String
    public var compilationCache: Bool
    public var cacheActivity: CacheActivity?
    public var swiftTargetsWithoutExplicitModules: Int
}

public struct Builder {
    public var paths: Paths
    public var runner: CommandRunner
    public var devices: DeviceManager
    public var log: (String) -> Void

    public init(paths: Paths, runner: CommandRunner, devices: DeviceManager, log: @escaping (String) -> Void = { _ in }) {
        self.paths = paths
        self.runner = runner
        self.devices = devices
        self.log = log
    }

    /// Runs xcodebuild with this worktree's DerivedData, simulator and the shared
    /// compilation cache. Flags the caller already passed are left alone.
    public func build(_ workspace: Workspace, xcodebuildArgs: [String], useCache: Bool = true) throws -> BuildResult {
        let workspaceLock = try FileLock.acquire(paths.workspaceLock(workspace.id), .shared)
        defer { workspaceLock.release() }
        try workspace.record(in: paths)

        var args = xcodebuildArgs
        // -list builds nothing, and xcodebuild rejects -derivedDataPath without a scheme.
        let listing = args.contains("-list")
        let derivedData = value(of: "-derivedDataPath", in: args) ?? workspace.derivedData(in: paths)
        if value(of: "-derivedDataPath", in: args) == nil, !listing { args = ["-derivedDataPath", derivedData] + args }
        var udid: String?
        if !hasDestination(args) {
            // xcodebuild boots what it needs, so skip the slower readiness checks.
            let device = try devices.acquire(workspace, AcquireOptions(boot: false))
            udid = device.udid
            args = ["-destination", "platform=iOS Simulator,id=\(device.udid)"] + args
        }

        let cache = CompilationCache(paths: paths)
        let toolchain = Toolchain.detect(runner: runner)
        let caching = useCache && !listing && toolchain.supportsCompilationCache
        var claim = caching ? try cache.claim() : nil
        defer { claim?.release() }
        if caching {
            args = compilationCacheSettings(workspaceRoot: workspace.root, derivedData: derivedData, casPath: cache.directory, toolchain: toolchain) + args
        }

        let logPath = workspace.buildLog(in: paths)
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let logFile = FileHandle(forWritingAtPath: logPath)
        defer { try? logFile?.close() }

        var corruption: String?
        var serviceCrashed = false
        var activity: CacheActivity?
        var withoutExplicitModules = 0
        let result = runner.run("xcrun", ["xcodebuild"] + args, timeout: nil) { line in
            logFile?.write(Data((line + "\n").utf8))
            log(line)
            if caching, corruption == nil, BuildOutput.isCorruption(line) { corruption = line.trimmingCharacters(in: .whitespaces) }
            if caching, BuildOutput.isBuildServiceCrash(line) { serviceCrashed = true }
            if let parsed = BuildOutput.activity(line) { activity = parsed }
            if BuildOutput.needsExplicitModules(line) { withoutExplicitModules += 1 }
        }

        if !result.ok {
            if corruption == nil, serviceCrashed { corruption = cache.validationFailure(runner: runner) }
            if let corruption {
                claim?.release()
                claim = nil
                throw handleCorruption(corruption, cache: cache)
            }
            throw HelperError(.buildFailed, "xcodebuild exited with status \(result.status).", remedy: "Full output: \(logPath)", xcodebuildStatus: result.status)
        }
        return BuildResult(
            workspace: workspace.id, derivedData: derivedData, udid: udid, log: logPath,
            compilationCache: caching, cacheActivity: activity,
            swiftTargetsWithoutExplicitModules: withoutExplicitModules)
    }

    private func handleCorruption(_ line: String, cache: CompilationCache) -> HelperError {
        do {
            try cache.clear()
            return HelperError(.cacheCorrupt, "The compilation cache was corrupt (compiler reported: \(line)). It has been emptied.", remedy: "Run the same command again; that build starts cold.")
        } catch {
            // Another build is still compiling against it. A rerun would likely fail
            // the same way, so this is not the "just retry" exit status.
            return HelperError(.cacheCorrupt, "The compilation cache is corrupt (compiler reported: \(line)) but was not emptied: \(error).", remedy: "Once other builds finish run `sim-helper cache clear`, then rerun.", exitCode: 1)
        }
    }

    private func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private func hasDestination(_ args: [String]) -> Bool {
        args.contains("-destination") || args.contains("-showBuildSettings") || args.contains("-list")
    }
}

/// Lets a worktree go: parks its simulator and deletes its DerivedData.
public struct WorkspaceCleaner {
    public var paths: Paths
    public var devices: DeviceManager

    public init(paths: Paths, devices: DeviceManager) {
        self.paths = paths
        self.devices = devices
    }

    public func release(_ workspace: Workspace) throws -> ReleaseReport {
        guard let lock = try FileLock.tryAcquire(paths.workspaceLock(workspace.id), .exclusive) else {
            throw HelperError(.workspaceBusy, "A build or `sim acquire` is running in \(workspace.root).", remedy: "Retry when it has finished.")
        }
        defer { lock.release() }
        var report = try devices.releaseDevice(of: workspace)
        let directory = workspace.directory(in: paths)
        if FileManager.default.fileExists(atPath: directory) {
            try attempt(.deleteFailed, "Could not delete \(directory)") { try FileManager.default.removeItem(atPath: directory) }
            report.removed = directory
        }
        return report
    }

    /// Releases workspaces whose worktree no longer exists. git has no hook for
    /// `worktree remove`, so this is how those get noticed.
    public func prune() -> PruneReport {
        var report = PruneReport()
        for workspace in Workspace.all(in: paths) where !FileManager.default.fileExists(atPath: workspace.root) {
            do {
                report.released.append(try release(workspace))
            } catch let error as HelperError where error.code == .workspaceBusy {
                report.skippedBusy.append(workspace.id)
            } catch {
                report.failures.append("\(workspace.id): \(error)")
            }
        }
        do {
            report.deleted = try devices.retryPendingDeletes()
        } catch {
            report.failures.append("\(error)")
        }
        return report
    }
}
