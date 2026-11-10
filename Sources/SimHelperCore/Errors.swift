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
    }

    public var code: Code
    public var message: String
    public var remedy: String?
    /// The valid choices, when the failure is an invalid choice.
    public var available: [String]?
    /// Process exit status to use when this error ends the command.
    public var exitCode: Int32

    public init(_ code: Code, _ message: String, remedy: String? = nil, available: [String]? = nil, exitCode: Int32? = nil) {
        self.code = code
        self.message = message
        self.remedy = remedy
        self.available = available
        self.exitCode = exitCode ?? Self.defaultExitCode(code)
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
