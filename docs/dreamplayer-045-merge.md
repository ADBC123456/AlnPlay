# DreamPlayer 0.4.5 功能合并记录

2026-09-18。对照 `E:/woker/DreamPlayer` 的 0.4.5 发布说明与实现代码，逐项判断
哪些适合合并进 AlnPlay；不复制会与现有媒体库冲突的做法。

## 结论速览

| 0.4.5 内容 | 决策 | 落点 |
| --- | --- | --- |
| TMDB 图片永久离线缓存 | 移植并改造 | `lib/services/image_cache_service.dart`、`lib/widgets/cached_image.dart` |
| 设置内查看/清理图片缓存 | 移植 | 设置 → 存储 |
| 详情页可折叠背景大图 | 移植 | `lib/screens/unified_title_details_screen.dart` |
| 设置分组可折叠 | 移植 | `lib/screens/settings_screen.dart` |
| 完善各网络来源的 TMDB 识别 | 部分移植 | `lib/services/tmdb_client.dart`、`lib/library/metadata/library_metadata_resolver.dart` |
| SMB 收藏目录自动展开 | 换实现 | `lib/screens/home_screen.dart` + `lib/library/unified_library_service.dart` |
| 一键清空媒体库 / 继续观看 | 移植并加竞态保护 | 首页「媒体库操作」、`UnifiedLibraryService.clearLibrary()` |
| SDR 被误判为 HDR 的修复 | 移植 | `HdrStaticMetadata.kt` + `lib/…/ExoPlayerView.kt` |
| iOS 内购入口（构建开关控制） | 不合并 | 商业决定，AlnPlay 无内购 |
| GitHub 发布仅产出 Android APK | 合并 | `.github/workflows/release.yml` |

## 逐项说明

### 1. TMDB 图片永久离线缓存（移植，改造后接入）

上游把海报、背景图、单集截图、演员照片落到磁盘供离线重启使用，但实现有两个
问题：内存中的字节没有上限；点「清理缓存」后仍在进行的下载会把文件写回来。

AlnPlay 的实现：

- 只接管 `image.tmdb.org/t/p/…` 形态的 URL（`_uri` 校验 scheme、host、
  路径模板，拒绝带 query/fragment/userinfo），其余图片（例如 Jellyfin 带
  token 的地址）继续走原有加载器，凭据不会落盘。
- 字节只存磁盘，界面用 `Image.file` 渲染，Dart 侧不常驻大图；单张上限 12 MiB，
  同时下载最多 3 个，相同 URL 的并发请求共用同一个 future。
- `_revision` 版本号：`clear()` 之后，清理前发起的下载即使返回也不会写入。
- 同一张图的不同尺寸共用一个目录：在线时仍按界面请求的尺寸下载（不会用
  小图顶替大图），只有下载失败（离线）才回退到已缓存的尺寸，并优先选最大
  的那张。
- 元数据落库时按需预取（海报、背景图、演员、单集截图），队列上限 256，失败
  不影响显示。

替换范围：卡片、详情页和各来源浏览器的 `Image.network` → `CachedImage`
（13 个文件、28 处）。临时缓存配额（`CacheQuotaManager`）保持不变，两者互不
管理对方。

### 2. 设置内查看/清理图片缓存（移植）

设置 → 存储 增加一行「离线图片缓存」：显示占用字节、标注「长期保留，可手动
清理」，点击后弹确认框再删除。原有的缓存配额行说明改为「限制临时文件与弹幕；
离线图片缓存单独管理」，避免用户以为清理配额会连海报一起删掉。

### 3. 详情页可折叠背景大图（移植）

统一详情页改用 `SliverAppBar` + `FlexibleSpaceBar`：滚动过背景图后顶栏出现
标题与返回按钮（`_pastHero`，阈值 `heroHeight - 72`），横屏下背景图按 16:9
居中、不再被拉满。短内容页（一集、无演职员数据）不会滚动到阈值，此时背景图
自带返回箭头，导航不会丢失。

### 4. 设置分组可折叠（移植）

`_settingsGroups` 把每个 `_SettingsHeading` 到下一个标题之间的条目收进一个
`ExpansionTile`，用 `PageStorageKey` 记住展开状态、默认展开。没有标题的条目
保持在原位。

