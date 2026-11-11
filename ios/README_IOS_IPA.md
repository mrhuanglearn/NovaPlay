# 星映 (NovaPlay) iOS 15.0+ `.ipa` 构建与三合一签名指南

本工程已在同一套代码库（`uzv-reimpl/flutter_app`）内完整集成 **iOS 15.0+ (`IPHONEOS_DEPLOYMENT_TARGET = 15.0`)** 原生播放器、弹幕渲染、触感反馈与 Node.js (`nodejs-mobile` `--jitless`) 运行时，并对 Android 端保持零侵入。

---

## 一、iOS 端架构与专属适配一览

1. **双内核原生播放器 (`packages/novaplay_ios`)**
   - **`AVPlayer (SYSTEM)`（默认）**：基于 Apple `VideoToolbox` 系统硬件解码，原生支持 **iOS 系统画中画 (PiP)**、**AirPlay 隔空投屏 (`AVRoutePickerView`)**、锁屏 / 灵动岛播放控制 (`MPNowPlayingInfoCenter`)、DASH 音画分离流及外挂 `.srt` / `.vtt` / `.ass` 字幕。
   - **`VLC (FFmpeg)` (`MobileVLCKit ~> 3.6.0`)**：基于 `libvlc` + `FFmpeg`，支持 `MKV`、`FLV`、`AVI`、`TS`、`RMVB`、内封 `ASS/SSA` 多轨字幕与多音轨，并支持 **硬件加速开关 (`VideoToolbox` 硬解 / `FFmpeg` 多线程软解)** 动态切换与原地重载续播。
2. **UI 与「设置 -> 播放器」平台对齐**
   - iOS 端「设置 -> 播放器」与播放页右上角齿轮抽屉完全对齐 iOS 真实支持的能力：展示 `AVPlayer (SYSTEM)` / `VLC (FFmpeg)` 内核与对应能力说明，隐藏 Android 专属的 `/storage/emulated/0/Fonts` 字体目录项，支持从 iOS「文件 (Files)」App 直接导入本地字幕文件或输入网络字幕 URL。
   - 进度条拖动等待框居中实时网速、画中画点 `×` 立即通知会话关闭（防止详情页“立即播放”置灰）、长按滑动倍速 (`0.5x ~ 8.0x`)、截图保存系统相册均已完整对齐。
3. **Node.js 免 JIT 运行时（兼容未越狱个人签 / 企业签 / 巨魔）**
   - 通过 `NodeMobile.xcframework` + `4 MiB` 独立 `pthread` 栈以 `--jitless` 模式启动内嵌 Node 18，无需 `dynamic-codesigning` 等受限权限即可在未越狱 iOS 15 ~ iOS 18+ 上运行 `catpaw` 与本地弹幕服务。

---

## 二、如何生成 `.ipa` 安装包

由于 Apple iOS SDK 与 Xcode 仅能在 macOS 上运行，提供以下两种构建方式：

### 方式 A：GitHub Actions 云端一键打包（推荐，无需本地 Mac）

仓库已内置工作流 `.github/workflows/build-ios-ipa.yml`：
1. 将代码推送到 GitHub 仓库（私有仓库同样支持）。
2. 打开 GitHub 仓库页面 -> **Actions** -> **Build NovaPlay iOS 15+ IPA** -> 点击右侧 **Run workflow**：
   - `include_vlc = true`（默认）：打包包含 `AVPlayer + VLC (MobileVLCKit)` 双内核完整版 `novaplay-0.1.0-ios15-arm64.ipa`。
   - `include_vlc = false`：打包仅含 `AVPlayer` 的轻量版 `novaplay-0.1.0-ios15-arm64-slim.ipa`。
3. 构建完成后在工作流底部的 **Artifacts (`novaplay-ios15-ipa`)** 下载 `.ipa`（若推送 `v*` 标签如 `v0.1.0`，还会自动发布到 GitHub Releases）。

### 方式 B：在 macOS 本地一行命令打包

确保已安装 Xcode 15/16+、Flutter Stable、CocoaPods（可选 `brew install ldid`）：

```bash
cd uzv-reimpl/flutter_app
bash ios/scripts/package_ipa.sh
```

构建产物位于：
`uzv-reimpl/flutter_app/build/ios/ipa/novaplay-0.1.0-ios15-arm64.ipa`

---

## 三、三合一安装与签名说明

输出的 `.ipa` 已剔除所有付费专属受限 Entitlements（仅使用免费证书也支持的 `UIBackgroundModes = audio`），并对主程序及 `Frameworks/` 下所有动态库完成了 `ldid -S` 伪签 + Bitcode 清理：

1. **巨魔 TrollStore（iOS 15.0+ 支持巨魔的设备）**
   - 直接将 `.ipa` 分享/导入到 **TrollStore** 即可一键永久安装，无需重签，画中画、后台播放、AirPlay 与本地 Node 服务全部直接可用。
2. **个人证书自签（Apple ID / 个人开发者账号）**
   - 使用 **Sideloadly**、**AltStore / SideStore**、**爱思助手** 或 **ESign（轻松签）** 选择该 `.ipa` 即可自动覆盖重签并安装（支持自定义修改 Bundle ID 多开，不会触发受限权限报错）。
3. **企业证书签名（企业签 / 定制签）**
   - 使用 **轻松签 (ESign)**、**全能签**、**GBox** 或命令行 `zsign -k cert.p12 -p <密码> -m prov.mobileprovision -o signed.ipa novaplay-0.1.0-ios15-arm64.ipa` 即可直接重签分发。
