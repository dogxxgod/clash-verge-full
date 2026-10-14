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

## 已知限制

- **系统代理 / TUN 模式不可用**：Android 没有可写的系统代理，VPNService（TUN）需要在 Java/Kotlin 层实现，当前版本未包含。
- **内核需要在应用内启动**：仅 `aarch64`（arm64-v8a）内核已打包。
- **Geo 数据库不随包分发**：mihomo 首次需要时自行下载 `geoip.dat` / `geosite.dat` / `Country.mmdb`。
- 应用内更新不可用（升级需重新安装 APK）。

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
2. 把内核复制为 `gen/android/app/src/main/jniLibs/arm64-v8a/libverge-mihomo.so`；
3. 让 Gradle 使用 legacy JNI 打包（`useLegacyPackaging = true`），确保内核被解压到 `nativeLibraryDir` 且可执行；
4. 将 compileSdk/targetSdk 调整到 36（Android 16）。
