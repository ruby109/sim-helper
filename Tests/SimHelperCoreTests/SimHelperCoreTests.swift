import Foundation
import Testing
@testable import SimHelperCore

/// In-memory simctl. Records calls and can be told to fail specific subcommands.
final class FakeRunner: CommandRunner {
    var devices: [String: SimDevice] = [:]
    var calls: [[String]] = []
    var failing: Set<String> = []
    var launchFailures = 0
    var simslimInstalled = true
    var buildLines: [String] = []
    var buildStatus: Int32 = 0
    var onBuild: (() -> Void)?
    var casValidation = CommandResult()
    var xcodeVersion = "Xcode 27.2\nBuild version 27B52"
    var swiftVersion = "Apple Swift version 6.4.2 (swiftlang)"
    private var next = 0

    static let runtimesJSON = """
    {"runtimes":[
      {"identifier":"rt.iOS-18-0","version":"18.0","isAvailable":true,"supportedDeviceTypes":[{"name":"iPhone 16 Pro","identifier":"dt.16pro"}]},
      {"identifier":"rt.iOS-27-2-iPhone19-4","version":"27.2","isAvailable":true,"supportedDeviceTypes":[{"name":"iPhone Duo","identifier":"dt.duo"}]},
      {"identifier":"rt.iOS-27-2","version":"27.2","isAvailable":true,"supportedDeviceTypes":[
        {"name":"iPhone 18","identifier":"dt.18"},{"name":"iPhone 18 Pro","identifier":"dt.18pro"},
        {"name":"iPhone 18 Pro Max","identifier":"dt.18max"},{"name":"iPhone 9 Pro","identifier":"dt.9pro"},
        {"name":"iPad Pro","identifier":"dt.ipad"}]},
      {"identifier":"rt.xrOS-2-0","version":"2.0","isAvailable":true,"supportedDeviceTypes":[]}
    ]}
    """

    func run(_ executable: String, _ args: [String], timeout: TimeInterval?, onLine: ((String) -> Void)?) -> CommandResult {
        calls.append([executable] + args)
        if executable == "which" { return CommandResult(status: simslimInstalled ? 0 : 1) }
        if executable == "simslim" { return CommandResult() }
        if executable == "xcrun", args.first == "xcodebuild" {
            if args.contains("-version") { return CommandResult(output: xcodeVersion) }
            onBuild?()
            buildLines.forEach { onLine?($0) }
            return CommandResult(status: buildStatus)
        }
        if executable == "xcrun", args.first == "llvm-cas" { return casValidation }
        if executable == "xcrun", args.first == "swift" { return CommandResult(output: swiftVersion) }
        guard executable == "xcrun", args.first == "simctl" else { return CommandResult(status: 127) }
        let sub = Array(args.dropFirst())
        if failing.contains(sub[0]) { return CommandResult(status: 1, output: "\(sub[0]) failed") }
        switch sub[0] {
        case "list" where sub.last == "runtimes":
            return CommandResult(output: Self.runtimesJSON)
        case "list":
            let entries = try! JSONSerialization.data(withJSONObject: devices.values.map {
                ["udid": $0.udid, "name": $0.name, "state": $0.state, "isAvailable": $0.isAvailable] as [String: Any]
            })
            return CommandResult(output: "{\"devices\":{\"rt\":\(String(decoding: entries, as: UTF8.self))}}")
        case "create":
            next += 1
            let udid = "UDID-\(next)"
            devices[udid] = SimDevice(udid: udid, name: sub[1], state: "Shutdown", isAvailable: true)
            return CommandResult(output: udid + "\n")
        case "delete":
            devices[sub[1]] = nil
            return CommandResult()
        case "launch":
            if launchFailures > 0 {
                launchFailures -= 1
                return CommandResult(status: 1, timedOut: true)
            }
            return CommandResult()
        default:
            return CommandResult()
        }
    }