### 5. 各网络来源的 TMDB 识别（部分移植）

只移植有明确证据的规则，不照搬上游「按名称前缀强行合并剧集」一类会误判的做法：

- **电影续集**：`Part 2` / `Vol 3` / `第X部` 等不再被祖先目录推断成集号，
  搜索时也把 TV 的微弱加权去掉、改为电影的加权（`hasMovieSequelPattern`）。
- **真人版**：`Live Action` / `J Drama` / `真人版` 从搜索词中剔除并记录标记；
  候选若来自动画类型（TMDB genre 16）则降权，动画版本优先。
- **篇章季**：`TmdDetails.seasonNames` + `seasonForFolder`，只有官方季名与
  目录名规范化后完全相等、且唯一匹配时才认定季号；认不出就保持未知，不会
  把外传塞进最后一季。
- 文件夹解析改为传入原始目录名后统一解析一次，避免「先取标题再解析」丢掉
  年份/季信息；已缓存的季数据为空时会重新拉取。

### 6. SMB 收藏目录自动展开（换实现）

上游把一次收藏拆成多个「子目录收藏」。AlnPlay 的媒体库本来就跨来源递归扫描
并按 `stableId` 去重、按 `maxScanDepth` 限深，拆开收藏会重复扫描同一批文件。

改为：新增收藏后立即把它送进现有扫描队列（首页监听 `LibraryFoldersStore.changes`
拿到差集，调用 `UnifiedLibraryService.refresh(added)`），子目录与文件自动进入
媒体库；来源离线时收藏照常保留，等用户手动重试。

### 7. 清空媒体库 / 清空继续观看（移植，加竞态保护）

首页顶栏「媒体库操作」菜单：两项都先弹确认框，取消不动数据。

- `UnifiedLibraryService.clearLibrary()`：先自增 `_revision` 并清空排队中的
  收藏，让旧扫描的结果失效；`cancelAll()` 停掉正在跑的扫描；等在途刷新结束
  后再清索引。随后删除收藏目录、索引（含恢复用的 `.bak` 与分片文件）、每个
  收藏的 TMDB 缓存与扫描时间戳，最后重置内存快照并通知界面。
- 只删媒体库，不动视频文件、服务器配置和观看记录（确认框里写明）。
- `LibraryFoldersStore.clearAll()` 与 `ContinueWatchingStore.clearAll()` 都
  进入各自的写队列，不会和并发写入互相覆盖。

### 8. SDR 误判 HDR 的修复（移植）

上游只检查亮度数值。AlnPlay 把校验抽到 `HdrStaticMetadata` 并补齐两点：

- HEVC SEI 的长度字段按 RBSP 计算，先做防竞争字节（`00 00 03`）还原，遇到
  非法转义直接判定无效；
- 类型 137 要求负载 24 字节且最大/最小亮度落在合理区间，类型 144 要求 4 字节
  且最大 CLL 在 10–10000 之间，两项都不再只凭「出现过该类型」就算 HDR。

### 9. iOS 内购入口（不合并）

AlnPlay 目前没有内购，也不打算在本次功能合并里引入商业入口，因此不移植。
上游「发布流程只产出 Android APK」这一条与本项目发布策略一致，已合并：
`.github/workflows/release.yml` 删除 iOS job，iOS 构建继续走
`.github/workflows/ios.yml`（手动、可选签名）。

## 验证

- `dart analyze lib test`：无问题。
- `flutter test`：全量通过（含本次新增的 `image_cache_service_test`、
  `tmdb_045_test`、`library_actions_test`、`library_clear_test`、
  `library_bookmark_scan_test`、详情页收起测试，以及扫描器/仓库/继续观看的
  竞态回归）。其中 `library_bookmark_scan_test` 用真实扫描链路验证「新增收藏
  → 目录内文件进入媒体库并标记扫描完成」。
- Android 侧 `HdrStaticMetadata` 用 Kotlin 直接编译运行：
  `tool/hdr-static-metadata-test.sh`（源码 `test/kotlin/HdrStaticMetadataTest.kt`），
  9 项校验通过（含伪造 SEI、越界亮度、防竞争字节三类反例）。
- 未做：真机长时间缓存占用、iOS 端离线重启的实际观感（需要设备验证）。
