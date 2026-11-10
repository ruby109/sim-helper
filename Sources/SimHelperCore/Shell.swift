import Foundation

public struct CommandResult: Equatable {
    public var status: Int32
    public var output: String
    public var timedOut: Bool

    public init(status: Int32 = 0, output: String = "", timedOut: Bool = false) {
        self.status = status
        self.output = output
        self.timedOut = timedOut
    }

    public var ok: Bool { status == 0 && !timedOut }
}

/// Runs external tools. Tests substitute a fake.
public protocol CommandRunner {
    /// Stdout and stderr are merged. `onLine` receives each line as it arrives.
    func run(_ executable: String, _ args: [String], timeout: TimeInterval?, onLine: ((String) -> Void)?) -> CommandResult
}

extension CommandRunner {
    public func run(_ executable: String, _ args: [String], timeout: TimeInterval? = nil) -> CommandResult {
        run(executable, args, timeout: timeout, onLine: nil)
    }
}

// The pid signal handlers forward to. A killed helper must not leave xcodebuild
// compiling with its claim on the compilation cache already released, so with a
// child running the helper only forwards the signal and dies once the child exits.
private var forwardedChildPid: pid_t = 0
private var pendingSignal: Int32 = 0

public func installSignalForwarding() {
    let handler: @convention(c) (Int32) -> Void = { sig in
        guard forwardedChildPid > 0 else { dieFromSignal(sig) }
        pendingSignal = sig
        kill(forwardedChildPid, sig)
    }
    signal(SIGINT, handler)
    signal(SIGTERM, handler)
    signal(SIGHUP, handler)
}

/// Exits the way the signal would have, so callers see the usual status.
private func dieFromSignal(_ sig: Int32) -> Never {
    signal(sig, SIG_DFL)
    raise(sig)
    _exit(128 + sig)
}

public struct ProcessRunner: CommandRunner {
    public var environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func run(_ executable: String, _ args: [String], timeout: TimeInterval?, onLine: ((String) -> Void)?) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + args
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let collector = LineCollector(onLine: onLine)
        let eof = DispatchGroup()
        eof.enter()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                eof.leave()
            } else {
                collector.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return CommandResult(status: 127, output: "could not run \(executable): \(error)")
        }
        forwardedChildPid = process.processIdentifier

        let timeoutFlag = LockedFlag()
        var killer: DispatchWorkItem?
        if let timeout {
            let item = DispatchWorkItem {
                guard process.isRunning else { return }
                timeoutFlag.set()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            killer = item
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
        }
        process.waitUntilExit()
        killer?.cancel()
        forwardedChildPid = 0
        if pendingSignal != 0 { dieFromSignal(pendingSignal) }
        // A daemon the tool spawned can inherit the pipe and hold it open forever.
        _ = eof.wait(timeout: .now() + 2)
        pipe.fileHandleForReading.readabilityHandler = nil
        return CommandResult(status: process.terminationStatus, output: collector.finish(), timedOut: timeoutFlag.value)
    }
}

private final class LockedFlag {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

private final class LineCollector {
    private let lock = NSLock()
    private let onLine: ((String) -> Void)?
    private var all = Data()
    private var partial = Data()

    init(onLine: ((String) -> Void)?) { self.onLine = onLine }

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        // Long builds print gigabytes only when streamed; the caller has the lines.
        if onLine == nil { all.append(data); return }
        partial.append(data)
        while let newline = partial.firstIndex(of: 0x0A) {
            let line = partial[partial.startIndex..<newline]
            onLine?(String(decoding: line, as: UTF8.self))
            partial = Data(partial[partial.index(after: newline)...])
        }
    }

    func finish() -> String {
        lock.lock(); defer { lock.unlock() }
        if !partial.isEmpty { onLine?(String(decoding: partial, as: UTF8.self)); partial = Data() }
        return String(decoding: all, as: UTF8.self)
    }
}

/// Locates the Xcode to drive. `xcode-select` often points at the command line
/// tools, which have neither simctl nor xcodebuild, so fall back to /Applications.
public enum DeveloperDirectory {
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        selected: () -> String? = selectedPath,
        applicationsDir: String = "/Applications"
    ) throws -> String {
        if let dir = environment["DEVELOPER_DIR"], !dir.isEmpty {
            guard hasXcodebuild(dir) else {
                throw HelperError(.noXcode, "DEVELOPER_DIR=\(dir) has no xcodebuild.", remedy: "Point DEVELOPER_DIR at an Xcode's Contents/Developer.")
            }
            return dir
        }
        if let dir = selected(), hasXcodebuild(dir) { return dir }
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: applicationsDir)) ?? []
        // Ordered by the version inside each app: names lie, e.g. Xcode.app
        // symlinked to an older install.
        let candidates = apps
            .filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
            .map { "\(applicationsDir)/\($0)" }
            .filter { hasXcodebuild($0 + "/Contents/Developer") }
            .compactMap { app in version(ofApp: app).map { (app, $0) } }
        if let newest = candidates.max(by: { $0.1.compare($1.1, options: .numeric) == .orderedAscending }) {
            return newest.0 + "/Contents/Developer"
        }
        throw HelperError(.noXcode, "No Xcode found.", remedy: "Install Xcode 26 or later, or set DEVELOPER_DIR to its Contents/Developer.")
    }

    static func version(ofApp app: String) -> String? {
        guard let plist = NSDictionary(contentsOfFile: app + "/Contents/Info.plist") else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    private static func hasXcodebuild(_ dir: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: "\(dir)/usr/bin/xcodebuild")
    }

    public static func selectedPath() -> String? {
        let result = ProcessRunner().run("xcode-select", ["-p"])
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok && !path.isEmpty ? path : nil
    }
}
