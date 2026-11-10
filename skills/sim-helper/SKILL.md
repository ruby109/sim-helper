---
name: sim-helper
description: Build, test, and run a native iOS app on a simulator from a git worktree with sim-helper, which gives each worktree its own simulator and DerivedData and shares one Xcode compilation cache. Use when building or testing an iOS or Xcode project, booting or picking a simulator, or cleaning up before removing a worktree, in a repo where the sim-helper CLI is installed.
---

# sim-helper

sim-helper keeps parallel agents on one Mac from fighting over simulators and DerivedData. Run every command from inside the git worktree you are working in.

Check it is installed with `sim-helper --version`. If it is missing, tell the user: `brew install ruby109/tap/sim-helper`.

## Workflow

```sh
sim-helper sim acquire --json                  # once per worktree: create, boot, and slim its simulator
sim-helper build --json -- -scheme App test    # build or test against it
sim-helper release --json                      # before the worktree is removed
```

- Run `sim acquire` before the first `build`. Without it, `build` lets xcodebuild boot a stock, unverified simulator.
- Do not pass `-destination` or `-derivedDataPath` to `build`; it adds this worktree's. Everything after `--` goes to xcodebuild unchanged.
- The first `sim acquire` can take a few minutes. To get the UDID later, read `.device.udid` from `sim-helper env --json`, which does not touch the simulator.
- To pick a model or iOS version, run `sim-helper sim targets --json` and pass `--device-type` and `--runtime` to `sim acquire`. A different choice parks the current simulator and switches; that is refused while a build runs in the worktree.
- On a 16 GB Mac, 2-3 simulators at once are stable. Do not boot more just to parallelize.

## Reading results

Pass `--json` to every command. Results go to stdout as `{"ok": true, ...}`; xcodebuild output and progress go to stderr. On failure, stdout is `{ok: false, code, message, remedy, available, exitCode}`. Branch on `code` and `exitCode`, and follow `remedy`:

| Code | What to do |
| --- | --- |
| `SIMH_BUILD_FAILED` | A real build or test failure. Read the log at the path in `remedy`; xcodebuild's status is in `xcodebuildStatus` |
| `SIMH_COMPILATION_CACHE_CORRUPT`, `exitCode` 75 | The cache was emptied. Rerun the same command once |
| `SIMH_COMPILATION_CACHE_CORRUPT`, `exitCode` 1 | Other builds still use the corrupt cache. Wait for them, run `sim-helper cache clear`, then rerun |
| `SIMH_COMPILATION_CACHE_BUSY`, `SIMH_WORKSPACE_BUSY` | Another build or acquire holds it. Wait, then retry |
| `SIMH_BOOT_STUCK` | The simulator was discarded, usually due to memory pressure. Wait, then run `sim acquire` once more; do not loop |
| `SIMH_NO_RUNTIME`, `SIMH_NO_DEVICE_TYPE`, `SIMH_USAGE` | Pick from `available`, or take the suggestion in `message` |
| `SIMH_SIMSLIM_MISSING` | Ask the user to install SimSlim, or pass `--no-slim` |
| `SIMH_UNEXPECTED` | Likely a sim-helper bug. Report the message to the user; do not retry in a loop |

Never delete simulators, DerivedData, or `~/.sim-helper` yourself; use `release`, `prune`, or `cache clear`.

## More

`sim-helper help <command>` shows options, output fields, errors, and examples for one command. `sim-helper help errors` lists every error code. Add `--json` to either for structured output.
