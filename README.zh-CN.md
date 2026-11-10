# sim-helper

[English](README.md) | 简体中文

让多个 agent 在多个 git worktree 里并行开发原生 iOS 项目：每个 worktree 有自己的模拟器和 DerivedData，并共享同一份 Xcode 编译缓存。

设计借鉴自 [Stim](https://github.com/appandflow/stim)（MIT），它只支持 React Native / Expo，这里是面向原生项目的精简版。

## 安装

需要 Xcode 26 或更新版本，以及 [Homebrew](https://brew.sh)（Swift 编译缓存需要 Xcode 27 / Swift 6.4）。

```sh
brew install ruby109/tap/sim-helper
```

也可以从源码目录安装：

```sh
scripts/install.sh                         # 安装到 /usr/local/bin
BIN_DIR=~/.local/bin scripts/install.sh    # 或任意 PATH 目录
```

两种方式都会用 Homebrew 安装 [SimSlim](https://github.com/mobai-app/simslim)。`sim acquire` 依赖 SimSlim，它会关掉模拟器用不到的后台服务，降低内存占用。

`xcode-select` 指向 CommandLineTools 时，会自动使用 `/Applications` 里版本最新的 Xcode，也可以用 `DEVELOPER_DIR` 指定。

## 用法

在 worktree 内运行：

```sh
sim-helper sim targets                     # 列出可以指定的系统版本和型号
sim-helper sim acquire                     # 分配并启动这个 worktree 的模拟器，打印 UDID
sim-helper sim acquire --device-type "iPhone 16 Pro" --runtime 18.0   # 指定型号和版本
sim-helper build -- -scheme App build      # 用这个 worktree 的 DerivedData、模拟器和共享缓存构建
sim-helper env                             # 查看路径和工具链

sim-helper release                         # 移除 worktree 前运行：停放模拟器，删除 DerivedData
sim-helper prune                           # 清理 worktree 已不存在的状态，重试失败的删除
sim-helper cache status
sim-helper cache clear --if-over-gb 20     # 只能整体清空，有构建在用时会拒绝

sim-helper help [<command>]                # 或 `<command> --help`：选项、输出、错误码和示例
sim-helper help errors                     # 所有错误码及处理方式
sim-helper --version
```

`build` 不会覆盖你已传入的 `-destination` 和 `-derivedDataPath`。

所有命令都支持 `--json`。结果写 stdout，状态和构建输出写 stderr。

## 给 agent 的约定

**给 Claude Code 和 Codex 的 skill。** `skills/sim-helper` 告诉 agent 典型流程和错误处理方式。它是标准的 `SKILL.md`，两者都能用。

Claude Code 可以作为插件安装，之后通过 `/plugin` 更新：

```
/plugin marketplace add ruby109/sim-helper
/plugin install sim-helper@sim-helper
```

也可以链接 Homebrew 安装的那份，`brew upgrade` 时会一起更新：

```sh
SKILL="$(brew --prefix sim-helper)/share/sim-helper/skills/sim-helper"
mkdir -p ~/.claude/skills && ln -s "$SKILL" ~/.claude/skills/sim-helper   # Claude Code
mkdir -p ~/.agents/skills && ln -s "$SKILL" ~/.agents/skills/sim-helper   # Codex
```

只想对某个仓库启用的话，改链接到该仓库的 `.claude/skills/`（Claude Code）或 `.agents/skills/`（Codex）。在两者中都可以用 `/skills` 检查是否加载。从源码安装时，用同样的方式链接 `skills/sim-helper`。

**其他 agent。** 把下面这段粘贴到项目的 `AGENTS.md`：

```markdown
## iOS builds
Use sim-helper for simulator builds and tests. Run every command inside your worktree with `--json`.
- Once per worktree: `sim-helper sim acquire`
- Build or test: `sim-helper build -- -scheme <Scheme> test`. Do not pass -destination or -derivedDataPath.
- Before the worktree is removed: `sim-helper release`
- On failure, branch on `code` and follow `remedy`. `sim-helper help <command>` and `sim-helper help errors` explain the rest.
```

**帮助。** `sim-helper help` 给出典型流程、命令、并发上限和环境变量。`help <command>` 列出单个命令的选项、输出字段、错误码和示例，`help errors` 列出所有错误码，两者都支持 `--json`。拼错时会给建议，例如 `Unknown command 'sim aquire'. Did you mean 'sim acquire'?`

**错误码。** 失败时返回稳定的错误码。加 `--json` 时，成功结果带 `"ok": true`，失败输出 `{ok: false, code, message, remedy, available, exitCode, xcodebuildStatus}`：

| 错误码 | 退出码 | 处理方式 |
| --- | --- | --- |
| `SIMH_COMPILATION_CACHE_CORRUPT` | 75 | 缓存已清空，重跑同一命令（这次是冷构建） |
| `SIMH_COMPILATION_CACHE_CORRUPT` | 1 | 缓存损坏，但其他构建还在用，没有清空。等它们结束后运行 `cache clear` 再重跑 |
| `SIMH_COMPILATION_CACHE_BUSY` | 1 | 有构建在用缓存，稍后重试 |
| `SIMH_WORKSPACE_BUSY` | 1 | 这个 worktree 正在构建或执行 `sim acquire`，稍后重试 |
| `SIMH_BUILD_FAILED` | 1 | 普通构建失败。xcodebuild 自己的退出码在 `xcodebuildStatus`，完整日志在 `remedy` 给出的路径 |
| `SIMH_BOOT_STUCK` | 1 | 模拟器显示已启动但无法启动进程，已被丢弃。等内存压力下降后重新申请 |
| `SIMH_SIMSLIM_MISSING` | 1 | 运行 `brew install mobai-app/tap/simslim`，或加 `--no-slim` 使用完整的模拟器 |
| `SIMH_UNEXPECTED` | 1 | 未归类的错误，很可能是 bug，请反馈 |
| `SIMH_DELETE_FAILED` | 1 | 记录已保留，运行 `prune` 重试 |
| `SIMH_NO_RUNTIME` / `SIMH_NO_DEVICE_TYPE` | 1 | 指定的版本或型号不可用，从 `available` 字段里选一个，或运行 `sim targets` |

其他错误码见 `sim-helper help errors`。

## 行为

**模拟器**

- 只操作记录在 `devices.json` 里的模拟器。名字以 `simh-` 开头也不算，别的工具建的模拟器不会被碰。
- 同一个 worktree 下次还用同一台。指定不同的型号或系统版本时，会停放当前这台并换成匹配的一台。
- 同一 worktree 里的 `sim acquire`、构建和 `release` 通过锁协调：有构建或 acquire 在运行时，`release` 会被拒绝；有构建在运行时，切换或 slim 模拟器也会被拒绝。
- `release` 后模拟器被停放，供其他 worktree 复用，最多留 3 台（`SIM_HELPER_MAX_PARKED`），超出时删最旧的。
- `sim acquire` 会在模拟器刚启动时实际拉起一个进程来验证可用，卡住时重启一次；仍然不行就丢弃这台模拟器。已经启动的模拟器不会再验证，避免打断上面正在跑的 UI 测试。
- 删除超出停放上限的模拟器是尽力而为：失败会记在 `deleteFailures`，由 `prune` 重试，不会导致 `release` 失败。
- `sim acquire` 会用 SimSlim 精简模拟器；没装 SimSlim 时直接报错，不会创建任何东西。`--no-slim` 可以跳过。SimSlim 执行失败（比如运行时太旧）只警告，不影响使用。

**编译缓存**

- 构建期间持有共享锁，清空需要独占锁。锁用 `flock`，进程崩溃时由内核释放，不会留下过期的锁。
- 构建失败时按两种情况判断损坏：编译器明确报 CAS 错误；或构建服务崩溃，且 `llvm-cas --validate` 确认存储已损坏。和缓存无关的崩溃不会清空缓存。
- 注意：这种崩溃的报错只有 `The Xcode build system has crashed. Build again to continue.`，但不清空的话，再构建也一样会崩。

状态默认在 `~/.sim-helper`（`SIM_HELPER_HOME` 可改），不会往 worktree 里写文件。

## 实测

都在同一台 16GB 内存的 Apple Silicon Mac 上测得，使用 Xcode 27.2 和小型测试 app，每个数字只跑了一次。

**编译缓存**（小型 SwiftUI app）

| 场景 | 命中 | 耗时 |
| --- | --- | --- |
| 第一个 worktree，冷构建 | 0 / 70 | 11.3s |
| 第二个 worktree，相同代码 | 70 / 70 | 4.5s |
| 第二个 worktree，改一个文件 | 63 / 70 | 未记录 |

**SimSlim**（一台空闲的 iPhone 18 Pro 模拟器，iOS 27.2，SimSlim 0.14.0）

| | 未 slim | slim 后 |
| --- | --- | --- |
| 进程数 | 220–235 | 74–78 |
| 内存占用 | 9.18–10.00GB | 2.43–2.50GB |
| 重启 | 8s | 3s |

slim 只需做一次，含重启约 12s。内存占用是 `simslim measure` 给出的 `phys_footprint`，按进程累加，会高估实际物理内存，多台之间也不能直接相加：两台未 slim 的模拟器合计 21GB，而这台 Mac 只有 16GB。

**并发**（多个 agent 同时申请模拟器，再各跑两轮 3 个单元测试和 1 个 UI 测试）

| 模拟器 | `sim acquire` | 第一轮测试 | 第二轮测试 | 最高 swap |
| --- | --- | --- | --- | --- |
| 2 台 slim | 147s | 50s | 16s | 4.6GB |
| 3 台 slim | 216–218s | 58–59s | 19–20s | 7.3GB |
| 4 台 slim | 337–394s，4 台中 2 台失败 | 124–233s | 50–171s | 9.6GB |
| 2 台未 slim | 84–87s | 136–204s | 34s | 9.0GB |

所有测试都通过了，包括 slim 后的 UI 测试。4 台时有 2 台 `sim acquire` 报 `SIMH_BOOT_STUCK`，之后由 `build` 启动，但没有 slim。未 slim 组最后跑，当时 swap 已有约 4.5GB，结果对它略不利。在这台 Mac 上，同时 2 到 3 台比较稳妥。

## 已知限制

- **SPM 包的目标几乎不跨 worktree 命中。** 根目录就是 `Package.swift` 的项目实测 2 / 8，原因未查明。依赖本地包的 `.xcodeproj` 项目也可能受影响，没有测过。
- **`SIM_HELPER_HOME` 不要放在 `/tmp` 或 `/private/tmp` 下。** Xcode 会把路径规范化成 `/tmp`，和前缀映射对不上。实测命中率不稳定（同一个 app 9 / 70 到 63 / 70），移到普通路径后是 70 / 70。worktree 放在这些目录下很可能有同样的问题，没有单独测过。
- **没有限制同时首次启动的数量。** 在 16GB 的 Mac 上同时申请 4 台，有 2 台报 `SIMH_BOOT_STUCK`。请错开申请，或者重试。
- **`--no-boot` 和 `build` 不会触发 SimSlim。** 要 slim 需先运行一次 `sim acquire`。`sim acquire` 失败后由 `build` 启动的模拟器不会被 slim。
- **停放的模拟器不清理 app 数据。** 换 worktree 后可能残留上一个 worktree 安装的 app，需要干净环境时请自己卸载。没有自动抹掉，是因为 erase 会让 SimSlim 的设置失效。
- **`kill -9` 杀掉 sim-helper 时，xcodebuild 可能继续运行，而它的缓存锁已释放。** SIGINT、SIGTERM、SIGHUP 会转发给 xcodebuild，sim-helper 会等它退出后再退出。
- **SimSlim 需要 iOS 18 或更新的运行时**，更旧的运行时重启后设置不保留。

## 开发

```sh
swift test   # xcode-select 指向 CommandLineTools 时，需设置 DEVELOPER_DIR
```

修改本仓库的 agent 请先读 [AGENTS.md](AGENTS.md)。

没有做的部分：产物缓存和单飞构建、已合并 worktree 的自动判断、磁盘压力分级清理、worktree 预热。

## 许可证

[MIT](LICENSE)