    func simctlCalls(_ sub: String) -> [[String]] {
        calls.filter { $0.count > 2 && $0[1] == "simctl" && $0[2] == sub }
    }
}

final class Sandbox {
    let home: String
    let paths: Paths
    let runner = FakeRunner()

    init() {
        home = NSTemporaryDirectory() + "simh-test-" + UUID().uuidString
        paths = Paths(home: home)
    }

    deinit { try? FileManager.default.removeItem(atPath: home) }

    func manager(maxParked: Int = 3) -> DeviceManager {
        DeviceManager(paths: paths, runner: runner, maxParked: maxParked)
    }

    /// A worktree directory that actually exists, so prune leaves it alone.
    func existingWorkspace(_ name: String) throws -> Workspace {
        let root = home + "/trees/" + name
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return Workspace(root: root)
    }
}

@Suite struct TargetResolution {
    let runtimes = try! JSONDecoder().decode(
        [String: [SimRuntime]].self, from: Data(FakeRunner.runtimesJSON.utf8))["runtimes"]!

    @Test func defaultsToNewestGeneralRuntimeAndNonMaxPro() throws {
        let target = try resolveTarget(runtimes: runtimes, deviceType: nil, runtime: nil)
        #expect(target == Target(deviceType: "dt.18pro", runtime: "rt.iOS-27-2"))
    }

    @Test func deviceTypeOnlyInOlderRuntimeSelectsThatRuntime() throws {
        let target = try resolveTarget(runtimes: runtimes, deviceType: "iPhone 16 Pro", runtime: nil)
        #expect(target == Target(deviceType: "dt.16pro", runtime: "rt.iOS-18-0"))
    }

    func failure(deviceType: String?, runtime: String?) throws -> HelperError {
        do {
            _ = try resolveTarget(runtimes: runtimes, deviceType: deviceType, runtime: runtime)
        } catch let error as HelperError {
            return error
        }
        throw HelperError(.usage, "expected failure")
    }

    @Test func unknownRuntimeListsInstalledVersions() throws {
        let error = try failure(deviceType: nil, runtime: "99.0")
        #expect(error.code == .noRuntime)
        #expect(error.available == ["27.2", "18.0"])
    }

    @Test func unknownDeviceTypeListsChoicesWithoutDuplicates() throws {
        let error = try failure(deviceType: "Nokia", runtime: nil)
        #expect(error.code == .noDeviceType)
        let available = try #require(error.available)
        #expect(available.contains("iPhone 18 Pro"))
        #expect(available.contains("iPhone 16 Pro"))
        #expect(Set(available).count == available.count)
    }

    @Test func deviceTypeMissingFromRequestedRuntimeListsOnlyThatRuntime() throws {
        let error = try failure(deviceType: "iPhone 18 Pro", runtime: "18.0")
        #expect(error.code == .noDeviceType)
        #expect(error.available == ["iPhone 16 Pro"])
    }

    @Test func listingMatchesWhatAcquireResolves() throws {
        let listing = listTargets(runtimes: runtimes)
        #expect(listing.runtimes.map(\.identifier) == ["rt.iOS-27-2", "rt.iOS-27-2-iPhone19-4", "rt.iOS-18-0"])
        #expect(listing.defaultTarget == .init(deviceType: "dt.18pro", runtime: "rt.iOS-27-2"))
        #expect(listing.runtimes[0].deviceTypes.map(\.name).prefix(2) == ["iPhone 18 Pro Max", "iPhone 18 Pro"])
        // Everything listed must be accepted back.
        for runtime in listing.runtimes {
            for type in runtime.deviceTypes {
                let target = try resolveTarget(runtimes: runtimes, deviceType: type.name, runtime: runtime.identifier)
                #expect(target == Target(deviceType: type.identifier, runtime: runtime.identifier))
            }
        }
    }

