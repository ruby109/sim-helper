import Foundation

/// The help text, kept as data so `--json` can return it and tests can check it
/// against the error codes and flags the CLI actually has.
public enum Help {
    public static let version = "0.1.2"

    public struct Option: Encodable, Equatable {
        public var flag: String
        public var value: String?
        public var summary: String
    }

    public struct Command: Encodable, Equatable {
        public var command: String
        public var summary: String
        public var usage: String
        public var options: [Option] = []
        public var output: String
        public var errors: [String] = []
        public var notes: [String] = []
        public var examples: [String] = []
    }

    public struct ErrorEntry: Encodable, Equatable {
        public var code: String
        public var exitCode: String
        public var meaning: String
        public var action: String
    }

    public static let commands: [Command] = [
        Command(
            command: "env",
            summary: "Show this worktree's paths, simulator, and toolchain",
            usage: "sim-helper env [--json]",
            output: "Text, or JSON with developerDir, xcode, swiftCaching, compilationCacheSupported, simslim, workspace, derivedData, device, and home. workspace and device are null outside a worktree or before `sim acquire`.",
            errors: ["SIMH_NO_XCODE", "SIMH_STATE_CORRUPT"],
            examples: ["sim-helper env --json"]),
        Command(
            command: "sim acquire",
            summary: "Give this worktree its simulator, booted, slimmed, and verified",
            usage: "sim-helper sim acquire [options] [--json]",
            options: [
                Option(flag: "--device-type", value: "<name>", summary: "Name or identifier from `sim targets` (default: newest iPhone Pro)"),
                Option(flag: "--runtime", value: "<version>", summary: "Version or identifier from `sim targets` (default: newest iOS)"),
                Option(flag: "--no-boot", summary: "Allocate without booting; skips SimSlim"),
                Option(flag: "--no-slim", summary: "Use a stock simulator; SimSlim is not needed"),
                Option(flag: "--slim-except", value: "<list>", summary: "SimSlim categories to keep, e.g. push,storekit; `simslim profiles` lists them"),
            ],
            output: "The simulator's UDID. With --json, the device record: udid, name, deviceType, runtime, state, workspace, slimmed, parkedAt.",
            errors: ["SIMH_NOT_IN_GIT_REPO", "SIMH_NO_RUNTIME", "SIMH_NO_DEVICE_TYPE", "SIMH_SIMSLIM_MISSING", "SIMH_BOOT_STUCK", "SIMH_SIMCTL_FAILED"],
            notes: [
                "A worktree gets the same simulator every time. The first acquire creates, boots, and slims it, which can take a few minutes; later ones take seconds.",
                "Reuses a parked simulator with the same device type and runtime before creating a new one.",
                "Device type and runtime only apply when the simulator is allocated; to change them, run `release` first.",
            ],
            examples: [
                "sim-helper sim acquire",
                "sim-helper sim acquire --device-type \"iPhone 16 Pro\" --runtime 18.0 --json",
            ]),
        Command(
            command: "sim targets",
            summary: "List the runtimes and device types acquire accepts",
            usage: "sim-helper sim targets [--json]",
            output: "Each iOS runtime with its iPhone and iPad types, the default marked. With --json: {defaultTarget: {deviceType, runtime}, runtimes: [{identifier, version, deviceTypes: [{identifier, name}]}]}.",
            errors: ["SIMH_SIMCTL_FAILED"],
            examples: ["sim-helper sim targets --json"]),
        Command(
            command: "sim list",
            summary: "List the simulators this tool owns",
            usage: "sim-helper sim list [--json]",
            output: "One line per simulator: udid, name, state (assigned, parked, or deleting), and workspace. With --json: {devices: [...]}, using the same record as `sim acquire`.",
            errors: ["SIMH_STATE_CORRUPT"],
            examples: ["sim-helper sim list --json"]),
        Command(
            command: "build",
            summary: "Run xcodebuild with this worktree's DerivedData and simulator and the shared cache",
            usage: "sim-helper build [--no-cache] [--json] -- <xcodebuild args>",
            options: [
                Option(flag: "--no-cache", summary: "Build without the shared compilation cache"),
            ],
            output: "xcodebuild's output streams to stderr and to a log file. On success: derivedData, udid, log, compilationCache, cacheActivity {hits, cacheableTasks}, and swiftTargetsWithoutExplicitModules.",
            errors: ["SIMH_BUILD_FAILED", "SIMH_COMPILATION_CACHE_CORRUPT", "SIMH_WORKSPACE_BUSY", "SIMH_NOT_IN_GIT_REPO"],
            notes: [
                "Adds -derivedDataPath and -destination for this worktree unless you pass them. Without a simulator, it allocates one but leaves booting to xcodebuild, so it is not slimmed or verified: run `sim acquire` first.",
                "Everything after -- goes to xcodebuild unchanged, including any --json. With -list, nothing is added.",
            ],
            examples: [
                "sim-helper build -- -scheme App build",
                "sim-helper build -- -workspace App.xcworkspace -scheme App test -only-testing:AppTests",
            ]),
        Command(
            command: "cache status",
            summary: "Show the shared compilation cache's size and whether a build is using it",
            usage: "sim-helper cache status [--json]",
            output: "Path, size, and whether it is in use. With --json: {path, bytes, inUse}.",
            errors: ["SIMH_STATE_CORRUPT"],
            examples: ["sim-helper cache status --json"]),
        Command(
            command: "cache clear",
            summary: "Empty the shared compilation cache",
            usage: "sim-helper cache clear [--if-over-gb <N>] [--json]",
            options: [
                Option(flag: "--if-over-gb", value: "<N>", summary: "Only clear when the cache is larger than N GB"),
            ],
            output: "Whether it was cleared and its size before. With --json: {cleared, bytes}.",
            errors: ["SIMH_COMPILATION_CACHE_BUSY"],
            notes: ["Refused while any build is using the cache. The next build of every worktree is cold."],
            examples: ["sim-helper cache clear --if-over-gb 20"]),
        Command(
            command: "release",
            summary: "Park the worktree's simulator and delete its DerivedData",
            usage: "sim-helper release [<path>] [--json]",
            output: "The workspace id, the parked UDID, and deleted paths. With --json: {workspace, parked, deleted}.",
            errors: ["SIMH_WORKSPACE_BUSY", "SIMH_UNKNOWN_WORKSPACE", "SIMH_DELETE_FAILED"],
            notes: [
                "Run it before removing a worktree. <path> defaults to the current worktree and may be one that was already removed.",
                "Parked simulators keep their installed apps; up to SIM_HELPER_MAX_PARKED are kept for reuse.",
            ],
            examples: ["sim-helper release", "sim-helper release ../feature-x"]),
        Command(
            command: "prune",
            summary: "Release worktrees that no longer exist and retry failed deletes",
            usage: "sim-helper prune [--json]",
            output: "What was released, deleted, skipped because a build was running, or failed. Exits 1 if anything failed.",
            errors: ["SIMH_STATE_CORRUPT"],
            examples: ["sim-helper prune --json"]),
    ]

