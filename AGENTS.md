# Working on sim-helper

Instructions for agents changing this repository. For using sim-helper from another project, see `skills/sim-helper/SKILL.md`.

## Build and test

```sh
swift build
swift test
```

When `xcode-select` points at the Command Line Tools, prefix both with `DEVELOPER_DIR=/Applications/<Xcode>.app/Contents/Developer`.

Tests use `FakeRunner` in `Tests/SimHelperCoreTests` instead of real simctl and xcodebuild. Anything that needs a real simulator (booting, SimSlim, concurrency) is verified by hand; say so when you report results.

## Layout

- `Sources/SimHelperCore`: all behavior. `DeviceManager` owns simulators, `Builder` wraps xcodebuild, `CompilationCache` handles the shared cache and its locks.
- `Sources/sim-helper/main.swift`: argument parsing and output only.
- `Sources/SimHelperCore/Help.swift`: help text, the error reference, and the version.

## Rules

- Every failure is a `HelperError` with a stable `SIMH_*` code. Do not rename codes; agents branch on them.
- A new code, command, or flag needs a matching entry in `Help.swift`. `HelpText` tests check that every code is documented.
- Keep `skills/sim-helper/SKILL.md` and both READMEs (`README.md`, `README.zh-CN.md`) in step with behavior changes. The repo is also a Claude Code plugin marketplace (`.claude-plugin/`); `claude plugin validate .` checks it.
- Only touch simulators recorded in `devices.json`, never by name.

## Releasing

1. Bump `Help.version` in `Sources/SimHelperCore/Help.swift` and `version` in `.claude-plugin/plugin.json`.
2. Commit, then tag `vX.Y.Z` and push the tag.
3. In `ruby109/homebrew-tap`, point `Formula/sim-helper.rb` at the new tag's tarball, update `sha256`, and run `brew audit --strict ruby109/tap/sim-helper`.
