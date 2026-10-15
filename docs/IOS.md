# iOS 构建说明

本仓库在 `ios-port` 分支上开始 iOS 目标支持。与 `android-port` 的关键区别是：
**目前还没有任何可运行的 iOS 产物，本机也没有完整的 Xcode**，因此本文档严格区分

- **已验证**：本次编写文档时在本机实际执行过并观察到结果；
- **未验证**：设计上需要、但因缺少 Xcode / Rust 工具链而完全没跑过。

不要把"未验证"一节里的内容当作已完成的事实。

## 一、为什么 Android 方案不能照搬到 iOS

| 领域 | Android（已实现） | iOS（本分支目标） |
| --- | --- | --- |
| 内核形态 | 独立可执行文件（子进程 sidecar） | **必须是链接进应用进程的库**，不能是进程 |
| 内核来源 | 上游预编译 `mihomo-android-arm64-v8` 二进制 | **上游不发布 iOS 产物**，必须自行从源码构建 |
| 隧道 | `VpnService.Builder.establish()` + `detachFd()` | `NEPacketTunnelProvider`（Network Extension） |
| 内核拿到网络的方式 | `tun.file-descriptor`（JNI 传入 int fd） | 无公开的 raw fd；由扩展进程持有 `packetFlow` |
| 自身流量绕行 | `addDisallowedApplication(packageName)` | 没有等价 API，只能靠 `includedRoutes/excludedRoutes` |
| 主程序与内核通信 | 桌面/Android 走 unix socket（`sidecar_ipc_path`） | 内核在扩展进程内，需跨进程 IPC（App Group + `NETunnelProviderSession`） |
| 权限/签名 | 无需付费账号即可侧载 debug 包 | NetworkExtension entitlement + 付费开发者账号 |

### 1.1 sidecar 路线在 iOS 上不成立

iOS 应用只能执行以应用身份签名、且由系统加载的代码，不能把"随包分发的另一个可执行文件"当子进程启动
（Foundation 的 `Process`/`NSTask` 仅 macOS 提供）。因此：

- Android 的做法（内核丢进 `jniLibs`，系统解压到 `nativeLibraryDir` 后 exec）没有 iOS 对应物；
- Tauri 的 shell 插件 sidecar API 依赖"解析 `current_exe()` 旁的可执行文件并 spawn"，在 iOS 上无意义。

代码库中的具体落点（均已读文件核对）：

| 位置 | 内容 | iOS 上的后果 |
| --- | --- | --- |
| `src-tauri/src/utils/dirs.rs:171-174` | `#[cfg(all(mobile, not(target_os = "android")))] core_sidecar_binary_path` 直接返回 `Err("packaged core binaries are not supported on this platform")` | iOS 走这一支，永远拿不到内核路径（task-1 的 cfg 收敛没有触及它，也不应触及） |
| `src-tauri/src/core/manager/state.rs:201-205` | `#[cfg(mobile)]` 分支用 `dirs::core_sidecar_binary_path(...)` 构造 `shell().command(...)` 再 `spawn()` | `start_core_by_sidecar` 在 iOS 上必然失败 |
| `src-tauri/src/core/manager/state.rs:165-169` | `clash_verge_service_ipc::execution::reserve_sidecar()` 是 `#[cfg(desktop)]` | 服务模式本来就不在移动端存在（Android 同样） |
| `src-tauri/src/core/mod.rs:52-53` | `#[cfg(target_os = "android")] pub mod tun_android;` | iOS 完全没有 TUN 相关模块 |

结论：iOS 需要的不是"换一条启动命令"，而是**内核不以进程形式存在**——它必须被链接进应用进程。

### 1.2 内核必须和隧道在同一个进程里

iOS 上唯一受支持的隧道形态是 Network Extension：

- 隧道由系统启动的扩展进程（`NEPacketTunnelProvider` 子类）持有，扩展通过 `setTunnelNetworkSettings(_:)` 配置地址/路由，通过 `packetFlow`（`NEPacketTunnelFlow`）收发包；
- 扩展进程本身已受沙箱限制，不能再去 spawn 第三个进程；
- 因此 mihomo 需要以库的形式跑在**扩展进程**内：数据包在扩展里被读写后进入内核的用户态网络栈（`tun.stack: gvisor`），而不是像 Android 那样把一个 fd 交给外部进程。

