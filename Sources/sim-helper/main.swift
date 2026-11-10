import Foundation
import SimHelperCore

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
        guard i + 1 < values.count else { throw HelperError(.usage, "\(name) needs a value.", remedy: "Run `sim-helper help <command>` for its options.") }
        let value = values[i + 1]
        values.removeSubrange(i...(i + 1))
        return value
    }

    func expectEmpty(_ command: String) throws {
        guard let extra = values.first else { return }
        let flags = (Help.command(command)?.options.map(\.flag) ?? []) + ["--json", "--help"]
        let hint = Help.suggestion(for: extra, among: flags).map { " Did you mean '\($0)'?" } ?? ""
        throw HelperError(.usage, "Unexpected argument '\(extra)' for \(command).\(hint)",
                          remedy: "Run `sim-helper help \(command)` for its options.", available: flags)
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
    guard !args.values.isEmpty else { throw missingCommand(nil) }
    let command = args.values.removeFirst()

    switch command {
    case "env":
        try args.expectEmpty("env")
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
        guard !args.values.isEmpty else { throw missingCommand("sim") }
        switch args.values.removeFirst() {
        case "acquire":
            var options = AcquireOptions()
            options.deviceType = try args.option("--device-type")
            options.runtime = try args.option("--runtime")
            options.slimExcept = try args.option("--slim-except")
            options.boot = !args.flag("--no-boot")
            options.slim = !args.flag("--no-slim")
            try args.expectEmpty("sim acquire")
            let device = try devices.acquire(try Workspace.containing(cwd, runner: runner), options)
            try emit(device, json: json) { $0.udid }
        case "targets":
            try args.expectEmpty("sim targets")
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
            try args.expectEmpty("sim list")
            try emit(DeviceList(devices: try devices.list()), json: json) { list in
                list.devices.map { "\($0.udid)  \($0.name)  \($0.state.rawValue)  \($0.workspace ?? "-")" }.joined(separator: "\n")
            }
        case let other:
            throw unknownCommand(other, in: "sim")
        }

    case "build":
        let split = args.values.firstIndex(of: "--")
        var own = Arguments(values: Array(args.values[..<(split ?? args.values.endIndex)]))
        let xcodebuildArgs = split.map { Array(args.values[($0 + 1)...]) } ?? []
        let useCache = !own.flag("--no-cache")
        try own.expectEmpty("build")
        guard !xcodebuildArgs.isEmpty else { throw HelperError(.usage, "build needs xcodebuild arguments after --.", remedy: "For example: sim-helper build -- -scheme App build") }
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
        guard !args.values.isEmpty else { throw missingCommand("cache") }
        let cache = CompilationCache(paths: paths)
        switch args.values.removeFirst() {
        case "status":
            try args.expectEmpty("cache status")
            try emit(try cache.status(), json: json) { "\($0.path)  \(gigabytes($0.bytes))\($0.inUse ? "  in use" : "")" }
        case "clear":
            let limit = try args.option("--if-over-gb").map { text -> Double in
                guard let value = Double(text), value >= 0 else { throw HelperError(.usage, "--if-over-gb needs a number.") }
                return value
            }
            try args.expectEmpty("cache clear")
            let before = try cache.status().bytes
            let over = limit.map { Double(before) > $0 * 1_000_000_000 } ?? true
            if over { try cache.clear() }
            try emit(CacheClearReport(cleared: over, bytes: before), json: json) { r in
                r.cleared ? "emptied \(gigabytes(r.bytes))" : "kept \(gigabytes(r.bytes)), under the limit"
            }
        case let other:
            throw unknownCommand(other, in: "cache")
        }

    case "release":
        let path = args.values.first.map { $0.hasPrefix("-") ? nil : $0 } ?? nil
        if path != nil { args.values.removeFirst() }
        try args.expectEmpty("release")
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
        try args.expectEmpty("prune")
        let report = cleaner.prune()
        try emit(report, json: json) { r in
            let lines = r.released.map { "released \($0.workspace)" + ($0.parked.map { ", parked \($0)" } ?? "") + $0.deleted.map { ", deleted \($0)" }.joined() }
                + r.deleted.map { "deleted \($0)" }
                + r.skippedBusy.map { "skipped \($0): build running" }
                + r.failures.map { "failed: \($0)" }
            return lines.isEmpty ? "nothing to prune" : lines.joined(separator: "\n")
        }
        if !report.failures.isEmpty { exit(1) }

    default:
        throw unknownCommand(command, in: nil)
    }
}