    public static let errors: [ErrorEntry] = [
        ErrorEntry(code: "SIMH_USAGE", exitCode: "64", meaning: "Unknown command or option, or a missing value", action: "Use `available` or the suggestion in the message; `sim-helper help <command>` lists options"),
        ErrorEntry(code: "SIMH_NO_XCODE", exitCode: "1", meaning: "No usable Xcode", action: "Install Xcode 26 or later, or set DEVELOPER_DIR to its Contents/Developer"),
        ErrorEntry(code: "SIMH_NOT_IN_GIT_REPO", exitCode: "1", meaning: "The current directory is not in a git worktree", action: "Run the command inside the worktree"),
        ErrorEntry(code: "SIMH_NO_RUNTIME", exitCode: "1", meaning: "No installed iOS runtime matches --runtime", action: "Pick one from `available`, or install one with `xcodebuild -downloadPlatform iOS`"),
        ErrorEntry(code: "SIMH_NO_DEVICE_TYPE", exitCode: "1", meaning: "The runtime does not support --device-type", action: "Pick one from `available`, or run `sim targets`"),
        ErrorEntry(code: "SIMH_SIMSLIM_MISSING", exitCode: "1", meaning: "SimSlim is not installed", action: "`brew install mobai-app/tap/simslim`, or pass --no-slim"),
        ErrorEntry(code: "SIMH_BOOT_STUCK", exitCode: "1", meaning: "The simulator reports booted but cannot launch a process", action: "Usually memory pressure or too many first boots at once; wait, then retry. Deleting the UDID in the message makes the next acquire create a new one"),
        ErrorEntry(code: "SIMH_SIMCTL_FAILED", exitCode: "1", meaning: "A simctl command failed or timed out", action: "Read the message; retry once, then check `xcrun simctl list`"),
        ErrorEntry(code: "SIMH_BUILD_FAILED", exitCode: "xcodebuild's", meaning: "An ordinary build or test failure", action: "Read the log at the path in `remedy`"),
        ErrorEntry(code: "SIMH_COMPILATION_CACHE_CORRUPT", exitCode: "75", meaning: "The cache was corrupt and has been emptied", action: "Run the same command again; it will be a cold build"),
        ErrorEntry(code: "SIMH_COMPILATION_CACHE_CORRUPT", exitCode: "1", meaning: "The cache is corrupt but other builds are using it", action: "Wait for them, run `sim-helper cache clear`, then rerun"),
        ErrorEntry(code: "SIMH_COMPILATION_CACHE_BUSY", exitCode: "1", meaning: "A build is using the cache, so it was not cleared", action: "Retry after the build finishes"),
        ErrorEntry(code: "SIMH_WORKSPACE_BUSY", exitCode: "1", meaning: "A build is running in this worktree", action: "Retry after it finishes"),
        ErrorEntry(code: "SIMH_UNKNOWN_WORKSPACE", exitCode: "1", meaning: "No state is recorded for that removed worktree", action: "Nothing to release; `prune` cleans up anything left"),
        ErrorEntry(code: "SIMH_DELETE_FAILED", exitCode: "1", meaning: "A simulator or directory could not be deleted; its record was kept", action: "Run `sim-helper prune` to retry"),
        ErrorEntry(code: "SIMH_STATE_CORRUPT", exitCode: "1", meaning: "State under SIM_HELPER_HOME could not be read or locked", action: "Read the message; check permissions on SIM_HELPER_HOME"),
    ]

