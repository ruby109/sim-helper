# sim-helper

English | [简体中文](README.zh-CN.md)

Let several agents work on a native iOS project in parallel, each in its own git worktree. Every worktree gets its own simulator and DerivedData, and all of them share one Xcode compilation cache.

The design borrows from [Stim](https://github.com/appandflow/stim) (MIT), which supports only React Native and Expo. sim-helper is a smaller take on the same ideas for native projects.

## Install

Requires Xcode 26 or later and [Homebrew](https://brew.sh). Swift compilation caching needs Xcode 27 (Swift 6.4).

```sh
brew install ruby109/tap/sim-helper
```

To build from a checkout instead:

```sh
scripts/install.sh                         # installs to /usr/local/bin
BIN_DIR=~/.local/bin scripts/install.sh    # or any directory on your PATH
```

Both install [SimSlim](https://github.com/mobai-app/simslim) with Homebrew. `sim acquire` requires SimSlim, which turns off background services the simulator does not need and cuts its memory use.

When `xcode-select` points at the Command Line Tools, sim-helper uses the newest Xcode in `/Applications`. Set `DEVELOPER_DIR` to choose one yourself.

## Usage

Run these inside a worktree:

```sh
sim-helper sim targets                     # list the runtimes and device types you can request
sim-helper sim acquire                     # allocate and boot this worktree's simulator, print its UDID
sim-helper sim acquire --device-type "iPhone 16 Pro" --runtime 18.0   # request a model and version
sim-helper build -- -scheme App build      # build with this worktree's DerivedData, simulator, and the shared cache
sim-helper env                             # show paths and toolchain

sim-helper release                         # run before removing a worktree: park its simulator, delete its DerivedData
sim-helper prune                           # clean up state for worktrees that no longer exist, retry failed deletes
sim-helper cache status
sim-helper cache clear --if-over-gb 20     # clears the whole cache; refused while a build is using it

sim-helper skill install                   # teach Claude Code and Codex to use sim-helper
sim-helper help [<command>]                # or `<command> --help`: options, output, errors, examples
sim-helper help errors                     # every error code and what to do
sim-helper --version
```

`build` keeps any `-destination` or `-derivedDataPath` you pass.

Every command accepts `--json`. Results go to stdout; status and build output go to stderr.

## For agents

**Skill for Claude Code and Codex.** `skills/sim-helper` teaches an agent the workflow and how to handle errors. It is a standard `SKILL.md`, so both agents can use it.

```sh
sim-helper skill install            # for every agent found: Claude Code, Codex, or both
sim-helper skill install --codex    # or just one
sim-helper skill uninstall
```

It links the skill into `~/.claude/skills` and `~/.agents/skills`, so `brew upgrade` keeps it current. Check with `/skills` in either agent; Codex may need a restart.

Claude Code can also install it as a plugin, updated through `/plugin`:

```
/plugin marketplace add ruby109/sim-helper
/plugin install sim-helper@sim-helper
```

For a single repo, link `skills/sim-helper` into that repo's `.claude/skills/` (Claude Code) or `.agents/skills/` (Codex) instead.

**Other agents.** Paste this into your project's `AGENTS.md`:

```markdown
## iOS builds
Use sim-helper for simulator builds and tests. Run every command inside your worktree with `--json`.
- Once per worktree: `sim-helper sim acquire`
- Build or test: `sim-helper build -- -scheme <Scheme> test`. Do not pass -destination or -derivedDataPath.
- Before the worktree is removed: `sim-helper release`
- On failure, branch on `code` and follow `remedy`. `sim-helper help <command>` and `sim-helper help errors` explain the rest.
```

**Help.** `sim-helper help` gives the workflow, commands, limits, and environment variables. `help <command>` lists a command's options, output fields, errors, and examples, and `help errors` covers every error code. Both accept `--json`. Typos get a suggestion, such as `Unknown command 'sim aquire'. Did you mean 'sim acquire'?`

**Errors.** Failures return stable error codes. With `--json`, successes include `"ok": true` and failures print `{ok: false, code, message, remedy, available, exitCode, xcodebuildStatus}`:

| Code | Exit code | What to do |
| --- | --- | --- |
| `SIMH_COMPILATION_CACHE_CORRUPT` | 75 | The cache was cleared. Rerun the same command (it will be a cold build) |
| `SIMH_COMPILATION_CACHE_CORRUPT` | 1 | The cache is corrupt but other builds are using it, so it was not cleared. Wait for them, run `cache clear`, then rerun |
| `SIMH_COMPILATION_CACHE_BUSY` | 1 | A build is using the cache. Retry later |
| `SIMH_WORKSPACE_BUSY` | 1 | A build or `sim acquire` is running in this worktree. Retry later |
| `SIMH_BUILD_FAILED` | 1 | An ordinary build failure. xcodebuild's own status is in `xcodebuildStatus`; the full log is at the path in `remedy` |
| `SIMH_BOOT_STUCK` | 1 | The simulator booted but could not launch a process, and was discarded. Wait for memory pressure to drop, then acquire again |
| `SIMH_SIMSLIM_MISSING` | 1 | Run `brew install mobai-app/tap/simslim`, or pass `--no-slim` to use a stock simulator |
| `SIMH_UNEXPECTED` | 1 | An unclassified error, likely a bug. Report it |
| `SIMH_DELETE_FAILED` | 1 | The record was kept. Run `prune` to retry |
| `SIMH_NO_RUNTIME` / `SIMH_NO_DEVICE_TYPE` | 1 | The requested version or model is unavailable. Pick one from `available`, or run `sim targets` |

`sim-helper help errors` lists the rest.

## Behavior

**Simulators**

- sim-helper only touches simulators recorded in `devices.json`. A `simh-` name prefix is not enough, so simulators created by other tools are left alone.
- A worktree gets the same simulator back next time. Asking for a different device type or runtime parks the current one and switches.
- `sim acquire`, builds, and `release` in the same worktree coordinate through a lock: `release` is refused while a build or acquire runs, and switching or slimming a simulator is refused while a build runs.
- `release` parks the simulator so another worktree can reuse it. Up to 3 are kept (`SIM_HELPER_MAX_PARKED`); beyond that, the oldest is deleted.
- `sim acquire` launches a real process to confirm a newly booted simulator works, and restarts it once if it is stuck. A simulator that still cannot launch anything is discarded. An already booted simulator is not probed again, so a UI test running on it is not disturbed.
- Deleting a simulator that is over the parking limit is best effort: a failure is reported in `deleteFailures` and retried by `prune`, and does not fail `release`.
- `sim acquire` slims the simulator with SimSlim, and fails before creating anything if SimSlim is missing. `--no-slim` skips it. A SimSlim failure, such as on an older runtime, is only a warning.

**Compilation cache**

- Builds hold a shared lock; clearing needs an exclusive lock. Locks use `flock`, so the kernel releases them when a process crashes and no stale lock is left behind.
- A failed build is treated as cache corruption in two cases: the compiler reports a CAS error, or the build service crashes and `llvm-cas --validate` confirms the store is damaged. Crashes unrelated to the cache do not clear it.
- That crash only says `The Xcode build system has crashed. Build again to continue.`, but building again keeps crashing until the cache is cleared.

State lives in `~/.sim-helper` by default (override with `SIM_HELPER_HOME`). Nothing is written into the worktree.

## Measurements

All on one Apple Silicon Mac with 16 GB of memory and Xcode 27.2, using small test apps. Each figure comes from a single run.

**Compilation cache** (small SwiftUI app)

| Scenario | Cache hits | Time |
| --- | --- | --- |
| First worktree, cold build | 0 / 70 | 11.3s |
| Second worktree, same code | 70 / 70 | 4.5s |
| Second worktree, one file changed | 63 / 70 | not recorded |

**SimSlim** (one idle iPhone 18 Pro simulator, iOS 27.2, SimSlim 0.14.0)

| | Stock | Slimmed |
| --- | --- | --- |
| Processes | 220–235 | 74–78 |
| Memory footprint | 9.18–10.00 GB | 2.43–2.50 GB |
| Reboot | 8s | 3s |

Slimming takes about 12s once, including a reboot. Footprint is `phys_footprint` from `simslim measure`, summed per process, so it overstates physical memory and does not add up across simulators: two stock simulators reported 21 GB on this 16 GB Mac.

**Concurrency** (agents acquiring simulators at the same time, then running 3 unit tests and 1 UI test twice)

| Simulators | `sim acquire` | First test run | Second test run | Peak swap |
| --- | --- | --- | --- | --- |
| 2 slimmed | 147s | 50s | 16s | 4.6 GB |
| 3 slimmed | 216–218s | 58–59s | 19–20s | 7.3 GB |
| 4 slimmed | 337–394s, 2 of 4 failed | 124–233s | 50–171s | 9.6 GB |
| 2 stock | 84–87s | 136–204s | 34s | 9.0 GB |

All tests passed, including the UI test on slimmed simulators. With 4, two acquires failed with `SIMH_BOOT_STUCK`; their builds booted the simulators later, without slimming. The stock run went last, when swap was already about 4.5 GB, so it is somewhat disadvantaged. On this Mac, 2–3 simulators at once is comfortable.

## Known limitations

- **SPM package targets barely hit the cache across worktrees.** A project whose root is a `Package.swift` measured 2 / 8, cause unknown. `.xcodeproj` projects that depend on local packages may be affected too; not tested.
- **Do not put `SIM_HELPER_HOME` under `/tmp` or `/private/tmp`.** Xcode normalizes the path to `/tmp`, which breaks prefix mapping. Hit rates were unstable (9 / 70 to 63 / 70 for the same app) and reached 70 / 70 after moving to a normal path. Worktrees in those directories probably have the same problem; not tested separately.
- **First boots are not throttled.** Acquiring 4 simulators at once on a 16 GB Mac made 2 of them fail with `SIMH_BOOT_STUCK`. Stagger acquires, or retry.
- **`--no-boot` and `build` do not run SimSlim.** Run `sim acquire` once to slim the simulator. A simulator that `build` boots after a failed acquire stays stock.
- **Parked simulators keep their app data.** A worktree may inherit apps installed by the previous one; uninstall them if you need a clean state. They are not erased automatically because erasing undoes SimSlim's settings.
- **If sim-helper is killed with `kill -9`, xcodebuild may keep running after its cache lock is released.** SIGINT, SIGTERM, and SIGHUP are forwarded to xcodebuild, and sim-helper waits for it to exit before exiting itself.
- **SimSlim needs an iOS 18 or later runtime.** Older runtimes lose the settings on reboot.

## Development

```sh
swift test   # set DEVELOPER_DIR when xcode-select points at the Command Line Tools
```

Agents changing this repo should read [AGENTS.md](AGENTS.md).

Not implemented: artifact caching and single-flight builds, detecting merged worktrees automatically, tiered cleanup under disk pressure, and worktree prewarming.

## License

[MIT](LICENSE)