    @Test func listingWithNoRuntimesIsEmpty() {
        let listing = listTargets(runtimes: [])
        #expect(listing.defaultTarget == nil)
        #expect(listing.runtimes.isEmpty)
    }
}

@Suite struct DeviceLifecycle {
    @Test func acquireIsStickyPerWorkspace() throws {
        let box = Sandbox()
        let a = try box.existingWorkspace("a"), b = try box.existingWorkspace("b")
        let first = try box.manager().acquire(a)
        let again = try box.manager().acquire(a)
        let other = try box.manager().acquire(b)
        #expect(first.udid == again.udid)
        #expect(first.udid != other.udid)
        #expect(first.name.hasPrefix(ownedDevicePrefix))
        #expect(box.runner.simctlCalls("create").count == 2)
    }

    @Test func releasedDeviceIsParkedAndReused() throws {
        let box = Sandbox()
        let a = try box.existingWorkspace("a"), b = try box.existingWorkspace("b")
        let first = try box.manager().acquire(a)
        let report = try box.manager().releaseDevice(of: a)
        #expect(report.parked == first.udid)
        #expect(box.runner.simctlCalls("shutdown").count == 1)
        let reused = try box.manager().acquire(b)
        #expect(reused.udid == first.udid)
        #expect(reused.workspace == b.id)
        #expect(box.runner.simctlCalls("create").count == 1)
    }

    @Test func parkedOverCapDeletesOldest() throws {
        let box = Sandbox()
        let manager = box.manager(maxParked: 1)
        let a = try box.existingWorkspace("a"), b = try box.existingWorkspace("b")
        let first = try manager.acquire(a), second = try manager.acquire(b)
        _ = try manager.releaseDevice(of: a)
        let report = try manager.releaseDevice(of: b)
        #expect(report.deleted == [first.udid])
        #expect(try manager.list().map(\.udid) == [second.udid])
    }

    @Test func failedDeleteKeepsRecordAndPruneRetries() throws {
        let box = Sandbox()
        let manager = box.manager(maxParked: 0)
        let a = try box.existingWorkspace("a")
        let first = try manager.acquire(a)
        box.runner.failing = ["delete"]
        #expect(throws: HelperError.self) { try manager.releaseDevice(of: a) }
        #expect(try manager.list().map(\.state) == [.deleting])
        box.runner.failing = []
        #expect(try manager.retryPendingDeletes() == [first.udid])
        #expect(try manager.list().isEmpty)
    }

    @Test func neverTouchesDevicesItDidNotCreate() throws {
        let box = Sandbox()
        // A look-alike name is not ownership; only the registry is.
        box.runner.devices["FOREIGN"] = SimDevice(udid: "FOREIGN", name: "simh-foreign", state: "Booted", isAvailable: true)
        let a = try box.existingWorkspace("a")
        let manager = box.manager(maxParked: 0)
        _ = try manager.acquire(a)
        _ = try manager.releaseDevice(of: a)
        _ = WorkspaceCleaner(paths: box.paths, devices: manager).prune()
        let touched = box.runner.calls.filter { $0.contains("FOREIGN") }
        #expect(touched.isEmpty)
        #expect(box.runner.devices["FOREIGN"] != nil)
    }

    @Test func recordIsDroppedWhenDeviceDeletedExternally() throws {
        let box = Sandbox()
        let a = try box.existingWorkspace("a")
        let first = try box.manager().acquire(a)
        box.runner.devices[first.udid] = nil
        let second = try box.manager().acquire(a)
        #expect(second.udid != first.udid)
    }

    @Test func stuckBootRestartsOnceThenFails() throws {
        let box = Sandbox()
        let a = try box.existingWorkspace("a")
        box.runner.launchFailures = 1
        // Without slimming, whose reboot would add a boot of its own.
        _ = try box.manager().acquire(a, AcquireOptions(slim: false))
        #expect(box.runner.simctlCalls("shutdown").count == 1)
        #expect(box.runner.simctlCalls("boot").count == 2)

        let b = try box.existingWorkspace("b")
        box.runner.launchFailures = 2
        #expect(throws: HelperError.self) { try box.manager().acquire(b) }
    }