主程序（Tauri WebView，负责 UI/配置）与内核（在扩展里）是两个进程，所以现有的
"主程序通过 unix socket 调内核 ext-controller API" 这套（`dirs::sidecar_ipc_path`）还需要一层 App Group 共享容器，
或者改用 `NETunnelProviderSession.sendProviderMessage`。**谁生成配置、谁调用 mihomo API 需要重新划分**，这是本移植最大的结构性工作。

### 1.3 TUN 描述符：Android 的每个环节在 iOS 上对应什么

Android 链路（已实现，供对照）：

1. `scripts/android/templates/VpnTunService.kt`：`VpnService.Builder` → `establish()` → `detachFd()` → JNI `nativeOnTunEstablished(fd)`；
2. `src-tauri/src/core/tun_android.rs:13-23`：`set_tun_fd` 清掉 `FD_CLOEXEC`（让子进程继承），存入 `AtomicI32`；
3. `src-tauri/src/feat/config.rs:28-39`：`patch_verge` 里 `#[cfg(target_os = "android")]` 的编排：开 → `start_vpn_service_and_wait_fd`，关 → `stop_vpn_service`（iOS 则在 `feat/config.rs:21-26` 直接拒绝开启 TUN）；
4. `src-tauri/src/enhance/tun.rs:55-69`：`#[cfg(target_os = "android")]` 把 `tun.stack=gvisor`、`auto-route/auto-redirect/strict-route=false`、`device=tun0` 和 `file-descriptor: <fd>` 写进配置。

iOS 上**第 1、2、4 步都不存在**（`enhance/tun.rs` 没有 iOS 分支，也没有 `tun_ios` 模块）。
第 3 步目前是"显式拒绝"而不是"实现"：`feat/config.rs:21-26` 新增了 `#[cfg(target_os = "ios")]` 守卫，
一旦请求开启 TUN 就 `bail!`（"TUN mode is not supported on iOS: the Network Extension integration is not implemented"），
因为 iOS 既不能执行 sidecar、也还没有 Network Extension 隧道，内核只会拿到一份无法满足的 TUN 配置。
相应地 `constants.rs:84` 的 `file-descriptor` 配置键与 `feat/effects.rs:35` 的 TUN 重启效应仍只在 android 下存在——iOS 走不到那里。

因此 iOS 的隧道实现有三条候选路线，本分支建议先按 A 设计、B 兜底：

| 方案 | 做法 | 代价 / 风险 |
| --- | --- | --- |
| **A（推荐目标）** | 扩展内持有 `packetFlow`，内核暴露"包级 IO"入口（读 `readPackets`、写 `writePackets`），交给 gvisor 栈 | 需要改造/包装 mihomo 的 tun 入口，只用公开 API；实现量最大 |
| B（兜底） | 通过 KVC 从 `packetFlow` 取出底层 socket 的 fd，交给内核的 `tun.file-descriptor`（与 Android 同形） | 依赖未公开 API，系统版本变化与审核都有风险 |
| C（不采用） | 仅做本地 HTTP/SOCKS 端口，让用户手动配置代理 | iOS 不允许应用改系统代理，做不到透明代理，等于放弃 TUN |

无论哪条路线，Android 那份"把所有流量交给内核"的语义都要在 iOS 上重新实现一遍，不能靠复制 `tun_android.rs` 完成。

### 1.4 NetworkExtension 的 entitlement、扩展 target 与签名

- 需要一个 **App Extension target**（`NEPacketTunnelProvider` 子类），嵌在 app bundle 内；`Info.plist` 里声明
  `NSExtension` → `NEProviderClasses`。
- entitlement：主 app 与扩展都要 `com.apple.developer.networking.networkextension`，值为 `packet-tunnel-provider`。
- 主 app 与扩展之间共享配置/日志/socket 需要 **App Group**（`com.apple.security.application-groups`）。
- **必须付费 Apple Developer Program**：免费 Apple ID 的 Personal Team 无法为 NetworkExtension 申请描述文件；
  同理 `bundle.iOS.developmentTeam` 是必需的（Tauri schema 原文：*"This value is required for iOS development because code signing is enforced"*，
  也可用 `APPLE_DEVELOPMENT_TEAM` 环境变量覆盖）。
  当前选择是**在 `tauri.ios.conf.json` 里留空**（不写占位团队 ID），签名时通过 `APPLE_DEVELOPMENT_TEAM`
  或本地未提交的覆盖提供——因此首次真机构建前必须自己补上这一项。
