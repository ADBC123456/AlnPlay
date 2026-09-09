# AlnPlay

<p align="center">
  <img src="assets/alnplay_app_icon.png" width="180" alt="AlnPlay logo">
</p>

<p align="center">面向本地文件与家庭媒体库的跨平台视频播放器。</p>

[![License: GPLv3](https://img.shields.io/github/license/ADBC123456/AlnPlay?style=flat)](LICENSE) [![Platform](https://img.shields.io/badge/platform-Android%20%7C%20iOS%20%7C%20iPad-blue)](https://github.com/ADBC123456/AlnPlay) [![Flutter](https://img.shields.io/badge/Flutter-3.44-46A6F2?logo=flutter&logoColor=white)](https://flutter.dev)

AlnPlay 使用 Flutter 构建，保留 Android 原生 Media3 播放路径与 iOS 原生播放路径。它适合整理本地视频、NAS/WebDAV 内容和家庭媒体库；具体格式、HDR 与音频能力取决于平台、设备硬件和文件封装。

## 当前版本

- 代码中的应用版本：`1.1.0+3`（见 `pubspec.yaml`）。
- 可安装构建与发布说明请以 [GitHub Releases](https://github.com/ADBC123456/AlnPlay/releases) 为准；代码版本号不等同于已发布版本。

## 主要功能

### 播放

- Android 使用 Media3/ExoPlayer 与原生 SurfaceView；适合 HDR/Dolby Vision 直通的设备路径。
- iPhone/iPad 使用 AetherEngine 与 AVPlayer 组合，支持常见 Apple 容器及 FFmpeg 覆盖的其他容器。
- 覆盖 MKV、MP4、MOV、TS、AVI、WebM 等常见容器；设备不支持的编码会正常报告失败。
- Android 音频路径包含 FFmpeg 扩展，可处理 DTS、DTS-HD、TrueHD、E-AC3、AC3、FLAC、AAC 等常见格式；是否能 bitstream/passthrough 由输出设备决定。
- Android 提供两种可选引擎：默认使用 Media3，也可主动选择“使用 MPV 播放”。MPV 为 SDR 播放路径，不自动切换，不能输出真正的 HDR/DV；iOS 不使用 MPV。
- 播放控制包括暂停、拖动、倍速、画面比例、章节、手势、触控锁、画中画和播放进度恢复。
- 支持选择音轨与字幕轨，支持结束后重播以及同目录下一集播放（按来源能力）。

### 媒体库

- 可添加本地文件夹、WebDAV、Jellyfin/Emby、FTP/SFTP、UPnP/DLNA 等来源；应用内 SMB/NAS 浏览限 Android。
- Android 支持应用内 SMB 浏览；iPad 的 SMB 内容可通过“文件”应用打开，应用内 WebDAV 与其他受支持来源仍可使用。
- 扫描深度可按媒体库设置，范围为 1–20 层，默认 6 层。
- 文件名与祖先目录都可参与影视识别；识别结果保存为本地媒体库索引。
- 影视详情页使用 TMDB 元数据，包括海报、背景、简介、评分、演员及剧集季集信息；需要可用的 TMDB API key，可在设置中填写。
- 继续观看、观看标记、播放进度和媒体来源稳定身份保存在本地。
- 可选连接 SIMKL 同步观看记录；未配置时不启用该同步。
- `.strm` 支持本地文件与 WebDAV 源：应用仅读取不超过 64 KiB 的文本并解析 HTTP(S) 地址，不提供云盘直连或云盘授权代理。
- WebDAV/SMB/FTP 目录中的可播放文件与相邻字幕可按来源能力浏览和播放；凭据保留在平台原生安全存储中。

### 字幕与弹幕

- 自动发现视频同目录的外置字幕，并与内嵌字幕一起在 CC 面板中选择。
- 支持 SRT、SSA/ASS、WebVTT、TTML、SAMI、MicroDVD、MPL2、SubViewer 等格式（具体渲染能力随平台而异）。
- 字幕提供大小、颜色、背景、描边、位置和同步延迟等设置；字幕会按视频显示区域定位。
- 可选 OpenSubtitles 搜索与下载，使用服务方账户/配额与 API key 规则。
- 弹幕采用可配置来源、匹配、缓存和时间轴渲染流程；支持单集匹配、整季处理及播放中的显示开关。弹幕源与可用内容取决于用户配置和服务端响应。

### 界面与系统集成

- 手机、平板、横屏与大字体布局适配；iPad 详情页支持全宽布局。
- 首页使用可拖动的液态玻璃风格 Dock；视觉效果会随平台渲染能力变化。
- 支持 Android TV/遥控器方向键的基础导航（以构建目标和设备为准）。
- 支持 iOS/iPadOS“文件”应用导入、Open with，以及 Android 外部 Intent 打开视频。
- 提供本地缓存上限：`1 GiB`、`2 GiB`、`5 GiB`、`10 GiB`、`50 GiB` 与“不限制”；默认 `5 GiB`。缓存清理不删除媒体库和观看记录。
- 缓存按最近使用时间淘汰，播放中的临时字幕会保留到播放器释放；上限不包含用户视频、STRM 原文件、持久字幕下载、应用本体或内存占用。界面中的 GB 按 1024³ 字节计算。
- 设置页可手动检查 GitHub 更新；默认启动后每日检查一次。更新检查固定读取公开仓库 `ADBC123456/AlnPlay` 的 latest release，不需要 GitHub token。
- 发现更新后显示版本、发布日期与更新说明，跳转发布页面下载；不在应用内自动安装，iOS 仍需侧载工具。

## 文件夹与 STRM 使用

命名优先使用明确的季集编号，也支持由目录补充剧名和季数：

```text
媒体库/
└── 凡人修仙传/
    └── 第二季/
        └── 高清/
            ├── 01.mkv
            └── 02.strm
```

在这个结构中，`01.mkv` 可结合祖先目录识别为第二季第一集。`凡人修仙传.S02E01.mkv` 这样的显式文件名优先级更高；人工修正和服务器已提供的匹配会被保留。无法确认的季集不强行归入特别篇。

根目录按第 0 层计算，默认最多深入 6 层；达到上限的目录内文件仍会读取，但不再进入更深目录。来源长按可调整扫描层级。扫描中断、超时或部分目录不可读时，不把旧索引中的文件直接当作已删除。

外部工具生成的 `.strm` 应为 UTF-8 小文件，只包含一个可播放的 HTTP(S) 地址，例如：

```text
https://media.example.com/videos/episode-02.mkv
```

支持 BOM、空行和注释；拒绝多目标、其他协议或嵌套 STRM。扫描阶段只读取不超过 64 KiB 的指针文本与目录信息，不读取其指向的视频流。播放时重新读取目标，观看进度绑定原 STRM，不在历史记录中保存临时签名地址。

STRM 能减少扫描视频流的请求，但不能保证第三方网盘不会限流或风控。请使用有权访问的来源，并遵守服务方规则。

## 不包含的功能

- 本项目当前不提供百度网盘、阿里云盘或夸克网盘的官方直连授权与播放时解析。
- `.strm` 只支持 HTTP(S) target；不会请求嵌套 STRM，也不会把源 WebDAV 凭据发送给 target。
- 不把“支持某格式”理解为所有设备都能硬解；HDR/DV、音频 passthrough、容器和字幕能力始终受设备与系统限制。

## 截图

以下为仓库已有界面截图，可能与当前开发版本的 Dock 和布局不同。

<p align="center">
  <img src="screenshots/home.jpg" width="220" alt="首页">
  <img src="screenshots/movie_detail.jpg" width="220" alt="影视详情">
  <img src="screenshots/menu.jpg" width="220" alt="添加内容菜单">
  <img src="screenshots/settings.jpg" width="220" alt="设置">
</p>

## 下载与安装

请从 [Releases](https://github.com/ADBC123456/AlnPlay/releases) 下载构建产物。

- Android：APK 构建，安装前请确认 ABI 与设备兼容。
- iOS/iPadOS：提供未签名 IPA；可使用 [SideStore](https://sidestore.io) 或 [AltStore](https://altstore.io) 进行侧载。签名有效期由侧载工具和账户类型决定。

## 平台要求

| 平台 | 项目配置 |
| --- | --- |
| Android | 当前 Flutter 3.44.7 构建最低 Android 7.0（API 24）；项目使用 `flutter.minSdkVersion` |
| iOS / iPadOS | iOS 17.0 或更高 |

## 技术栈

- Flutter 3.44.x：应用界面、媒体库、设置和跨平台业务逻辑。
- Android Media3/ExoPlayer：原生视频 Surface、硬件解码、HDR/DV 路径及 FFmpeg 音频扩展。
- iOS AetherEngine + AVPlayer：原生播放、FFmpeg 容器/音频覆盖和系统显示路径。
- jcifs-ng：Android SMB 2/3；Citadel/SwiftNIO：iOS SFTP；WebDAV 使用平台原生网络层与 Range 读取。
- TMDB：影视元数据；OpenSubtitles：可选字幕搜索/下载；弹幕服务由用户配置来源提供。
- Flutter MethodChannel/PlatformView：连接原生播放、文件、网络来源与系统集成。

## 数据与隐私边界

- 媒体库索引、观看进度、设置和缓存默认保存在设备本地。
- 浏览、媒体库刷新、刮削和播放会访问已配置的网络来源；账号密码由平台安全存储管理。
- TMDB、OpenSubtitles、弹幕来源、已启用的 SIMKL 同步和 GitHub 更新检查会按对应功能访问第三方服务。
- AlnPlay 不运营网盘内容，也不代替用户取得第三方媒体的访问授权。

## 开发

需要 Flutter stable 3.44.x、Android SDK，以及 iOS 构建所需的 Xcode（仅 macOS）。

```bash
flutter pub get
flutter run
flutter analyze
flutter test
```

TMDB key 可写入 `.env`（参考 `.env.example`）：

```bash
flutter run --dart-define-from-file=.env
```

Android 构建：

```bash
flutter build apk
```

iOS 构建需在 macOS/Xcode 环境执行：

```bash
flutter build ios --no-codesign
```

## 许可

本项目按 [GNU General Public License v3.0](LICENSE) 发布。第三方依赖仍受其各自许可证约束；归属与原项目版权声明见 [NOTICE](NOTICE)。