    @Test func missingSimslimFailsBeforeCreatingAnything() throws {
        let box = Sandbox()
        box.runner.simslimInstalled = false
        let a = try box.existingWorkspace("a")
        #expect(throws: HelperError.self) { try box.manager().acquire(a) }
        #expect(box.runner.simctlCalls("create").isEmpty)

        // Opting out, or not booting, does not need SimSlim.
        _ = try box.manager().acquire(a, AcquireOptions(boot: false))
        let device = try box.manager().acquire(a, AcquireOptions(slim: false))
        #expect(!device.slimmed)
        #expect(!box.runner.calls.contains { $0[0] == "simslim" })
    }

    @Test func slimsOnlyOnce() throws {
        let box = Sandbox()
        let a = try box.existingWorkspace("a")
        let device = try box.manager().acquire(a, AcquireOptions(slim: true, slimExcept: "push"))
        #expect(device.slimmed)
        #expect(box.runner.calls.filter { $0[0] == "simslim" } == [["simslim", "on", device.udid, "--except", "push"]])
        _ = try box.manager().acquire(a)
        #expect(box.runner.calls.filter { $0[0] == "simslim" }.count == 1)
    }
}

@Suite struct CacheLocking {
    @Test func clearRefusedWhileBuildHoldsClaim() throws {
        let box = Sandbox()
        let cache = CompilationCache(paths: box.paths)
        let claim = try cache.claim()
        let marker = cache.directory + "/entry"
        FileManager.default.createFile(atPath: marker, contents: Data([1]))
        #expect(throws: HelperError(.cacheBusy, "A build is using the compilation cache at \(cache.directory).", remedy: "Retry when the build has finished.")) {
            try cache.clear()
        }
        #expect(FileManager.default.fileExists(atPath: marker))
        #expect(try cache.status().inUse)
        claim.release()
        try cache.clear()
        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(FileManager.default.fileExists(atPath: cache.directory))
        #expect(try !cache.status().inUse)
    }

    @Test func sharedClaimsCoexist() throws {
        let box = Sandbox()
        let cache = CompilationCache(paths: box.paths)
        let one = try cache.claim(), two = try cache.claim()
        one.release()
        two.release()
    }
}

@Suite struct CacheSettings {
    let swift64 = Toolchain(xcodeMajor: 27, swiftMajor: 6, swiftMinor: 4)

    @Test func swiftJoinsOnlyFrom64() {
        let new = compilationCacheSettings(workspaceRoot: "/w", derivedData: "/d", casPath: "/c", toolchain: swift64)
        #expect(new.contains("SWIFT_ENABLE_COMPILE_CACHE=YES"))
        #expect(new.contains("SWIFT_OTHER_PREFIX_MAPPINGS=/w=/^src /d=/^derived-data"))
        let old = compilationCacheSettings(workspaceRoot: "/w", derivedData: "/d", casPath: "/c", toolchain: Toolchain(xcodeMajor: 26, swiftMajor: 6, swiftMinor: 3))
        #expect(old.contains("COMPILATION_CACHE_ENABLE_CACHING=YES"))
        #expect(old.contains("SWIFT_ENABLE_COMPILE_CACHE=NO"))
    }

    @Test func noSettingsBeforeXcode26() {
        #expect(compilationCacheSettings(workspaceRoot: "/w", derivedData: "/d", casPath: "/c", toolchain: Toolchain(xcodeMajor: 16, swiftMajor: 6, swiftMinor: 0)).isEmpty)
    }

    @Test func mappingsWithSpacesAreQuoted() {
        let settings = compilationCacheSettings(workspaceRoot: "/my tree", derivedData: "/my tree/dd", casPath: "/c", toolchain: swift64)
        #expect(settings.contains("CLANG_OTHER_PREFIX_MAPPINGS=\"/my tree=/^src\""))
    }

