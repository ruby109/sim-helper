import CryptoKit
import Foundation

/// Where all helper state lives. Nothing is written inside a worktree.
public struct Paths {
    public var home: String

    public init(home: String) { self.home = home }

    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        if let home = environment["SIM_HELPER_HOME"], !home.isEmpty { return Paths(home: home) }
        return Paths(home: NSHomeDirectory() + "/.sim-helper")
    }

    public var workspaces: String { home + "/workspaces" }
    public var registry: String { home + "/devices.json" }
    public var registryLock: String { home + "/locks/devices.lock" }
    public var compilationCache: String { home + "/compilation-cache" }
    public var compilationCacheLock: String { home + "/locks/compilation-cache.lock" }

    // Locks stay outside workspace directories: unlinking a lock file another
    // process is waiting on would let two holders in at once.
    public func workspaceLock(_ id: String) -> String { home + "/locks/workspace-\(id).lock" }
}

public struct Workspace: Codable, Equatable {
    public var id: String
    public var root: String

    public init(root: String) {
        self.root = root
        self.id = Self.id(forRoot: root)
    }

    public static func id(forRoot root: String) -> String {
        let hash = SHA256.hash(data: Data(root.utf8)).map { String(format: "%02x", $0) }.joined()
        let base = (root as NSString).lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        return "\(base)-\(hash.prefix(12))"
    }

    public func directory(in paths: Paths) -> String { "\(paths.workspaces)/\(id)" }
    public func derivedData(in paths: Paths) -> String { directory(in: paths) + "/DerivedData" }
    public func buildLog(in paths: Paths) -> String { directory(in: paths) + "/last-build.log" }

    /// The worktree containing `directory`. Every worktree has its own toplevel,
    /// so each gets its own id.
    public static func containing(_ directory: String, runner: CommandRunner) throws -> Workspace {
        let result = runner.run("git", ["-C", directory, "rev-parse", "--show-toplevel"])
        let top = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.ok, !top.isEmpty else {
            throw HelperError(.notInGitRepo, "\(directory) is not inside a git worktree.")
        }
        return Workspace(root: realPath(top))
    }

    public func record(in paths: Paths) throws {
        let dir = directory(in: paths)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: URL(fileURLWithPath: dir + "/workspace.json"), options: .atomic)
    }

    /// Every workspace with recorded state, including ones whose worktree is gone.
    public static func all(in paths: Paths) -> [Workspace] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.workspaces)) ?? []
        return names.sorted().compactMap { name in
            guard let data = FileManager.default.contents(atPath: "\(paths.workspaces)/\(name)/workspace.json") else { return nil }
            return try? JSONDecoder().decode(Workspace.self, from: data)
        }
    }
}

public func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
    defer { free(resolved) }
    return String(cString: resolved)
}