- `src-tauri/gen/apple` 由 `tauri ios init` 生成且被 gitignore，所以扩展 target、entitlement、App Group
  必须像 Android 的 `scripts/android/templates/*.kt` 一样做成**可重放的补丁/模板**，否则重新克隆后构建不出来。
  Tauri 在这里留了口子：`bundle.iOS.template` 可以指定自定义的 XcodeGen `project.yml` 模板
  （本机 `node_modules/@tauri-apps/cli/config.schema.json` 中已核对该字段存在）。

### 1.5 内核从哪里来

- **上游不发布 iOS 产物**（已核实 v1.19.32 的 release 资产只有 android / darwin / freebsd / linux / windows）。
  `scripts/prebuild.mjs` 的 `PLATFORM_MAP` 也没有 `aarch64-apple-ios`，因此 `pnpm prebuild` 这条路径在 iOS 上不适用。
- 需要自行把 mihomo 编成可链接的库。**可参考的现成先例**：ClashMetaForAndroid 的 `core` 模块
  （`core/build.gradle.kts`）用 golang-android 插件把 mihomo 编成 `libclash.so`，Go 包名 `cfa/native`，
  构建 tag 为 `foss,with_gvisor,cmfa`。同一套"包装成库"的思路换成 `gomobile bind -target=ios`（产出 XCFramework）
  或 `-buildmode=c-archive` 就是 iOS 需要的形态——**但这条链路本文档未验证**：
  mihomo 的依赖在 iOS 上是否需要额外 tag、`gomobile` 是否支持其全部依赖，都必须在装了 Xcode 的机器上先做最小实验。
- 因此 iOS 的 bundle 不能带桌面的 sidecar：`tauri.ios.conf.json` 已用 `bundle.externalBin: []` 覆盖，
  否则 `tauri-build` 会去找 `sidecar/verge-mihomo-aarch64-apple-ios`（机制见 §2 与 §3.2）。

## 二、构建路径（从零到首次可运行）

> 以下步骤**全部未验证**（本机没有 Xcode），是按现有代码与配置推导出的顺序，首次执行时每一步都需要据实修正。

### 0. 前置条件

```bash
# 1) 完整 Xcode（不是 CommandLineTools）
sudo xcode-select -s /Applications/Xcode.app
xcodebuild -runFirstLaunch

# 2) Rust 与 iOS 目标
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim

# 3) 前端依赖必须在 macOS 上重装：当前 node_modules 是 Linux 容器里装的，
#    里面只有 @tauri-apps/cli-linux-arm64-gnu，CLI 在 macOS 上无法运行
pnpm install
```

- **Xcode 版本（推断，未验证）**：`tauri.ios.conf.json` 声明 `minimumSystemVersion: 18.0`，因此预计需要自带 iOS 18 SDK 的 Xcode（16 及以上）。
- **磁盘**：Xcode + iOS SDK + 模拟器运行时通常需要数十 GB，本机当前可用约 20 GiB，需要先腾空间。
- **CocoaPods**：本仓库没有 Podfile，Tauri 的 iOS 工程以 XcodeGen 模板为扩展点，本路线预期不需要 CocoaPods；
  Tauri CLI 内部是否会调用 CocoaPods 未实测（见未决问题）。
- **Apple 账号**：模拟器构建不需要签名，可以先用免费账号；真机安装与 NetworkExtension entitlement 必须用付费账号。

### 1. 准备构建输入

```bash
bash scripts/ios/prepare.sh
```

该脚本做两件事：硬性检查 Xcode / iphoneos SDK / rustup 与 iOS target，并下载 gitignore 掉的 geo 数据库到
`src-tauri/resources`（这些文件在非 Android 平台由 `utils/init.rs:537-568` 从 bundle 资源目录复制到应用数据目录）。
它**故意不准备内核**：iOS 没有可用的 sidecar，见 §1.1。

### 2. 生成并改造 Xcode 工程