    @Test func parsesBuildOutput() {
        #expect(BuildOutput.isCorruption("LLVM ERROR: OnDiskCAS: corrupt internal reference"))
        #expect(BuildOutput.isCorruption("error: CAS operation failed: x"))
        #expect(!BuildOutput.isCorruption("error: no such module"))
        #expect(BuildOutput.activity("note: 12 hits / 34 cacheable tasks (35%)") == CacheActivity(hits: 12, cacheableTasks: 34))
        #expect(BuildOutput.activity("note: 1 hit / 70 cacheable tasks (1%)") == CacheActivity(hits: 1, cacheableTasks: 70))
    }
}

@Suite struct Building {
    func builder(_ box: Sandbox) -> Builder {
        Builder(paths: box.paths, runner: box.runner, devices: box.manager())
    }

    @Test func listPassesThroughWithoutWorktreeFlags() throws {
        let box = Sandbox()
        let a = try box.existingWorkspace("a")
        let result = try builder(box).build(a, xcodebuildArgs: ["-list"])
        let call = try #require(box.runner.calls.last { $0.count > 1 && $0[1] == "xcodebuild" && !$0.contains("-version") })
        #expect(Array(call.dropFirst(2)) == ["-list"])
        #expect(!result.compilationCache && result.udid == nil)
    }

    @Test func corruptionEmptiesCacheAndExits75() throws {
        let box = Sandbox()
        let a = try box.existingWorkspace("a")
        let cache = CompilationCache(paths: box.paths)
        try FileManager.default.createDirectory(atPath: cache.directory, withIntermediateDirectories: true)
        let entry = cache.directory + "/entry"
        FileManager.default.createFile(atPath: entry, contents: Data([1]))
        box.runner.buildLines = ["LLVM ERROR: OnDiskCAS: corrupt internal reference"]
        box.runner.buildStatus = 65
        do {
            _ = try builder(box).build(a, xcodebuildArgs: ["build"])
            Issue.record("expected failure")
        } catch let error as HelperError {
            #expect(error.code == .cacheCorrupt)
            #expect(error.exitCode == 75)
        }
        #expect(!FileManager.default.fileExists(atPath: entry))
    }

    @Test func corruptionWithAnotherBuildRunningLeavesCacheAlone() throws {
        let box = Sandbox()
        let a = try box.existingWorkspace("a")
        let cache = CompilationCache(paths: box.paths)
        let otherBuild = try cache.claim()
        defer { otherBuild.release() }
        let entry = cache.directory + "/entry"
        FileManager.default.createFile(atPath: entry, contents: Data([1]))
        box.runner.buildLines = ["error: CAS operation failed: x"]
        box.runner.buildStatus = 65
        do {
            _ = try builder(box).build(a, xcodebuildArgs: ["build"])
            Issue.record("expected failure")
        } catch let error as HelperError {
            #expect(error.code == .cacheCorrupt)
            #expect(error.exitCode == 1)
        }
        #expect(FileManager.default.fileExists(atPath: entry))
    }

    @Test func ordinaryFailureKeepsCacheAndStatus() throws {
        let box = Sandbox()
        let a = try box.existingWorkspace("a")
        let cache = CompilationCache(paths: box.paths)
        try FileManager.default.createDirectory(atPath: cache.directory, withIntermediateDirectories: true)
        let entry = cache.directory + "/entry"
        FileManager.default.createFile(atPath: entry, contents: Data([1]))
        box.runner.buildLines = ["error: cannot find 'x' in scope"]
        box.runner.buildStatus = 65
        do {
            _ = try builder(box).build(a, xcodebuildArgs: ["build"])
            Issue.record("expected failure")
        } catch let error as HelperError {
            #expect(error.code == .buildFailed)
            #expect(error.exitCode == 65)
        }
        #expect(FileManager.default.fileExists(atPath: entry))
    }

