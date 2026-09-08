# 播放器响应与弹幕入口调整

日期：2026-09-07

## 播放器

- `lib/widgets/player_gesture_surface.dart`：首次点击抬手立即响应；自行识别邻近双击，不等待 Flutter 双击超时再叠加旧的 260 ms 定时器。长按、取消触摸、第二指加入及滑动竞争统一处理。
- `lib/screens/player_screen.dart`：原生视频 widget 缓存；进度和缓冲只更新时间轴，控制栏隐藏时不刷新进度 UI；慢速滑动累积位移。长按临时 2×，松手、后台、PiP、结束或锁定恢复用户原速；弹幕时钟同步倍速，不覆盖持久化速度。
- `android/app/src/main/kotlin/com/dreamplayer/app/ExoPlayerView.kt`：进度 tick 复用最近完整元数据快照，减少音轨枚举、HDR 设置和空间音频查询；速度变化立即同步系统媒体会话。按视频帧率整数倍选择刷新率，手机优先高刷新率，电视优先较低的匹配刷新率。
- `android/app/src/main/kotlin/com/dreamplayer/app/PlaybackManager.kt`：前台服务按生命周期启动，元数据仅变化时提交；系统进度更新限制为 1 Hz，播放、暂停和 seek 立即同步。
- 保留 Media3 硬件解码和 hybrid composition 原生 SurfaceView，未降低视频分辨率、码率或改变 HDR/DV 输出路径。

验证：PJD110 Android 手机原来是 Debug 包；构建并安装 Release。播放《牧神记》时查到 120 Hz，视频仍由 `c2.qti.avc.decoder` 输出 3840×2160，采样 `discardFps=0`。实际速度核对 `1.5 → 2.0 → 1.5`。本次使用的片源是 SDR，未另行重测 HDR/DV 片源。60 Hz 与 120 Hz 的系统 jank 阈值不同，未将两次 gfxinfo 数字当作可直接比较的性能提升比例。

自动测试：播放器阶段完整套件 471 项通过；最终播放器手势与 UI 回归 18 项通过；相关 Dart 静态分析无问题。

## 本集与整季弹幕入口

- `lib/screens/unified_title_details_screen.dart`：点击“匹配本集弹幕”只传当前集的所有来源版本，设置 `matchSingleEpisode: true`，不再传入整个季。
- `lib/screens/danmaku_scrape_screen.dart`：本集入口准备后直接打开系列选择，再将当前集放在远程集列表最前，用户点选具体集完成绑定；同集来源版本共享选择。
- 整季入口选中系列后使用首个非预告、有效编号的远程集为季起点，直接保存绑定并开始缓存；不再使用续播集作为起点，不再要求另选起始集或进行批量确认。文件按季、集排序后依次处理；缺失的本地集不压缩编号。
- 仍过滤预告条目；未映射/重复条目保留失败状态供手动修正；可取消、重试，已有有效缓存继续复用。
- `test/danmaku_scrape_screen_test.dart`：本集直接选系列并定位第 45 集、排除预告；整季续播第 45 集仍按第 1 集、第 45 集顺序缓存，且无需额外确认。
- `lib/danmaku/binding/danmaku_binding_store.dart`：仅供 widget 测试重置异步写队列，避免上一测试 FakeAsync zone 的 Future 影响下一测试；生产流程不调用。

交付方式：用户要求直接安装到已连接的 PJD110，自行测试；不在设备上代为确认弹幕绑定或发起整季网络刮削。

本轮检查：弹幕刮削、绑定存储、入口流程与播放器手势共 34 项相关测试通过；8 个相关 Dart 文件静态分析无问题。
