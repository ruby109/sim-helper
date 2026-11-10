import Foundation

/// Links the bundled agent skill into the directories Claude Code and Codex
/// load skills from. Links rather than copies, so `brew upgrade` updates it.
public struct SkillInstaller {
    public enum Agent: String, CaseIterable, Encodable {
        case claude, codex

        /// Where each agent looks for personal skills.
        func directory(home: String) -> String {
            switch self {
            case .claude: return home + "/.claude/skills"
            case .codex: return home + "/.agents/skills"
            }
        }

        var configDirectory: String {
            switch self {
            case .claude: return ".claude"
            case .codex: return ".codex"
            }
        }

        var command: String { rawValue }
    }

    public struct Result: Encodable, Equatable {
        public enum Status: String, Encodable {
            case installed, alreadyInstalled, replaced, uninstalled, notInstalled
        }
        public var agent: Agent
        public var path: String
        public var status: Status
    }

    public struct Report: Encodable, Equatable {
        public var source: String?
        public var results: [Result]
    }

    public static let skillName = "sim-helper"

    public var home: String
    public var executablePath: String
    public var runner: CommandRunner

    public init(home: String = NSHomeDirectory(), executablePath: String, runner: CommandRunner) {
        self.home = home
        self.executablePath = executablePath
        self.runner = runner
    }

    /// The agents to act on: the ones asked for, else the ones installed here.
    public func agents(requested: [Agent]) throws -> [Agent] {
        if !requested.isEmpty { return requested }
        let found = Agent.allCases.filter {
            FileManager.default.fileExists(atPath: "\(home)/\($0.configDirectory)") || runner.run("which", [$0.command]).ok
        }
        guard !found.isEmpty else {
            throw HelperError(.usage, "Found neither Claude Code nor Codex.", remedy: "Pass --claude or --codex to choose.", available: ["--claude", "--codex"])
        }
        return found
    }

    /// The skill folder that ships with this binary. Prefers Homebrew's `opt`
    /// path, which survives upgrades, over the versioned Cellar one.
    public func source() throws -> String {
        let executable = realPath(executablePath)
        var candidates: [String] = []
        if let cellar = executable.range(of: "/Cellar/sim-helper/") {
            candidates.append(executable[..<cellar.lowerBound] + "/opt/sim-helper/share/sim-helper/skills/\(Self.skillName)")
        }
        // Other prefixes put it in share/; a SwiftPM build sits a few levels inside a checkout.
        var dir = (executable as NSString).deletingLastPathComponent
        for _ in 0..<5 {
            candidates.append("\(dir)/share/sim-helper/skills/\(Self.skillName)")
            candidates.append("\(dir)/skills/\(Self.skillName)")
            dir = (dir as NSString).deletingLastPathComponent
        }
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0 + "/SKILL.md") }) else {
            throw HelperError(.skillNotFound, "Could not find the sim-helper skill next to \(executable).",
                              remedy: "Pass --from with the skills/sim-helper folder of a sim-helper checkout.")
        }
        return found
    }

    public func install(from source: String, for agents: [Agent]) throws -> Report {
        guard FileManager.default.fileExists(atPath: source + "/SKILL.md") else {
            throw HelperError(.skillNotFound, "\(source) has no SKILL.md.", remedy: "Point --from at the skills/sim-helper folder.")
        }
        let fm = FileManager.default
        var results: [Result] = []
        var conflicts: [String] = []
        for agent in agents {
            let link = agent.directory(home: home) + "/" + Self.skillName
            var status = Result.Status.installed
            if let existing = try? fm.destinationOfSymbolicLink(atPath: link) {
                if realPath(existing) == realPath(source) {
                    results.append(Result(agent: agent, path: link, status: .alreadyInstalled))
                    continue
                }
                guard Self.isOurs(existing) else {
                    conflicts.append(link)
                    continue
                }
                // An older sim-helper link, e.g. into a removed Cellar version.
                try attempt(.stateCorrupt, "Could not replace \(link)") { try fm.removeItem(atPath: link) }
                status = .replaced
            } else if fm.fileExists(atPath: link) {
                conflicts.append(link)
                continue
            }
            try attempt(.stateCorrupt, "Could not link \(link)") {
                try fm.createDirectory(atPath: agent.directory(home: home), withIntermediateDirectories: true)
                try fm.createSymbolicLink(atPath: link, withDestinationPath: source)
            }
            results.append(Result(agent: agent, path: link, status: status))
        }
        if !conflicts.isEmpty {
            let done = results.map { "\($0.agent.rawValue): \($0.status.rawValue)" }.joined(separator: ", ")
            throw HelperError(.skillConflict, "Something other than the sim-helper skill is at \(conflicts.joined(separator: ", ")); left it alone." + (done.isEmpty ? "" : " Done: \(done)."),
                              remedy: "Move it aside and rerun, or install for one agent with --claude or --codex.")
        }
        return Report(source: source, results: results)
    }

    /// Removes only links this command could have made.
    public func uninstall(for agents: [Agent]) throws -> Report {
        let fm = FileManager.default
        var results: [Result] = []
        for agent in agents {
            let link = agent.directory(home: home) + "/" + Self.skillName
            if let existing = try? fm.destinationOfSymbolicLink(atPath: link), Self.isOurs(existing) {
                try attempt(.stateCorrupt, "Could not remove \(link)") { try fm.removeItem(atPath: link) }
                results.append(Result(agent: agent, path: link, status: .uninstalled))
            } else if fm.fileExists(atPath: link) || (try? fm.destinationOfSymbolicLink(atPath: link)) != nil {
                throw HelperError(.skillConflict, "\(link) is not a link to the sim-helper skill; left it alone.", remedy: "Remove it yourself if you no longer need it.")
            } else {
                results.append(Result(agent: agent, path: link, status: .notInstalled))
            }
        }
        return Report(source: nil, results: results)
    }

    static func isOurs(_ target: String) -> Bool {
        target.hasSuffix("/skills/\(skillName)") || target.hasSuffix("/skills/\(skillName)/")
    }
}
