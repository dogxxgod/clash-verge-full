# Android 构建说明

本仓库在 `android-port` 分支上增加了 Android 目标支持，产物为可直接安装的 APK（arm64-v8a，minSdk 24 / targetSdk 36，可在 Android 16 上安装）。

上游 clash-verge-rev 是 Tauri v2 桌面应用，Android 支持通过以下方式实现：

## 移植要点

| 领域 | 处理方式 |
| --- | --- |
| 平台插件 | `tauri-plugin-autostart` / `global-shortcut` / `updater` / `window-state` 仅在桌面构建中注册 |
| 托盘、全局快捷键、自动更新、轻量模式、系统代理 | 桌面模块加 `#[cfg(desktop)]` 门控，并为移动端提供同接口空实现（`core/*_mobile.rs`） |
| 应用数据目录 | Android 上 `dirs` crate 返回 XDG 路径不可写；`utils/dirs.rs::app_home_dir` 改为经 Tauri `PathResolver` 解析 |
| 单一实例 / 内嵌 HTTP 服务 | 桌面在 builder 之前检查；移动端在 `setup()` 内（AppHandle 就绪后）执行 |
| 主窗口 | Android 由 `tauri.android.conf.json` 中的 `app.windows` 声明，运行时自动创建；`build_new_window` 在移动端复用该窗口 |
| mihomo 内核 | Android 禁止执行应用数据目录中的文件（W^X）。内核以 `libverge-mihomo.so` 形式打包进 `jniLibs`，由系统解压到 `nativeLibraryDir` 后执行；`utils/dirs.rs::core_sidecar_binary_path` 通过 `/proc/self/maps` 定位该目录 |
| sidecar 启动 | Tauri shell 插件的 `sidecar()` 以 `current_exe()` 解析路径，在 Android 上不可用；移动端改用 `shell().command(绝对路径)` 启动内核 |
| 服务模式 | Android 无特权守护进程，`core::service` 自动退化为 "未安装" 状态，内核走 Sidecar 路径 |
| 标识符 | Android 包名不允许连字符，`tauri.android.conf.json` 覆盖为 `io.github.clashverge.rev` |
| 能力（capabilities） | 新增 `mobile-capability`；`migrated` 中桌面专属权限（global-shortcut）移除 |
| tauri-plugin-mihomo | 上游插件 `build.rs` 声明 `.android_path("android")` 但仓库不提供该 Kotlin 工程，Gradle 会报 “:tauri-plugin-mihomo 无可用 variant”。已 vendor 到 `vendor/tauri-plugin-mihomo` 并移除该声明（应用只用其 Rust API） |
| TUN 模式 | 由 `VpnTunService`（`VpnService`）建立隧道并 `detachFd()`，经 JNI 把描述符交给内核的 `tun.file-descriptor`；自身包名加入 `addDisallowedApplication`，内核出站连接直接走物理网卡 |
| 内核 TUN 参数 | Android 上强制 `stack: gvisor`、`auto-route / auto-redirect / strict-route: false`、`dns.enhanced-mode: fake-ip`：内核仅编译了 gvisor 栈，非 root 无法下发 iptables/nftables 规则，且被污染的域名解析会让浏览器长时间卡住 |
| 非 root 包列表 | sing-tun 读取 `/data/system/packages.xml` 组装 Android 规则集，普通应用无权打开会导致 TUN 启动失败；`scripts/android/prepare.sh` 把内核中该定长字符串改写为等长的全局可读 XML 文件，得到空规则集 |

## TUN 模式

`src-tauri/src/core/tun_android.rs` 是 Rust 侧的全部实现，`scripts/android/templates/` 下是随源码分发的 Kotlin 部分（`gen/android` 被 gitignore，构建时由 `prepare.sh` 覆盖安装）。

开关 TUN 的调用链：

1. 前端 `patch_verge_config` → `feat::config::patch_verge`；
2. 打开时 `start_vpn_service_and_wait_fd()`：申请 VPN 授权 → 启动前台服务 → 等待描述符，并用 `fcntl` 清除 `FD_CLOEXEC` 以便子进程继承；
3. 配置生成时 `enhance::tun::use_tun` 写入 `file-descriptor` 与上述强制参数；
4. 关闭时 `stop_vpn_service()` 并重启内核——只有新进程才会释放描述符与监听。

## 已知限制

- **仅 arm64-v8a**：只打包了 `aarch64` 内核。
- **Geo 数据库随包分发**：Android 上应用资源无法作为普通文件读取，geo 数据在编译期嵌入二进制并在首次启动释放到应用目录。
- 应用内更新不可用（升级需重新安装 APK）。
- `packages.xml` 补丁依赖内核中该字符串的出现次数，`prepare.sh` 在次数不为 1 时会显式报错，内核升级后需重新确认。
- 日志中出现 `create watcher for packages list: fswatch: watch ... permission denied` 是该补丁的预期副作用：SELinux 不允许普通应用监视该文件，读取本身正常，随后 TUN 监听照常启动。

## 排查记录

