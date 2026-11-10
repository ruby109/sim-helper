import Foundation

/// The LLVM on-disk CAS shared by every worktree's builds. Its entries live in
/// shared database files and trimming by age breaks the index, so it is only ever
/// emptied whole. Builds hold a shared lock; emptying needs the exclusive one.
public struct CompilationCache {
    public var paths: Paths

    public init(paths: Paths) { self.paths = paths }

    public var directory: String { paths.compilationCache }

    public struct Status: Encodable, Equatable {
        public var path: String
        public var bytes: Int64
        public var inUse: Bool
    }

    public func claim() throws -> FileLock {
        try attempt(.stateCorrupt, "Could not create \(directory)") {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        return try FileLock.acquire(paths.compilationCacheLock, .shared)
    }

    public func status() throws -> Status {
        // Probe and let go at once: sizing a large cache takes a while, and holding
        // the exclusive lock meanwhile would block builds and fail clears as busy.
        let probe = try FileLock.tryAcquire(paths.compilationCacheLock, .exclusive)
        let inUse = probe == nil
        probe?.release()
        return Status(path: directory, bytes: Self.size(of: directory), inUse: inUse)
    }

    /// Empties the cache. Throws `cacheBusy` while any build holds its claim.
    public func clear() throws {
        let fm = FileManager.default
        do {
            guard let lock = try FileLock.tryAcquire(paths.compilationCacheLock, .exclusive) else {
                throw HelperError(.cacheBusy, "A build is using the compilation cache at \(directory).", remedy: "Retry when the build has finished.")
            }
            defer { lock.release() }
            // Rename first so a crash mid-delete cannot leave a half-empty cache in use.
            // Only the rename needs the lock; deleting gigabytes must not block builds.
            try attempt(.stateCorrupt, "Could not empty \(directory)") {
                if fm.fileExists(atPath: directory) { try fm.moveItem(atPath: directory, toPath: "\(directory).trash-\(getpid())") }
                try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
        }
        // Includes any left by an earlier clear that crashed. Another clear may be
        // deleting the same ones, so a failure here is not an error.
        for name in (try? fm.contentsOfDirectory(atPath: paths.home)) ?? [] where name.hasPrefix("compilation-cache.trash-") {
            try? fm.removeItem(atPath: "\(paths.home)/\(name)")
        }
    }

    /// The validation failure llvm-cas reports, or nil if the store is sound or could
    /// not be checked. A missing tool or a timeout is not evidence of damage.
    public func validationFailure(runner: CommandRunner) -> String? {
        let store = directory + "/builtin"
        guard FileManager.default.fileExists(atPath: store) else { return nil }
        let result = runner.run("xcrun", ["llvm-cas", "--cas", store, "--validate"], timeout: 300)
        guard !result.ok, !result.timedOut, result.output.contains("validate:") else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func size(of path: String) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

public struct Toolchain: Equatable {
    public var xcodeMajor: Int?
    public var xcodeVersion: String?
    public var swiftMajor: Int?
    public var swiftMinor: Int?

    public init(xcodeMajor: Int? = nil, xcodeVersion: String? = nil, swiftMajor: Int? = nil, swiftMinor: Int? = nil) {
        self.xcodeMajor = xcodeMajor
        self.xcodeVersion = xcodeVersion
        self.swiftMajor = swiftMajor
        self.swiftMinor = swiftMinor
    }

    public static func detect(runner: CommandRunner) -> Toolchain {
        var toolchain = Toolchain()
        let xcode = runner.run("xcrun", ["xcodebuild", "-version"], timeout: 60).output
        if let match = xcode.range(of: #"Xcode (\d+)[.\d]*"#, options: .regularExpression) {
            let version = xcode[match].dropFirst("Xcode ".count)
            toolchain.xcodeVersion = String(version)
            toolchain.xcodeMajor = Int(version.split(separator: ".")[0])
        }
        let swift = runner.run("xcrun", ["swift", "--version"], timeout: 60).output
        if let match = swift.range(of: #"Swift version \d+\.\d+"#, options: .regularExpression) {
            let parts = swift[match].dropFirst("Swift version ".count).split(separator: ".")
            toolchain.swiftMajor = Int(parts[0])
            toolchain.swiftMinor = Int(parts[1])
        }
        return toolchain
    }

    /// Xcode 26 introduced compilation caching.
    public var supportsCompilationCache: Bool { (xcodeMajor ?? 0) >= 26 }

    /// swift-frontend crashes on prefix-mapped caching before Swift 6.4, and without
    /// the mapping paths differ per worktree so nothing would ever hit.
    public var supportsSwiftCaching: Bool {
        compareVersions([swiftMajor ?? 0, swiftMinor ?? 0], [6, 4]) >= 0
    }
}

/// Build settings that make worktrees share one cache: absolute paths are mapped to
/// fixed placeholders so the same source in another directory produces the same key.
public func compilationCacheSettings(workspaceRoot: String, derivedData: String, casPath: String, toolchain: Toolchain) -> [String] {
    guard toolchain.supportsCompilationCache else { return [] }
    var mappings = ["\(workspaceRoot)=/^src"]
    if !(derivedData + "/").hasPrefix(workspaceRoot + "/") { mappings.append("\(derivedData)=/^derived-data") }
    let mapped = mappings.map { mapping -> String in
        guard mapping.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\"\\")) != nil else { return mapping }
        return "\"" + mapping.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }.joined(separator: " ")
    var settings = [
        "COMPILATION_CACHE_ENABLE_CACHING=YES",
        "COMPILATION_CACHE_CAS_PATH=\(casPath)",
        "CLANG_ENABLE_PREFIX_MAPPING=YES",
        "CLANG_OTHER_PREFIX_MAPPINGS=\(mapped)",
    ]
    if toolchain.supportsSwiftCaching {
        settings += ["SWIFT_ENABLE_COMPILE_CACHE=YES", "SWIFT_ENABLE_PREFIX_MAPPING=YES", "SWIFT_OTHER_PREFIX_MAPPINGS=\(mapped)"]
    } else {
        settings += ["SWIFT_ENABLE_COMPILE_CACHE=NO", "SWIFT_ENABLE_PREFIX_MAPPING=NO"]
    }
    return settings
}

public struct CacheActivity: Encodable, Equatable {
    public var hits: Int
    public var cacheableTasks: Int
}

public enum BuildOutput {
    /// The compiler's own reports of a damaged object in its CAS.
    public static func isCorruption(_ line: String) -> Bool {
        ["OnDiskCAS: corrupt internal reference", "CAS operation failed", "not a IncludeTreeRoot node kind"].contains { line.contains($0) }
    }

    /// A damaged CAS can also segfault the build service inside OnDiskCAS, leaving only
    /// this. Other crashes print the same line, so it is a reason to validate, not proof.
    public static func isBuildServiceCrash(_ line: String) -> Bool {
        line.contains("The Xcode build system has crashed")
    }

    public static func needsExplicitModules(_ line: String) -> Bool {
        line.contains("swift compiler caching requires explicit module build")
    }

    /// Parses Xcode's "12 hits / 34 cacheable tasks (35%)" summary.
    public static func activity(_ line: String) -> CacheActivity? {
        guard let range = line.range(of: #"\d+ hits? / \d+ cacheable tasks"#, options: .regularExpression) else { return nil }
        let numbers = line[range].split(separator: " ").compactMap { Int($0) }
        return numbers.count == 2 ? CacheActivity(hits: numbers[0], cacheableTasks: numbers[1]) : nil
    }
}