    /// Runs a build whose only symptom is the build service crashing.
    func crashedBuild(_ box: Sandbox, validation: CommandResult) throws -> (HelperError, entrySurvived: Bool) {
        let a = try box.existingWorkspace("a")
        let cache = CompilationCache(paths: box.paths)
        try FileManager.default.createDirectory(atPath: cache.directory + "/builtin", withIntermediateDirectories: true)
        let entry = cache.directory + "/builtin/entry"
        FileManager.default.createFile(atPath: entry, contents: Data([1]))
        box.runner.casValidation = validation
        box.runner.buildLines = ["error: unexpected service error: The Xcode build system has crashed. Build again to continue."]
        box.runner.buildStatus = 65
        do {
            _ = try builder(box).build(a, xcodebuildArgs: ["build"])
        } catch let error as HelperError {
            return (error, FileManager.default.fileExists(atPath: entry))
        }
        throw HelperError(.usage, "expected failure")
    }

    @Test func serviceCrashWithInvalidCasIsCorruption() throws {
        let box = Sandbox()
        let (error, survived) = try crashedBuild(box, validation: CommandResult(status: 1, output: "llvm-cas: validate: invalid trie at 0x1: slot points out of bound"))
        #expect(error.code == .cacheCorrupt)
        #expect(error.exitCode == 75)
        #expect(!survived)
    }

    @Test func serviceCrashWithSoundCasKeepsCache() throws {
        let box = Sandbox()
        let (error, survived) = try crashedBuild(box, validation: CommandResult())
        #expect(error.code == .buildFailed)
        #expect(survived)
    }

    @Test func uncheckableCasIsNotEvidenceOfDamage() throws {
        let box = Sandbox()
        let (error, survived) = try crashedBuild(box, validation: CommandResult(status: 1, output: "xcrun: error: unable to find utility \"llvm-cas\""))
        #expect(error.code == .buildFailed)
        #expect(survived)
    }

    @Test func holdsClaimDuringBuildAndAddsOnlyMissingFlags() throws {
        let box = Sandbox()
        let a = try box.existingWorkspace("a")
        let cache = CompilationCache(paths: box.paths)
        var inUseDuringBuild = false
        box.runner.onBuild = { inUseDuringBuild = (try? cache.status().inUse) ?? false }
        let result = try builder(box).build(a, xcodebuildArgs: ["-scheme", "App", "build"])
        #expect(inUseDuringBuild)
        #expect(try !cache.status().inUse)
        let call = try #require(box.runner.calls.last { $0.contains("-scheme") })
        #expect(call.contains("-derivedDataPath"))
        #expect(call.contains("platform=iOS Simulator,id=\(result.udid!)"))

        let custom = try builder(box).build(a, xcodebuildArgs: ["-scheme", "App", "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", "/mine", "build"])
        #expect(custom.udid == nil)
        #expect(custom.derivedData == "/mine")
        let customCall = try #require(box.runner.calls.last { $0.contains("-scheme") })
        #expect(customCall.filter { $0 == "-destination" }.count == 1)
        #expect(customCall.filter { $0 == "-derivedDataPath" }.count == 1)
    }
}

@Suite struct Cleanup {
    @Test func releaseRefusedDuringBuild() throws {
        let box = Sandbox()
        let a = try box.existingWorkspace("a")
        let manager = box.manager()
        _ = try manager.acquire(a)
        let cleaner = WorkspaceCleaner(paths: box.paths, devices: manager)
        let building = try FileLock.acquire(box.paths.workspaceLock(a.id), .shared)
        #expect(throws: HelperError.self) { try cleaner.release(a) }
        building.release()
        _ = try cleaner.release(a)
        #expect(!FileManager.default.fileExists(atPath: a.directory(in: box.paths)))
    }

