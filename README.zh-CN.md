# sim-helper

[English](README.md) | 简体中文

让多个 agent 在多个 git worktree 里并行开发原生 iOS 项目：每个 worktree 有自己的模拟器和 DerivedData，并共享同一份 Xcode 编译缓存。

设计借鉴自 [Stim](https://github.com/appandflow/stim)（MIT），它只支持 React Native / Expo，这里是面向原生项目的精简版。

## 安装

需要 Xcode 26 或更新版本，以及 [Homebrew](https://brew.sh)（Swift 编译缓存需要 Xcode 27 / Swift 6.4）。

```sh
scripts/install.sh                         # 安装到 /usr/local/bin
BIN_DIR=~/.local/bin scripts/install.sh    # 或任意 PATH 目录
```

脚本会构建 sim-helper，并用 Homebrew 安装 [SimSlim](https://github.com/mobai-app/simslim)。`sim acquire` 依赖 SimSlim，它会关掉模拟器用不到的后台服务，降低内存占用。

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
```

`build` 不会覆盖你已传入的 `-destination` 和 `-derivedDataPath`。

所有命令都支持 `--json`。结果写 stdout，状态和构建输出写 stderr。

## 给 agent 的约定

失败时返回稳定的错误码，加 `--json` 时输出 `{ok, code, message, remedy, available}`：

| 错误码 | 退出码 | 处理方式 |
| --- | --- | --- |
| `SIMH_COMPILATION_CACHE_CORRUPT` | 75 | 缓存已清空，重跑同一命令（这次是冷构建） |
| `SIMH_COMPILATION_CACHE_CORRUPT` | 1 | 缓存损坏，但其他构建还在用，没有清空。等它们结束后运行 `cache clear` 再重跑 |
| `SIMH_COMPILATION_CACHE_BUSY` | 1 | 有构建在用缓存，稍后重试 |
| `SIMH_WORKSPACE_BUSY` | 1 | 这个 worktree 正在构建，稍后再 `release` |
| `SIMH_BUILD_FAILED` | xcodebuild 的退出码 | 普通构建失败，完整日志在 `remedy` 给出的路径 |
| `SIMH_BOOT_STUCK` | 1 | 模拟器显示已启动，但无法启动进程，先检查内存压力 |
| `SIMH_SIMSLIM_MISSING` | 1 | 运行 `scripts/install.sh`，或加 `--no-slim` 使用完整的模拟器 |
| `SIMH_DELETE_FAILED` | 1 | 记录已保留，运行 `prune` 重试 |
| `SIMH_NO_RUNTIME` / `SIMH_NO_DEVICE_TYPE` | 1 | 指定的版本或型号不可用，从 `available` 字段里选一个，或运行 `sim targets` |

其他错误码见 `Sources/SimHelperCore/Errors.swift`。

## 行为

**模拟器**

- 只操作记录在 `devices.json` 里的模拟器。名字以 `simh-` 开头也不算，别的工具建的模拟器不会被碰。
- 同一个 worktree 下次还用同一台。
- `release` 后模拟器被停放，供其他 worktree 复用，最多留 3 台（`SIM_HELPER_MAX_PARKED`），超出时删最旧的。
- `sim acquire` 会实际启动一个进程来验证模拟器可用，卡住时重启一次。
- `sim acquire` 会用 SimSlim 精简模拟器；没装 SimSlim 时直接报错，不会创建任何东西。`--no-slim` 可以跳过。SimSlim 执行失败（比如运行时太旧）只警告，不影响使用。

**编译缓存**

- 构建期间持有共享锁，清空需要独占锁。锁用 `flock`，进程崩溃时由内核释放，不会留下过期的锁。
- 构建失败时按两种情况判断损坏：编译器明确报 CAS 错误；或构建服务崩溃，且 `llvm-cas --validate` 确认存储已损坏。和缓存无关的崩溃不会清空缓存。
- 注意：这种崩溃的报错只有 `The Xcode build system has crashed. Build again to continue.`，但不清空的话，再构建也一样会崩。

状态默认在 `~/.sim-helper`（`SIM_HELPER_HOME` 可改），不会往 worktree 里写文件。

## 实测（Xcode 27.2，Apple Silicon，小型 SwiftUI app）

| 场景 | 命中 | 耗时 |
| --- | --- | --- |
| 第一个 worktree，冷构建 | 0 / 70 | 11.3s |
| 第二个 worktree，相同代码 | 70 / 70 | 4.5s |
| 第二个 worktree，改一个文件 | 63 / 70 | 未记录 |

## 已知限制

- **SPM 包的目标几乎不跨 worktree 命中。** 根目录就是 `Package.swift` 的项目实测 2 / 8，原因未查明。依赖本地包的 `.xcodeproj` 项目也可能受影响，没有测过。
- **`SIM_HELPER_HOME` 不要放在 `/tmp` 或 `/private/tmp` 下。** Xcode 会把路径规范化成 `/tmp`，和前缀映射对不上。实测命中率不稳定（同一个 app 9 / 70 到 63 / 70），移到普通路径后是 70 / 70。worktree 放在这些目录下很可能有同样的问题，没有单独测过。
- **`--no-boot` 和 `build` 不会触发 SimSlim。** 要 slim 需先运行一次 `sim acquire`。
- **停放的模拟器不清理 app 数据。** 换 worktree 后可能残留上一个 worktree 安装的 app，需要干净环境时请自己卸载。没有自动抹掉，是因为 erase 会让 SimSlim 的设置失效。
- **`kill -9` 杀掉 sim-helper 时，xcodebuild 可能继续运行，而它的缓存锁已释放。** SIGINT、SIGTERM、SIGHUP 会转发给 xcodebuild。
- **SimSlim 需要 iOS 18 或更新的运行时**，更旧的运行时重启后设置不保留。

## 开发

```sh
swift test   # xcode-select 指向 CommandLineTools 时，需设置 DEVELOPER_DIR
```

没有做的部分：产物缓存和单飞构建、已合并 worktree 的自动判断、磁盘压力分级清理、worktree 预热。