```bash
pnpm tauri ios init
# 已就位（在 tauri.ios.conf.json 里）：
#   * bundle.externalBin: [] —— 覆盖 base 的桌面 sidecar 列表，见下方说明；
#   * bundle.iOS.minimumSystemVersion: 18.0。
# 仍需要在 Xcode 工程侧补齐：
#   * 自定义 XcodeGen 模板（bundle.iOS.template）加入扩展 target 与 entitlement；
#   * App Group；
#   * bundle.iOS.developmentTeam（或 APPLE_DEVELOPMENT_TEAM）。
# 这些都应固化成 scripts/ios/ 下的脚本/模板，重新生成工程后可一键重放。
```

> **为什么 iOS 配置要把 `externalBin` 覆盖成 `[]`**：`tauri-build` 对 `externalBin` 没有 mobile 闸门，
> 它无条件地把每条路径拼成 `{path}-{rust target triple}`（上游 `tauri-utils/src/resources.rs` 的
> `external_binaries()`），再交给 `copy_binaries()` 复制，文件不存在就直接失败。所以 iOS 目标会去找
> `sidecar/verge-mihomo-aarch64-apple-ios`——一个 iOS 既不能执行、也不该打包的桌面内核。
> 平台配置的合并走 `json_patch::merge`（RFC 7396 合并补丁），数组这类非 object 的 patch 值是**整体替换**，
> 因此 `"externalBin": []` 能干净地覆盖掉 base 的列表。（机制由读取上游 tauri dev 分支源码复核，见 §3.2；
> 本仓库固定 `tauri-build 2.7.1` / CLI `2.12.1`，引用行号以 dev 分支为准。）

### 3. 构建内核库

从 mihomo 源码构建 XCFramework（gomobile 或 c-archive），产物随 app 与扩展一起签名。见 §1.5。

### 4. Rust 侧接入

需要新增（本分支尚未实现）：

- `core/tun_ios.rs` 之类的模块：接收扩展进程交来的隧道句柄/包 IO，把它写进 `enhance/tun.rs` 的 iOS 分支；
- `CoreManager` 的启动路径分支：iOS 上不再 `spawn` 内核，而是调用进程内库；
- 扩展进程的入口（`extern "C"`），以及主 app ↔ 扩展的 IPC 划分。

### 5. 构建与运行

```bash
pnpm tauri ios build      # 或 pnpm tauri ios dev
```

### 6. 首次运行的验证要点（未验证）

- 扩展日志里出现隧道建立与 gvisor 栈监听；
- `www.google.com` 命中 `DomainSuffix` 走代理、`www.baidu.com` 命中 `GeoSite(CN)` 走直连（与 Android 侧同一套判断）；
- Clash Verge"连接"页能显示连接与实时流量（说明主 app ↔ 内核的 IPC 通了）；
- 内核出站连接不回到隧道（对照 Android 的 `addDisallowedApplication`）。

## 三、当前状态

### 3.1 已改动的源码 / 配置（`ios-port` 分支工作区）

| 文件 | 状态 | 说明 |
| --- | --- | --- |
| `src-tauri/tauri.ios.conf.json` | 新增（未提交） | identifier `io.github.clashverge.rev`、`bundle.iOS.minimumSystemVersion: 18.0`、**`bundle.externalBin: []`**（覆盖桌面 sidecar 列表，见 §2）、`app.windows` 声明 main 窗口；`bundle.iOS.developmentTeam` **故意留空**（签名时由 `APPLE_DEVELOPMENT_TEAM` 或本地未提交覆盖提供，见 §1.4） |
| `scripts/ios/prepare.sh` | 新增（未提交，task-3 产出） | 前置检查 + geo 资源；见 §3.2 |
| `docs/IOS.md` | 新增（本文） | — |
| `src-tauri/capabilities/mobile.json` | Android 移植提交 `661ed38c` 已含 | `platforms: ["android", "iOS"]`，iOS 无需再改 |
| `src-tauri/Cargo.toml:146-152` | 已有 | `jni`/`ndk-context` 仅 android；tray/autostart 依赖用 `not(any(target_os = "android", target_os = "ios"))`（该行是上游提交 `6cc81fe6` 引入的，不是移植改动） |
| `core/*_mobile.rs`（`core/mod.rs:1-53`） | 已有 | `#[cfg(mobile)]` 空实现分发天然覆盖 iOS（autostart/hotkey/lightweight/proxy_control/sysopt/tray/updater） |
| `src-tauri/src/core/tun_android.rs` | 已有，仅 android | iOS 无对应实现 |