func unknownCommand(_ word: String, in group: String?) -> HelperError {
    // Match on the last word so `sim-helper aquire` still finds `sim acquire`.
    let candidates: [(key: String, full: String)]
    if let group {
        candidates = (Help.groups[group] ?? []).map { ($0, "\(group) \($0)") }
    } else {
        candidates = Help.topLevel.map { ($0, $0) }
            + Help.commands.map(\.command).filter { $0.contains(" ") }.map { (String($0.split(separator: " ")[1]), $0) }
    }
    let hint = Help.suggestion(for: word, among: candidates.map(\.key)).flatMap { key in candidates.first { $0.key == key }?.full }
    let label = group.map { "\($0) \(word)" } ?? word
    return HelperError(.usage, "Unknown command '\(label)'." + (hint.map { " Did you mean '\($0)'?" } ?? ""),
                       remedy: "Run `sim-helper help\(group.map { " " + $0 } ?? "")` for the commands.",
                       available: group.flatMap { Help.groups[$0] } ?? Help.topLevel)
}

func missingCommand(_ group: String?) -> HelperError {
    guard let group else {
        return HelperError(.usage, "No command given.", remedy: "Run `sim-helper help`.", available: Help.topLevel)
    }
    return HelperError(.usage, "\(group) needs a subcommand.", remedy: "Run `sim-helper help \(group)`.", available: Help.groups[group])
}

struct HelpOverview: Encodable {
    struct Variable: Encodable { var name: String; var summary: String }
    var version = Help.version
    var commands = Help.commands
    var environment = Help.environment.map { Variable(name: $0.name, summary: $0.summary) }
    var errors = Help.errors
}

/// `help [words]` and `<words> --help`. Handled before Xcode is looked up, so it
/// works on a machine without one.
func printHelp(_ words: [String], json: Bool) throws {
    let name = words.joined(separator: " ")
    if words.isEmpty {
        try emit(HelpOverview(), json: json) { _ in Help.overview }
    } else if name == "errors" {
        struct Errors: Encodable { var errors: [Help.ErrorEntry] }
        try emit(Errors(errors: Help.errors), json: json) { _ in Help.errorsText }
    } else if let command = Help.command(name) {
        try emit(command, json: json) { Help.text($0) }
    } else if words.count == 1, Help.groups[name] != nil {
        struct Group: Encodable { var commands: [Help.Command] }
        try emit(Group(commands: Help.commands.filter { $0.command.hasPrefix(name + " ") }), json: json) { _ in Help.groupText(name) }
    } else {
        throw unknownCommand(words.last!, in: words.count > 1 ? words[0] : nil)
    }
}

installSignalForwarding()
var arguments = Arguments(values: Array(CommandLine.arguments.dropFirst()))
// Everything after -- belongs to xcodebuild, including a literal --json.
let separator = arguments.values.firstIndex(of: "--") ?? arguments.values.endIndex
let json = arguments.values[..<separator].contains("--json")
if let i = arguments.values[..<separator].firstIndex(of: "--json") { arguments.values.remove(at: i) }

// Removing --json moved the separator.
let own = arguments.values[..<(arguments.values.firstIndex(of: "--") ?? arguments.values.endIndex)]

do {
    if own.contains("--version") {
        struct Version: Encodable { var version: String }
        try emit(Version(version: Help.version), json: json) { "sim-helper \($0.version)" }
    } else if own.first == "help" {
        try printHelp(own.dropFirst().filter { !$0.hasPrefix("-") }, json: json)
    } else if own.contains("--help") || own.contains("-h") {
        try printHelp(Array(own.prefix { !$0.hasPrefix("-") }), json: json)
    } else if own.isEmpty, !json {
        status(Help.overview)
        exit(64)
    } else {
        try run(arguments.values, json: json)
    }
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