    public static let environment: [(name: String, summary: String)] = [
        ("DEVELOPER_DIR", "Xcode to use (default: xcode-select, else the newest Xcode in /Applications)"),
        ("SIM_HELPER_HOME", "State directory (default: ~/.sim-helper); keep it out of /tmp"),
        ("SIM_HELPER_MAX_PARKED", "Released simulators kept for reuse (default: 3)"),
    ]

    /// Top-level command words and the subcommands of each group.
    public static var groups: [String: [String]] {
        var groups: [String: [String]] = [:]
        for command in commands {
            let words = command.command.split(separator: " ").map(String.init)
            if words.count > 1 { groups[words[0], default: []].append(words[1]) }
        }
        return groups
    }

    public static var topLevel: [String] {
        var seen: [String] = []
        for command in commands {
            let first = String(command.command.split(separator: " ")[0])
            if !seen.contains(first) { seen.append(first) }
        }
        return seen + ["help"]
    }

    public static func command(_ name: String) -> Command? {
        commands.first { $0.command == name }
    }

    public static var overview: String {
        let width = commands.map { $0.command.count }.max() ?? 0
        let list = commands.map { "  \($0.command.padding(toLength: width + 2, withPad: " ", startingAt: 0))\($0.summary)" }
        let env = environment.map { "  \($0.name.padding(toLength: 23, withPad: " ", startingAt: 0))\($0.summary)" }
        return """
        sim-helper \(version): per-worktree iOS simulators and DerivedData with a shared Xcode compilation cache

        usage: sim-helper <command> [options] [--json]

        Typical flow, inside a git worktree:
          sim-helper sim acquire                     boot this worktree's simulator, print its UDID
          sim-helper build -- -scheme App test       adds -destination and -derivedDataPath for you
          sim-helper release                         before removing the worktree

        Commands:
        \(list.joined(separator: "\n"))

        Every command accepts --json. Results go to stdout; progress and build output to stderr.
        Failures exit non-zero with a stable SIMH_* code. With --json they print
        {ok, code, message, remedy, available}. Exit 75: the cache was emptied, so rerun the command.

        On a 16 GB Mac, 2-3 simulators at once were stable; acquiring 4 together made some fail.

        Environment:
        \(env.joined(separator: "\n"))

        More:
          sim-helper help <command>    options, output, errors, and examples (or: <command> --help)
          sim-helper help errors       every error code and what to do
          sim-helper --version
        """
    }

    public static func text(_ command: Command) -> String {
        var lines = ["usage: \(command.usage)", "", command.summary + "."]
        if !command.options.isEmpty {
            let labels = command.options.map { $0.flag + ($0.value.map { " " + $0 } ?? "") }
            let width = labels.map(\.count).max() ?? 0
            lines += ["", "Options:"] + zip(labels, command.options).map {
                "  \($0.padding(toLength: width + 2, withPad: " ", startingAt: 0))\($1.summary)"
            }
        }
        lines += ["", "Output:", "  " + command.output]
        if !command.notes.isEmpty { lines += ["", "Notes:"] + command.notes.map { "  - " + $0 } }
        if !command.errors.isEmpty { lines += ["", "Errors (details: sim-helper help errors):", "  " + command.errors.joined(separator: ", ")] }
        if !command.examples.isEmpty { lines += ["", "Examples:"] + command.examples.map { "  " + $0 } }
        return lines.joined(separator: "\n")
    }

    public static func groupText(_ group: String) -> String {
        let members = commands.filter { $0.command.hasPrefix(group + " ") }
        let width = members.map { $0.command.count }.max() ?? 0
        return (["usage: sim-helper \(group) <subcommand> [options] [--json]", ""]
            + members.map { "  \($0.command.padding(toLength: width + 2, withPad: " ", startingAt: 0))\($0.summary)" }
            + ["", "Details: sim-helper help \(group) <subcommand>"]).joined(separator: "\n")
    }

    public static var errorsText: String {
        errors.map { e in
            "\(e.code) (exit \(e.exitCode))\n  \(e.meaning).\n  What to do: \(e.action)."
        }.joined(separator: "\n\n")
    }

    /// The closest candidate, if one is close enough to be a likely typo.
    public static func suggestion(for input: String, among candidates: [String]) -> String? {
        let scored = candidates.map { ($0, distance(input.lowercased(), $0.lowercased())) }
        guard let best = scored.min(by: { $0.1 < $1.1 }) else { return nil }
        let allowed = max(1, min(3, best.0.count / 3))
        return best.1 <= allowed ? best.0 : nil
    }

    /// Edit distance where swapping two adjacent letters, a common typo, counts as one edit.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var d = (0...a.count).map { i in (0...b.count).map { j in i == 0 ? j : (j == 0 ? i : 0) } }
        for i in 1...a.count {
            for j in 1...b.count {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }
}