**已落地的 iOS 编译期门控收敛（未提交）**——这是"内核/TUN 之外的 iOS 目标适配"这条工作（task-1）的产出。
下表由本轮逐条读代码 + `git diff` 核对（行号为本轮实际值，语义与代码一致）：

| 文件 | 改动要点 |
| --- | --- |
| `src-tauri/src/feat/config.rs:21-26` | 新增 `#[cfg(target_os = "ios")]` 守卫：`enable_tun_mode == Some(true)` 时 `bail!`（"TUN mode is not supported on iOS: the Network Extension integration is not implemented"） |
| `src-tauri/src/constants.rs:65-68` | `tun::DEFAULT_STACK`：由 `android` / `not(android)` 扩为 `any(android, ios)` / `not(any(...))`，iOS 与 Android 一样是 `gvisor`，桌面仍是 `mips` |
| `src-tauri/src/core/manager/lifecycle.rs:824-825` | `service_required` 由 `!cfg!(target_os = "android")` 改为 `cfg!(desktop)`：移动端永不安装特权服务 |
| `src-tauri/src/core/runstate/health.rs:66-73` | `tun_capable()`：android 仍为 `true`；其余平台改为 `!cfg!(any(android, ios)) && (is_admin \|\| service_usable())`，即 **iOS 恒为 `false`** |
| `src-tauri/src/core/service.rs:347`、`694` | `trusted_service_evidence()`（返回 `Ok(false)`）与 `uninstall_service()`（`bail!`）的 cfg 由 android 扩为 `any(android, ios)`；原先 iOS 目标缺少这两个定义，会编译失败 |
| `src-tauri/src/utils/dirs.rs:177`、`299` | `service_path()`（返回 `Err`）与 `sidecar_ipc_path_for()`（app 数据目录内的 unix socket）的 cfg 扩为 `any(android, ios)`；原先 iOS 同样缺定义 |
| `src-tauri/src/utils/init.rs:623` | `init_scheme()` 的移动端空实现（deep link 由各平台清单声明）扩到 iOS |

**已落地的 vendored crate 补丁（未提交）**——`vendor/clash-verge-service-ipc` 里 ios-rust 的修复（task-4）：

| 文件 | 改动要点 |
| --- | --- |
| `vendor/clash-verge-service-ipc/src/execution.rs:324-326` | `other_helper` 的 fallback 绑定由 `#[cfg(target_os = "android")]` 扩为 `#[cfg(any(target_os = "android", target_os = "ios"))]`（`PathBuf::new()`）。此前 iOS 属于 `cfg(unix)` 却没有绑定，344 行的 `executable != other_helper` 会报 `E0425`；修完后 macos / linux / android / ios 四条 unix 分支都有绑定 |

这一处是本分支目前**唯一做过 iOS 目标编译检查**的代码（局部实测结果见 §3.4）。

以上所有改动都**只收敛了编译期门控缺口**，让 iOS 目标能走到"移动端分支"：它既没有内核（`dirs.rs:171-174`
的 `core_sidecar_binary_path` 仍返回 `Err`），也没有 Network Extension、entitlement 与进程内内核。
换句话说，**"门控缺口收敛"不等于"iOS 可用"，局部 crate 通过也不等于"整机 iOS 能编译"**——见 §3.3 与 §3.5。

### 3.2 已实测 / 已验证（本会话实际执行过）

