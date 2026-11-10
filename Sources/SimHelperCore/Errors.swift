import Foundation

/// Failure with a stable code that callers (usually agents) can branch on.
public struct HelperError: Error, Equatable {
    public enum Code: String, CaseIterable {
        case usage = "SIMH_USAGE"
        case noXcode = "SIMH_NO_XCODE"
        case notInGitRepo = "SIMH_NOT_IN_GIT_REPO"
        case noRuntime = "SIMH_NO_RUNTIME"
        case noDeviceType = "SIMH_NO_DEVICE_TYPE"
        case simctlFailed = "SIMH_SIMCTL_FAILED"
        case bootStuck = "SIMH_BOOT_STUCK"
        case simslimMissing = "SIMH_SIMSLIM_MISSING"
        case workspaceBusy = "SIMH_WORKSPACE_BUSY"
        case unknownWorkspace = "SIMH_UNKNOWN_WORKSPACE"
        case cacheBusy = "SIMH_COMPILATION_CACHE_BUSY"
        case cacheCorrupt = "SIMH_COMPILATION_CACHE_CORRUPT"
        case buildFailed = "SIMH_BUILD_FAILED"
        case deleteFailed = "SIMH_DELETE_FAILED"
        case stateCorrupt = "SIMH_STATE_CORRUPT"
        case skillNotFound = "SIMH_SKILL_NOT_FOUND"
        case skillConflict = "SIMH_SKILL_CONFLICT"
        case unexpected = "SIMH_UNEXPECTED"
    }

    public var code: Code
    public var message: String
    public var remedy: String?
    /// The valid choices, when the failure is an invalid choice.
    public var available: [String]?
    /// Process exit status to use when this error ends the command.
    public var exitCode: Int32
    /// xcodebuild's own status, for build failures. Kept apart from `exitCode` so
    /// it cannot collide with this tool's codes, such as 64 for usage or 75 for retry.
    public var xcodebuildStatus: Int32?

    public init(_ code: Code, _ message: String, remedy: String? = nil, available: [String]? = nil, exitCode: Int32? = nil, xcodebuildStatus: Int32? = nil) {
        self.code = code
        self.message = message
        self.remedy = remedy
        self.available = available
        self.exitCode = exitCode ?? Self.defaultExitCode(code)
        self.xcodebuildStatus = xcodebuildStatus
    }

    /// Wraps a filesystem or other system error so it still has a stable code.
    public init(_ code: Code, _ action: String, underlying error: Error) {
        self.init(code, "\(action): \((error as NSError).localizedDescription)")
    }

    private static func defaultExitCode(_ code: Code) -> Int32 {
        switch code {
        case .usage: return 64
        // EX_TEMPFAIL: the same command is expected to work when run again.
        case .cacheCorrupt: return 75
        default: return 1
        }
    }
}

/// Runs `body`, giving any non-`HelperError` failure the code `code`.
func attempt<T>(_ code: HelperError.Code, _ action: @autoclosure () -> String, _ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as HelperError {
        throw error
    } catch {
        throw HelperError(code, action(), underlying: error)
    }
}
