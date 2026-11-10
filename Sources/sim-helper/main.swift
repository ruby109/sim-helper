import Foundation
import SimHelperCore

let usage = """
usage: sim-helper <command> [--json]

  env                          Show this worktree's state paths and the toolchain
  sim acquire [options]        Give this worktree its simulator, booted and verified
      --device-type <name>     Identifier or name (default: newest iPhone Pro)
      --runtime <version>      Identifier or version (default: newest iOS)
      --no-boot                Allocate only
      --no-slim                Skip SimSlim for this device
      --slim-except <list>     Categories SimSlim keeps, e.g. push,storekit
  sim targets                  Runtimes and device types acquire can be asked for
  sim list                     Simulators this tool owns
  build [--no-cache] -- <xcodebuild args>
                               xcodebuild with this worktree's DerivedData and simulator
                               and the shared compilation cache
  cache status                 Size and whether a build is using it
  cache clear [--if-over-gb N] Empty the cache; refused while a build uses it
  release [path]               Park the worktree's simulator, delete its DerivedData
  prune                        Release worktrees that no longer exist, retry deletes

Results go to stdout, status and build output to stderr.
Exit 75 (SIMH_COMPILATION_CACHE_CORRUPT): the cache was emptied; run the command again.
"""

func status(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

struct Arguments {
    var values: [String]

    mutating func flag(_ name: String) -> Bool {
        guard let i = values.firstIndex(of: name) else { return false }
        values.remove(at: i)
        return true
    }

    mutating func option(_ name: String) throws -> String? {
        guard let i = values.firstIndex(of: name) else { return nil }
        guard i + 1 < values.count else { throw HelperError(.usage, "\(name) needs a value.") }
        let value = values[i + 1]
        values.removeSubrange(i...(i + 1))
        return value
    }

    func expectEmpty() throws {
        if let extra = values.first { throw HelperError(.usage, "Unexpected argument: \(extra)\n\n\(usage)") }
    }
}

let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

func emit<T: Encodable>(_ value: T, json: Bool, text: (T) -> String) throws {
    if json {
        print(String(decoding: try jsonEncoder.encode(value), as: UTF8.self))
    } else {
        print(text(value))
    }
}

func gigabytes(_ bytes: Int64) -> String { String(format: "%.2f GB", Double(bytes) / 1_000_000_000) }

struct EnvReport: Encodable {
    var developerDir: String
    var xcode: String?
    var swiftCaching: Bool
    var compilationCacheSupported: Bool
    var simslim: Bool
    var workspace: Workspace?
    var derivedData: String?
    var device: OwnedDevice?
    var home: String
}

struct DeviceList: Encodable { var devices: [OwnedDevice] }
struct CacheClearReport: Encodable { var cleared: Bool; var bytes: Int64 }

func run(_ rawArguments: [String], json: Bool) throws {
    var environment = ProcessInfo.processInfo.environment
    let developerDir = try DeveloperDirectory.resolve(environment: environment)
    environment["DEVELOPER_DIR"] = developerDir

    let runner = ProcessRunner(environment: environment)
    let paths = Paths.standard(environment: environment)
    let maxParked = environment["SIM_HELPER_MAX_PARKED"].flatMap { Int($0) } ?? 3
    let devices = DeviceManager(paths: paths, runner: runner, maxParked: maxParked, log: status)
    let cleaner = WorkspaceCleaner(paths: paths, devices: devices)
    let cwd = FileManager.default.currentDirectoryPath

    var args = Arguments(values: rawArguments)
    guard !args.values.isEmpty else { throw HelperError(.usage, usage) }
    let command = args.values.removeFirst()

    switch command {
    case "env":
        try args.expectEmpty()
        let toolchain = Toolchain.detect(runner: runner)
        let workspace = try? Workspace.containing(cwd, runner: runner)
        let device = try devices.list().first { $0.workspace == workspace?.id && $0.state == .assigned }
        let report = EnvReport(
            developerDir: developerDir,
            xcode: toolchain.xcodeVersion,
            swiftCaching: toolchain.supportsSwiftCaching,
            compilationCacheSupported: toolchain.supportsCompilationCache,
            simslim: runner.run("which", ["simslim"]).ok,
            workspace: workspace,
            derivedData: workspace?.derivedData(in: paths),
            device: device,
            home: paths.home)
        try emit(report, json: json) { r in
            """
            xcode        \(r.xcode ?? "unknown") (\(r.developerDir))
            cache        \(r.compilationCacheSupported ? (r.swiftCaching ? "clang and swift" : "clang only") : "unsupported")
            simslim      \(r.simslim ? "installed" : "not installed")
            worktree     \(r.workspace?.root ?? "none")
            derived data \(r.derivedData ?? "none")
            simulator    \(r.device.map { "\($0.name) \($0.udid)" } ?? "none")
            """
        }

    case "sim":
        guard !args.values.isEmpty else { throw HelperError(.usage, usage) }
        switch args.values.removeFirst() {
        case "acquire":
            var options = AcquireOptions()
            options.deviceType = try args.option("--device-type")
            options.runtime = try args.option("--runtime")
            options.slimExcept = try args.option("--slim-except")
            options.boot = !args.flag("--no-boot")
            options.slim = !args.flag("--no-slim")
            try args.expectEmpty()
            let device = try devices.acquire(try Workspace.containing(cwd, runner: runner), options)
            try emit(device, json: json) { $0.udid }
        case "targets":
            try args.expectEmpty()
            let listing = listTargets(runtimes: try Simctl(runner: runner).runtimes())
            try emit(listing, json: json) { l in
                l.runtimes.map { runtime -> String in
                    let types = runtime.deviceTypes.map { type -> String in
                        let isDefault = l.defaultTarget == TargetListing.Default(deviceType: type.identifier, runtime: runtime.identifier)
                        return "  \(type.name)\(isDefault ? "  (default)" : "")"
                    }
                    return (["iOS \(runtime.version)  \(runtime.identifier)"] + types).joined(separator: "\n")
                }.joined(separator: "\n")
            }
        case "list":
            try args.expectEmpty()
            try emit(DeviceList(devices: try devices.list()), json: json) { list in
                list.devices.map { "\($0.udid)  \($0.name)  \($0.state.rawValue)  \($0.workspace ?? "-")" }.joined(separator: "\n")
            }
        default:
            throw HelperError(.usage, usage)
        }

    case "build":
        let split = args.values.firstIndex(of: "--")
        var own = Arguments(values: Array(args.values[..<(split ?? args.values.endIndex)]))
        let xcodebuildArgs = split.map { Array(args.values[($0 + 1)...]) } ?? []
        let useCache = !own.flag("--no-cache")
        try own.expectEmpty()
        guard !xcodebuildArgs.isEmpty else { throw HelperError(.usage, "build needs xcodebuild arguments after --.") }
        let builder = Builder(paths: paths, runner: runner, devices: devices, log: status)
        let result = try builder.build(try Workspace.containing(cwd, runner: runner), xcodebuildArgs: xcodebuildArgs, useCache: useCache)
        if result.swiftTargetsWithoutExplicitModules > 0 {
            status("warning: \(result.swiftTargetsWithoutExplicitModules) Swift target(s) skipped the compilation cache: they need SWIFT_ENABLE_EXPLICIT_MODULES=YES")
        }
        try emit(result, json: json) { r in
            let cache = r.cacheActivity.map { "\($0.hits) hits / \($0.cacheableTasks) cacheable tasks" } ?? (r.compilationCache ? "no activity reported" : "off")
            return "derived data \(r.derivedData)\nsimulator    \(r.udid ?? "caller's destination")\ncache        \(cache)"
        }

    case "cache":
        guard !args.values.isEmpty else { throw HelperError(.usage, usage) }
        let cache = CompilationCache(paths: paths)
        switch args.values.removeFirst() {
        case "status":
            try args.expectEmpty()
            try emit(try cache.status(), json: json) { "\($0.path)  \(gigabytes($0.bytes))\($0.inUse ? "  in use" : "")" }
        case "clear":
            let limit = try args.option("--if-over-gb").map { text -> Double in
                guard let value = Double(text), value >= 0 else { throw HelperError(.usage, "--if-over-gb needs a number.") }
                return value
            }
            try args.expectEmpty()
            let before = try cache.status().bytes
            let over = limit.map { Double(before) > $0 * 1_000_000_000 } ?? true
            if over { try cache.clear() }
            try emit(CacheClearReport(cleared: over, bytes: before), json: json) { r in
                r.cleared ? "emptied \(gigabytes(r.bytes))" : "kept \(gigabytes(r.bytes)), under the limit"
            }
        default:
            throw HelperError(.usage, usage)
        }

    case "release":
        let path = args.values.isEmpty ? nil : args.values.removeFirst()
        try args.expectEmpty()
        let workspace: Workspace
        if let path, !FileManager.default.fileExists(atPath: path) {
            // The worktree may already be removed, so git cannot be asked about it.
            let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
            guard let known = Workspace.all(in: paths).first(where: { $0.root == absolute || $0.root == "/private" + absolute }) else {
                throw HelperError(.unknownWorkspace, "No recorded workspace at \(path).")
            }
            workspace = known
        } else {
            workspace = try Workspace.containing(path ?? cwd, runner: runner)
        }
        try emit(try cleaner.release(workspace), json: json) { r in
            "released \(r.workspace)" + (r.parked.map { ", parked \($0)" } ?? "") + r.deleted.map { ", deleted \($0)" }.joined()
        }

    case "prune":
        try args.expectEmpty()
        let report = cleaner.prune()
        try emit(report, json: json) { r in
            let lines = r.released.map { "released \($0.workspace)" + ($0.parked.map { ", parked \($0)" } ?? "") + $0.deleted.map { ", deleted \($0)" }.joined() }
                + r.deleted.map { "deleted \($0)" }
                + r.skippedBusy.map { "skipped \($0): build running" }
                + r.failures.map { "failed: \($0)" }
            return lines.isEmpty ? "nothing to prune" : lines.joined(separator: "\n")
        }
        if !report.failures.isEmpty { exit(1) }

    case "help", "--help", "-h":
        print(usage)

    default:
        throw HelperError(.usage, "Unknown command \(command).\n\n\(usage)")
    }
}

installSignalForwarding()
var arguments = Arguments(values: Array(CommandLine.arguments.dropFirst()))
// Everything after -- belongs to xcodebuild, including a literal --json.
let separator = arguments.values.firstIndex(of: "--") ?? arguments.values.endIndex
let json = arguments.values[..<separator].contains("--json")
if let i = arguments.values[..<separator].firstIndex(of: "--json") { arguments.values.remove(at: i) }

do {
    try run(arguments.values, json: json)
} catch let error as HelperError {
    if json {
        struct Failure: Encodable { var ok = false; var code: String; var message: String; var remedy: String?; var available: [String]? }
        let failure = Failure(code: error.code.rawValue, message: error.message, remedy: error.remedy, available: error.available)
        print(String(decoding: try jsonEncoder.encode(failure), as: UTF8.self))
    } else {
        status("\(error.code.rawValue): \(error.message)")
        if let remedy = error.remedy { status(remedy) }
        if let available = error.available { status("Available: \(available.joined(separator: ", "))") }
    }
    exit(error.exitCode)
} catch {
    status("error: \(error)")
    exit(1)
}