| 结论 | 命令 | 结果 |
| --- | --- | --- |
| 本机只有 CommandLineTools，没有 Xcode | `xcode-select -p` | `/Library/Developer/CommandLineTools` |
| 取不到 iphoneos SDK | `xcrun --sdk iphoneos --show-sdk-path` | `xcrun: error: SDK "iphoneos" cannot be located`，退出码非 0 |
| 没有 `simctl` | `xcrun simctl list devices` | `xcrun: error: unable to find utility "simctl"` |
| `xcodebuild` 存在但不可用 | `xcodebuild -version` | `xcode-select: error: tool 'xcodebuild' requires Xcode ...` |
| 本机没有 Rust 工具链 | `command -v rustup` / `command -v cargo` / `ls ~/.cargo ~/.rustup` | 均不存在 |
| 本机没有 CocoaPods | `command -v pod` | 无输出 |
| 本机环境 | `sw_vers`、`df -h /` | macOS 26.5.1 (25F80)；可用空间约 20 GiB |
| Tauri CLI 在当前 `node_modules` 里跑不起来 | `./node_modules/.bin/tauri ios --help` | `Cannot find native binding`；`.pnpm` 里只有 `@tauri-apps/cli-linux-arm64-gnu` |
| `bundle.iOS.*` 字段合法、`developmentTeam` 是 iOS 必需项 | 读 `node_modules/@tauri-apps/cli/config.schema.json` | `bundle.iOS` 支持 `template/frameworks/developmentTeam/bundleVersion/minimumSystemVersion/infoPlist`；`developmentTeam` 描述为 "required for iOS development because code signing is enforced" |
| 脚本语法正确 | `bash -n scripts/ios/prepare.sh` | 退出码 0 |
| 脚本在缺 Xcode 时报错退出且不产生副作用 | `bash scripts/ios/prepare.sh` | 退出码 1，输出"需要完整 Xcode + `sudo xcode-select -s ...`"；前置检查在 `mkdir` 与下载之前，本次运行没有创建/修改任何构建输入 |
| 脚本读取的部署目标与配置一致 | 单独执行脚本里的 python 表达式 + case 分支复现 | `18.0`；`/Library/Developer/CommandLineTools` 被拒、`Xcode.app` 与 `Xcode-beta.app` 通过 |
| 上游没有 iOS 预编译内核 | `curl .../releases/expanded_assets/v1.19.32` 后 grep | 资产前缀只有 `android-/darwin-/freebsd-/linux-/windows-`，无 `mihomo-ios*` |
| mihomo 可被编成进程内库的先例 | `curl` 上游 ClashMetaForAndroid `core/build.gradle.kts` | golang-android 插件、Go 包 `cfa/native`、tag `foss,with_gvisor,cmfa`、输出 `libclash.so` |
| task-1 的 iOS 门控改动内容与行号 | `git diff src-tauri/src`，逐文件读源码 | 与 §3.1 表一致（7 个文件、语义如表中所述） |
| task-4 的 `other_helper` 修复已落地 | `git diff vendor/` + 读 `vendor/clash-verge-service-ipc/src/execution.rs` | 第 325-326 行已是 `#[cfg(any(target_os = "android", target_os = "ios"))]`；四条 unix 绑定齐备（macos:306 / linux:317 / mobile:325-326），344 行的使用处不再悬空 |
| iOS 配置已覆盖 `externalBin` | 读 `src-tauri/tauri.ios.conf.json` | `bundle.externalBin: []`，`bundle.iOS` 只有 `minimumSystemVersion` |
| `externalBin` 的机制（为什么 `[]` 是必要的） | `curl` 上游 tauri dev 分支的 `crates/tauri-utils/src/resources.rs`、`crates/tauri-build/src/lib.rs`、`crates/tauri-utils/src/config/parse.rs` | `external_binaries()` 无条件拼 `{path}-{target_triple}`（resources.rs:46-61）；`tauri-build` 的 `if let Some(paths) = &config.bundle.external_bin { copy_binaries(...) }` 没有 mobile 闸门（lib.rs:735-742）；平台配置合并用 `json_patch::merge`（parse.rs:7、lib.rs:683），数组整体替换 → `[]` 覆盖生效 |

此外，文档中所有"代码库事实"（文件行号、cfg 门控、脚本行为）都通过实际读取相应文件核对。

### 3.3 已改动但仍**未做整机 iOS 编译验证**

以下内容只经过读代码/读 diff 核对，**没有在 iOS 目标上编译过**（本机无 Rust 与 Xcode，见 §3.2 与 §3.5）：

- §3.1 表中 task-1 的 7 处 cfg 门控改动——静态阅读看起来自洽，但"是否还有别的 iOS 编译错误"没有结论；
- `src-tauri/tauri.ios.conf.json`、`scripts/ios/prepare.sh`、`docs/IOS.md` 本身；
- `src-tauri/capabilities/mobile.json` 里 `platforms` 已含 `"iOS"` 的既有声明。

