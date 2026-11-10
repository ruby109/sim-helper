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
```

`build` keeps any `-destination` or `-derivedDataPath` you pass.

Every command accepts `--json`. Results go to stdout; status and build output go to stderr.

## For agents

Failures return stable error codes. With `--json`, the output is `{ok, code, message, remedy, available}`:

| Code | Exit code | What to do |
| --- | --- | --- |
| `SIMH_COMPILATION_CACHE_CORRUPT` | 75 | The cache was cleared. Rerun the same command (it will be a cold build) |
| `SIMH_COMPILATION_CACHE_CORRUPT` | 1 | The cache is corrupt but other builds are using it, so it was not cleared. Wait for them, run `cache clear`, then rerun |
| `SIMH_COMPILATION_CACHE_BUSY` | 1 | A build is using the cache. Retry later |
| `SIMH_WORKSPACE_BUSY` | 1 | This worktree is building. Run `release` later |
| `SIMH_BUILD_FAILED` | xcodebuild's exit code | An ordinary build failure. The full log is at the path in `remedy` |
| `SIMH_BOOT_STUCK` | 1 | The simulator reports booted but cannot launch a process. Check memory pressure first |
| `SIMH_SIMSLIM_MISSING` | 1 | Run `scripts/install.sh`, or pass `--no-slim` to use a stock simulator |
| `SIMH_DELETE_FAILED` | 1 | The record was kept. Run `prune` to retry |
| `SIMH_NO_RUNTIME` / `SIMH_NO_DEVICE_TYPE` | 1 | The requested version or model is unavailable. Pick one from `available`, or run `sim targets` |

See `Sources/SimHelperCore/Errors.swift` for the other codes.

## Behavior

**Simulators**

- sim-helper only touches simulators recorded in `devices.json`. A `simh-` name prefix is not enough, so simulators created by other tools are left alone.
- A worktree gets the same simulator back next time.
- `release` parks the simulator so another worktree can reuse it. Up to 3 are kept (`SIM_HELPER_MAX_PARKED`); beyond that, the oldest is deleted.
- `sim acquire` launches a real process to confirm the simulator works, and restarts it once if it is stuck.
- `sim acquire` slims the simulator with SimSlim, and fails before creating anything if SimSlim is missing. `--no-slim` skips it. A SimSlim failure, such as on an older runtime, is only a warning.

**Compilation cache**

- Builds hold a shared lock; clearing needs an exclusive lock. Locks use `flock`, so the kernel releases them when a process crashes and no stale lock is left behind.
- A failed build is treated as cache corruption in two cases: the compiler reports a CAS error, or the build service crashes and `llvm-cas --validate` confirms the store is damaged. Crashes unrelated to the cache do not clear it.
- That crash only says `The Xcode build system has crashed. Build again to continue.`, but building again keeps crashing until the cache is cleared.

State lives in `~/.sim-helper` by default (override with `SIM_HELPER_HOME`). Nothing is written into the worktree.

## Measurements (Xcode 27.2, Apple Silicon, small SwiftUI app)

| Scenario | Cache hits | Time |
| --- | --- | --- |
| First worktree, cold build | 0 / 70 | 11.3s |
| Second worktree, same code | 70 / 70 | 4.5s |
| Second worktree, one file changed | 63 / 70 | not recorded |

## Known limitations

- **SPM package targets barely hit the cache across worktrees.** A project whose root is a `Package.swift` measured 2 / 8, cause unknown. `.xcodeproj` projects that depend on local packages may be affected too; not tested.
- **Do not put `SIM_HELPER_HOME` under `/tmp` or `/private/tmp`.** Xcode normalizes the path to `/tmp`, which breaks prefix mapping. Hit rates were unstable (9 / 70 to 63 / 70 for the same app) and reached 70 / 70 after moving to a normal path. Worktrees in those directories probably have the same problem; not tested separately.
- **`--no-boot` and `build` do not run SimSlim.** Run `sim acquire` once to slim the simulator.
- **Parked simulators keep their app data.** A worktree may inherit apps installed by the previous one; uninstall them if you need a clean state. They are not erased automatically because erasing undoes SimSlim's settings.
- **If sim-helper is killed with `kill -9`, xcodebuild may keep running after its cache lock is released.** SIGINT, SIGTERM, and SIGHUP are forwarded to xcodebuild.
- **SimSlim needs an iOS 18 or later runtime.** Older runtimes lose the settings on reboot.

## Development

```sh
swift test   # set DEVELOPER_DIR when xcode-select points at the Command Line Tools
```

Not implemented: artifact caching and single-flight builds, detecting merged worktrees automatically, tiered cleanup under disk pressure, and worktree prewarming.
