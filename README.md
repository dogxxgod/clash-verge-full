# clash-verge-full

把 [clash-verge-rev](https://github.com/clash-verge-rev/clash-verge-rev)（面向桌面的 Tauri v2 Clash GUI）
移植到**移动端**的项目：**Android 已可用，iOS 进行中**。

上游不支持 Android / iOS。本仓库在尽量不破坏桌面代码的前提下，用
「桌面/移动 cfg 门控 + 移动端同接口空实现」的方式增加移动端支持。

> 本仓库早期是上游的 fork，现已独立管理（私有），开发集中在 `main` 一条分支上。
>
> `docs/README_*.md`、`docs/preview_*.png` 等是**上游项目**的多语言文档与截图，与本移植无关，
> 保留仅为减少与上游 diff。

---

## 移植状态

| 平台 | 状态 |
| --- | --- |
| **Android 16（arm64-v8a）** | ✅ 可用。VpnService(TUN) 全局代理已在 Android 16 模拟器上端到端验证 |
| **iOS（目标 iPhone 12 Pro / iOS 18）** | 🚧 源码级适配已完成（配置、门控、UI、文档）；**TUN 与 Network Extension 尚未实现**，整机编译验证进行中 |

## Android 已实现

- **VpnService(TUN) 全局代理**：`VpnService` 建立隧道并 `detachFd()`，清除 `FD_CLOEXEC` 后经 JNI 把描述符
  交给内核的 `tun.file-descriptor`；自身包名加入 `addDisallowedApplication`，内核出站连接直接走物理网卡。
  其它 App **无需任何代理设置**即可被内核分流。关闭 TUN 时重启内核以释放描述符与监听。
- **内核以共享库形式运行**：Android 禁止执行应用数据目录中的文件（W^X），因此 mihomo 以
  `libverge-mihomo.so` 打进 `jniLibs`，由系统解压到 `nativeLibraryDir` 后启动；
  内核在非 root 沙箱下读取系统包列表失败的问题已在构建脚本中处理。
- **Geo 数据随包分发**：移动端资源不能作为普通文件读取，geo 数据在编译期嵌入二进制、首次启动释放到应用目录。
- **移动端界面**：窄屏底部标签栏、刘海/手势条安全区、44pt 触控下限，并按平台隐藏桌面专属控件
  （窗口控制按钮、标题栏拖拽区、右键菜单、"优先使用系统标题栏"开关等）。
- **构建可复现**：`gen/android` 被 gitignore，Kotlin 源码与内核补丁都由脚本复原，克隆后一条命令即可还原构建输入。
- **Release 签名 APK**：arm64-v8a，`minSdk 24 / targetSdk 36`，约 141 MB。

## iOS 现状

源码层面已就绪：`#[cfg(target_os = "ios")]` 的平台门控补齐、`tauri.ios.conf.json`、
iPhone 12 Pro 的 UI 适配，以及记录架构与前置条件的 [`docs/IOS.md`](docs/IOS.md)。

**TUN 尚未实现**，原因是 iOS 与 Android 的机制根本不同，见下表。要补齐需要：
把 mihomo 编译成可链接库（上游不发布 iOS 产物）、新增 Network Extension 扩展 target 与 entitlement、
App Group，并重新划分「谁生成配置、谁调用内核 API」。

| | Android | iOS |
| --- | --- | --- |
| 隧道 | `VpnService` 拿到 fd | 只有 Network Extension 的 `packetFlow` |
| 内核形态 | 独立进程（sidecar） | **必须**链进扩展进程，不能是独立进程 |
| 数据交接 | `detachFd()` → JNI → `tun.file-descriptor` | 扩展内直接读写数据包（无公开 fd 可用） |
| 前置门槛 | 应用权限 + 用户授权 VPN | 付费 Apple Developer 账号 + NE entitlement |

## 文档

| 文档 | 内容 |
| --- | --- |
| [`docs/ANDROID.md`](docs/ANDROID.md) | Android 移植要点、构建步骤、TUN 调用链、排查记录 |
| [`docs/IOS.md`](docs/IOS.md) | iOS 架构方案、前置条件、构建路径与**当前验证边界** |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | 上游贡献规范（沿用） |
| [`PRIVACY.md`](PRIVACY.md) | 隐私说明（不收集用户数据，配置与日志仅存本地） |

## 分支与上游同步

只有一条开发分支：

| 分支 | 用途 |
| --- | --- |
| `main` | 唯一分支，包含上游历史 + 全部移植成果 |

需要跟进上游新版本时，从上游 remote 拉取后合并到 `main`：

```bash
git fetch upstream
git merge upstream/dev          # 或 upstream/main，视上游当前主线而定
```

## 构建

### Android（在 Linux 容器内构建）

```bash
# 1) 还原 Android 构建输入：内核（含非 root 补丁）、Kotlin 源码、gradle/manifest 补丁
bash scripts/android/prepare.sh

# 2) 打包（会先跑前端 tsc --noEmit）
CI=true CARGO_BUILD_JOBS=6 CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_DEV_STRIP=debuginfo \
  pnpm tauri android build --apk --debug --target aarch64
```

产物：`src-tauri/gen/android/app/build/outputs/apk/universal/debug/app-universal-debug.apk`。
完整的容器环境、签名与模拟器验证流程见 [`docs/ANDROID.md`](docs/ANDROID.md)。

### iOS（需要 macOS + Xcode）

前置条件、`tauri ios init`、内核库编译方式与尚未打通的部分，见 [`docs/IOS.md`](docs/IOS.md)。

## 已知限制

- **仅 arm64-v8a**，未构建其它 ABI。
- **Android 真机未验证**：现有结论来自 Android 16 模拟器（OPPO Find X8 规格），真机复核待做。
- **iOS 的 TUN 未实现**；Network Extension、签名与模拟器验证均未完成。
- 应用内更新不可用（移动端为同接口空实现）。
- 移动端没有可写的系统代理，桌面那套「系统代理」开关在移动端仅反映配置状态。

## 许可与致谢

沿用上游的 **GPL-3.0** 许可（见 [`LICENSE`](LICENSE)）。本项目的代码与设计来自：

- [clash-verge-rev/clash-verge-rev](https://github.com/clash-verge-rev/clash-verge-rev) — 本项目的基础
- [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) — 内核
- [tauri-apps/tauri](https://github.com/tauri-apps/tauri) — 应用框架

感谢上述项目及其贡献者。