**唯一有 iOS 编译证据的例外**：`vendor/clash-verge-service-ipc` 这个 crate。它的 `other_helper` 缺绑定问题
（`E0425`，execution.rs:344）已由 task-4 修复（§3.1），并且 ios-rust 在容器里对修复前后做了对比检查：
**修复前 EXIT=101、修复后 EXIT=0（0 error / 0 warning）**。该 crate 在 `features=client` 下不依赖
`objc2`/`tauri`/iOS SDK，所以能在 Linux 容器里直接 `cargo check --target aarch64-apple-ios`——
详细命令与结果见 §3.4。**这是局部验证：它只说明这一个 crate 能过 iOS 目标检查，不能外推到 `src-tauri`（Tauri 应用本体）。**

静态扫描的附带观察（非编译结论）：`src-tauri/src` 里其余 android-only 分支都是"元素/效应级"的，
例如 `constants.rs:84` 的 `file-descriptor` 键、`feat/effects.rs:35` 的 TUN 重启效应、`core/mod.rs:52` 的 `tun_android`
模块，它们没有 `not(android)` 配对分支也不会让 iOS 编译失败——但这一点仍需真实编译确认。

### 3.4 由 Lead / teammate 实测报告（本文档未复现）

- **vendored crate 的 iOS 目标检查（task-4，ios-rust 在容器中执行）**：

  ```bash
  docker exec cv-android bash -c 'cp -r /workspace/clash-verge-rev/vendor/clash-verge-service-ipc /tmp/vcsipc-ios \
    && cd /tmp/vcsipc-ios && cargo check --target aarch64-apple-ios --features client --lib'
  ```

  修复前（用 `git show HEAD:vendor/.../execution.rs` 还原那一行）：EXIT=101，
  `error[E0425]: cannot find value 'other_helper' in this scope`（execution.rs:344）；
  修复后：EXIT=0，0 error / 0 warning。
  **边界**：只有这一个 crate；`objc2` / Tauri / iOS SDK 相关的构建阶段都没有参与，所以不能据此声称整机可编译。
  本文档没有重新执行该命令（本机无 Rust，且不在共享容器里跑重编译），只记录了 teammate 给出的命令与结果。
- Linux 构建容器可以 `rustup target add aarch64-apple-ios`，但 `cargo check --target aarch64-apple-ios`
  在 Tauri 应用本体上会在 `objc2-exception-helper` 的 build script 处失败（缺 `clang`、`xcrun`/iOS SDK）。
  **结论：整机的 iOS 编译验证必须在装有 Xcode 的 macOS 上做**，容器只能用来做像上面那样不依赖 SDK 的局部检查。
- 前端构建、Android 目标不回归等验证由 Lead 在其会话中完成；本次编写本文档时**没有重新执行**（不想在共享工作区里
  跑会写 `dist/`、`target/` 的重命令）。

### 3.5 完全未验证（因缺少 Xcode）

- **整机** iOS 编译/打包：`tauri ios init/build/dev`、`cargo check/build --target aarch64-apple-ios -p clash-verge`；
  （`vendor/clash-verge-service-ipc` 的单 crate 检查是唯一例外，见 §3.4）；
- `build.rs` 与各 Tauri 插件在 iOS 上的行为；`bundle.resources`（含 geo 数据库）是否真的被拷进 app bundle；
- **iOS 目标是否已经能编译**：task-1 收敛了 cfg 门控缺口、task-4 修掉了 vendored crate 的 `E0425`
  且该 crate 局部检查通过，但 `src-tauri`（Tauri 应用本体）从未跑过 iOS 编译，
  因此不能声称"iOS 可编译"，也无法排除还有第三个阻塞点；
- `bundle.externalBin: []` 覆盖在真实 iOS 构建里的效果（机制已核实、配置已落地，见 §2 / §3.2 / 未决问题 5）；
- NetworkExtension、entitlement、签名、真机运行的一切环节。

## 四、未决问题与后续任务

1. **隧道形态 spike（最高优先级）**：在真实 Xcode 环境里做一个最小 `NEPacketTunnelProvider`，
   验证方案 A（`packetFlow` + 内核包级 IO）与方案 B（KVC 取 fd）哪个可行，产出结论后再定架构。