    @Test func pruneOnlyReleasesWorkspacesWhoseWorktreeIsGone() throws {
        let box = Sandbox()
        let manager = box.manager()
        let alive = try box.existingWorkspace("alive")
        let gone = try box.existingWorkspace("gone")
        let aliveDevice = try manager.acquire(alive)
        let goneDevice = try manager.acquire(gone)
        try FileManager.default.removeItem(atPath: gone.root)
        let report = WorkspaceCleaner(paths: box.paths, devices: manager).prune()
        #expect(report.released.map(\.parked) == [goneDevice.udid])
        #expect(report.failures.isEmpty)
        let devices = try manager.list()
        #expect(devices.first { $0.udid == aliveDevice.udid }?.state == .assigned)
        #expect(devices.first { $0.udid == goneDevice.udid }?.state == .parked)
        #expect(FileManager.default.fileExists(atPath: alive.directory(in: box.paths)))
        #expect(!FileManager.default.fileExists(atPath: gone.directory(in: box.paths)))
    }
}

@Suite struct Developer {
    @Test func skipsCommandLineToolsAndNonXcodeApps() throws {
        let box = Sandbox()
        let apps = box.home + "/Applications"
        let fm = FileManager.default
        func app(_ name: String, xcodebuild: Bool) throws {
            let dir = "\(apps)/\(name)/Contents/Developer/usr/bin"
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if xcodebuild { fm.createFile(atPath: dir + "/xcodebuild", contents: Data(), attributes: [.posixPermissions: 0o755]) }
        }
        try app("Xcodes.app", xcodebuild: false)
        try app("Xcode-13.3.1.app", xcodebuild: true)
        try app("Xcode-27.2.0.app", xcodebuild: true)
        let dir = try DeveloperDirectory.resolve(environment: [:], selected: { "/Library/Developer/CommandLineTools" }, applicationsDir: apps)
        #expect(dir == "\(apps)/Xcode-27.2.0.app/Contents/Developer")
    }
}

@Suite struct Identity {
    @Test func worktreesGetDistinctStableIds() {
        #expect(Workspace(root: "/a/repo").id == Workspace(root: "/a/repo").id)
        #expect(Workspace(root: "/a/repo").id != Workspace(root: "/b/repo").id)
        #expect(Workspace(root: "/a/my repo!").id.hasPrefix("my-repo--"))
    }
}

@Suite struct HelpText {
    @Test func errorReferenceCoversEveryCode() {
        let documented = Set(Help.errors.map(\.code))
        #expect(documented == Set(HelperError.Code.allCases.map(\.rawValue)))
        for command in Help.commands {
            #expect(Set(command.errors).isSubset(of: documented), "\(command.command)")
        }
    }

    @Test func groupsAndTopLevelComeFromCommands() {
        #expect(Help.groups["sim"] == ["acquire", "targets", "list"])
        #expect(Help.groups["cache"] == ["status", "clear"])
        #expect(Help.topLevel == ["env", "sim", "build", "cache", "release", "prune", "help"])
    }

    @Test func suggestsCloseMatchesOnly() {
        #expect(Help.suggestion(for: "aquire", among: ["acquire", "targets", "list"]) == "acquire")
        #expect(Help.suggestion(for: "bulid", among: Help.topLevel) == "build")
        #expect(Help.suggestion(for: "--devce-type", among: ["--device-type", "--runtime"]) == "--device-type")
        #expect(Help.suggestion(for: "deploy", among: Help.topLevel) == nil)
    }

    @Test func everyCommandHasUsageOutputAndExample() {
        for command in Help.commands {
            #expect(command.usage.hasPrefix("sim-helper \(command.command)"), "\(command.command)")
            #expect(!command.output.isEmpty && !command.examples.isEmpty, "\(command.command)")
            #expect(command.options.allSatisfy { $0.flag.hasPrefix("--") }, "\(command.command)")
        }
    }
}