### 连接页恒为空

症状是连接页一直显示 `ACTIVE 0` 与 `0.00B`，但流量确实在转发。目前已知两个不同根因，症状完全相同：

1. **打包器覆盖绑定名**：入口 chunk 里 `MihomoWebSocket` 与一处无关的内部对象被压缩成了同一个变量名，所有 `connect_*` 都落到错误对象上，异常又被各 supervisor 的重连逻辑吞掉。修复见 `vite.config.mts` 的 `manualChunks`（把 `tauri-plugin-mihomo-api` 拆成独立 chunk）。
2. **移动端可见性判断**：`plugin:window|is_visible` 在 Android 上恒为 `false`（tao 在 Android 上忽略 `Window::is_visible`，logcat 中有对应告警），而 `useVisibility` 把它和 `document.visibilityState` 做了与运算，`pageVisible` 因此恒为 false，连接页与流量监控根本不建立订阅。修复见 `src/hooks/use-visibility.ts`（移动端跳过窗口探测，只采信 WebView 自身的可见性）。

诊断顺序：先用 `plugin:mihomo|get_connections` 与 `plugin:mihomo|ws_connections` 判断后端与通道是否正常，再查 `pageVisible` 的实际取值。用控制台点击复现时**不要派发 `pointerdown`**，否则会被 `handlePointerDown` 里的 `setVisible(true)` 掩盖问题。

## 构建

### 1. 构建环境（OrbStack Docker，arm64）

```bash
docker build --platform linux/arm64 -t clashverge-android-build docker/android
docker run -d --name cv-android -v "$PWD":/workspace -w /workspace/clash-verge-rev clashverge-android-build sleep infinity
```

Google 只发布 x86_64 主机的 NDK 工具链，镜像内已安装 amd64 运行库，OrbStack 会通过 Rosetta 执行 NDK clang。

### 2. 准备内核与前端依赖

```bash
docker exec cv-android bash -lc 'source /opt/container-env.sh && cd /workspace/clash-verge-rev \
  && CI=true pnpm install --frozen-lockfile --registry=https://registry.npmmirror.com'
```

### 3. 生成 Android 工程并构建 APK

```bash
docker exec cv-android bash -lc 'source /opt/container-env.sh && cd /workspace/clash-verge-rev \
  && pnpm tauri android init --ci \
  && bash scripts/android/prepare.sh \
  && CI=true CARGO_BUILD_JOBS=6 CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_DEV_STRIP=debuginfo \
     pnpm tauri android build --apk --debug --target aarch64'
```

产物位于 `src-tauri/gen/android/app/build/outputs/apk/universal/debug/app-universal-debug.apk`
（debug 签名，`minSdk 24 / targetSdk 36`，可直接安装到 Android 16；不 strip 时约 225MB，
上面两个环境变量把 debuginfo 去掉后约 50MB）。

> 已实测：package `io.github.clashverge.rev`、versionName `2.5.9`、compileSdk/targetSdk `36`，
> `lib/arm64-v8a/` 内含 `libapp_lib.so` 与 `libverge-mihomo(.alpha).so`。

`scripts/android/prepare.sh` 会：

1. 下载 mihomo Android arm64 内核并按 Tauri 目标三元组命名放入 `src-tauri/sidecar/`；
2. 从原始缓存派生一份改写过的内核（`node_modules/.verge/mihomo-android-arm64.vpn`），把内核读取系统包列表的路径改为等长的全局可读文件，原始缓存保持不变；
3. 把派生内核复制为 `gen/android/app/src/main/jniLibs/arm64-v8a/libverge-mihomo.so`；
4. 把 `scripts/android/templates/*.kt` 覆盖安装到生成工程的 `java/io/github/clashverge/rev/`；
5. 让 Gradle 使用 legacy JNI 打包（`useLegacyPackaging = true`），确保内核被解压到 `nativeLibraryDir` 且可执行；
6. 将 compileSdk/targetSdk 调整到 36（Android 16）；
7. 在 manifest 中声明 `extractNativeLibs`、VPN 相关权限与 `VpnTunService`。

因为 `gen/android` 被 gitignore，第 3、4、7 步是重新克隆后能构建出可用 APK 的必要条件。

## 模拟器验证

在 Android 16（API 36，arm64）模拟器上以 release 签名包实测通过：

- `[TUN] Tun adapter listening at: tun0(fd=256)([198.18.0.1/30],...)` 说明描述符已成功交接；
- 浏览器访问 `www.google.com` 命中 `DomainSuffix(google.com)` 走代理解析，`www.baidu.com` 命中 `GeoSite(CN)` 走直连；
- Clash Verge 的“连接”页显示上述连接与实时上下行流量。

> 模拟器上验证过但需要真机复核的一点：非 root 补丁改写的目标文件是可读的 AOSP 文件，
> 但在 SELinux 下 `inotify` 监视该文件会被拒绝（日志中出现 `avc: denied { watch }`）。
> 读取本身不受影响，实测不影响启动；真机首次运行时建议确认该告警是否出现。