2. **内核可链接性**：确认 mihomo 能否用 `gomobile bind -target=ios`（或 c-archive）编出 XCFramework；
   需要哪些 build tag、是否需要裁剪（如 `with_gvisor`）、体积与内存占用多少。
3. **进程/职责划分**：内核跑在扩展进程后，谁生成运行配置、谁持有 mihomo API、主 app 如何经
   App Group + `NETunnelProviderSession` 访问；`CoreManager` 的 sidecar 启动路径（`state.rs:162-329`）需要拆分。
4. **Xcode 工程可重放化**：把扩展 target / entitlement / App Group 固化成
   `scripts/ios/` 下的模板或补丁脚本（对齐 `scripts/android/templates/` 的做法），并考虑用 `bundle.iOS.template`。
5. **`bundle.externalBin` 处理（已定论并落地）**：`tauri.conf.json` 的 `externalBin` 指向桌面内核，iOS 不应携带；
   已确认 `tauri-build` 对 `externalBin` 没有 mobile 闸门，会要求 `sidecar/verge-mihomo-aarch64-apple-ios` 存在，
   而平台配置合并是 RFC 7396 合并补丁（数组整体替换），因此在 `src-tauri/tauri.ios.conf.json` 里写
   `bundle.externalBin: []` 即可干净覆盖。机制核对见 §3.2，落地状态见 §3.1。
   **未验证的余项**：真正的 iOS 构建里这一步是否不再报缺文件（要等 Xcode 环境）；以及将来要随包分发
   iOS 内核库时应走什么路径（当前设计是链接进 app/扩展，不是 externalBin）。
6. **`developmentTeam` 的落地方式（已定）**：`tauri.ios.conf.json` 里留空，签名时用 `APPLE_DEVELOPMENT_TEAM`
   或本地未提交覆盖提供，避免把团队 ID 提交进仓库；真机构建前必须补上。
7. **iOS 上的 TUN 开关语义（已实现，待验收前端表现）**：`patch_verge` 现在会在 iOS 上直接 `bail!`（见 §3.1），
   不再把内核无法满足的 TUN 配置写下去；剩下的是确认前端如何呈现这个错误（提示文案 / 是否直接禁用开关）。
8. **扩展资源与内存**：geo 数据库、规则集在扩展进程里的常驻开销与系统内存限制需要实测。
9. **前端 iOS 适配**：安全区、`get-system.ts` 的系统识别等已有并发改动（工作区中 `src/utils/get-system.ts`、
   `src/assets/styles/layout.scss` 等多处处于修改状态），需要与本文档的架构结论对齐后再验收。
10. **`vendor` 侧的平台适配（已解决）**：`vendor/clash-verge-service-ipc/src/execution.rs` 的 `other_helper` 缺口
    已由 task-4 修复并在容器里做过该 crate 的 iOS 目标检查（§3.4）。仍待确认的是**其它第三方 crate**
    在 iOS 上的兼容性——`objc2-exception-helper` 已由 Lead 报告过，只有整机编译才能给出完整结论。
11. **文档与验证补齐**：搭起 Xcode 环境后，把 §3.5 的每一项都变成可复现的命令与结果，再更新本文档。

## 五、已知限制

- 当前分支没有可运行的 iOS 产物：内核、Network Extension、entitlement 与签名都未实现；task-1 只收敛了编译期 cfg 门控。
- **整机 iOS 编译从未执行过**（本机无 Rust 与 Xcode），因此不能声称 iOS 目标可编译；目前唯一的 iOS 编译证据是
  不依赖 SDK 的 `vendor/clash-verge-service-ipc` 单 crate 检查通过（§3.4）。
- 本机（macOS 26.5.1）无 Xcode、无 Rust 工具链、无 CocoaPods，可用磁盘约 20 GiB；此前所有平台相关验证都不适用于 iOS。
- mihomo 上游没有 iOS 预编译产物，`pnpm prebuild` 也不支持 `aarch64-apple-ios`。
- iOS 上的 TUN/系统代理与 Android 一样无法照搬桌面实现；系统代理在 `sysopt_mobile.rs` 与 `cmd/network.rs` 中已是空实现/回显。
- 应用内更新在移动端不可用（`updater_mobile.rs`）。
