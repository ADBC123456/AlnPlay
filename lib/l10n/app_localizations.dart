import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide language state. Chinese is the product default; users may opt in
/// to English and the choice survives restarts.
class AppLocaleController extends ChangeNotifier {
  AppLocaleController._();

  static final AppLocaleController instance = AppLocaleController._();
  static const String preferenceKey = 'dreamplayer.appLanguage';

  Locale _locale = const Locale('zh');

  Locale get locale => _locale;
  bool get isChinese => _locale.languageCode == 'zh';

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(preferenceKey);
    _locale = Locale(saved == 'en' ? 'en' : 'zh');
  }

  Future<void> setLanguage(String languageCode) async {
    final normalized = languageCode == 'en' ? 'en' : 'zh';
    if (_locale.languageCode == normalized) return;
    _locale = Locale(normalized);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(preferenceKey, normalized);
    notifyListeners();
  }

  static Future<String> savedLanguageCode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(preferenceKey) == 'en' ? 'en' : 'zh';
  }
}

/// Lightweight localization facade used while migrating the existing UI.
/// Unknown strings are deliberately preserved: media titles, paths and server
/// content must never be machine-translated.
class AppLocalizations {
  const AppLocalizations(this.locale);

  final Locale locale;

  static AppLocalizations of(BuildContext context) =>
      AppLocalizations(Localizations.localeOf(context));

  bool get isChinese => locale.languageCode == 'zh';

  String tr(String source) {
    if (!isChinese || source.isEmpty) return source;
    final exact = _zh[source];
    if (exact != null) return exact;
    return _translateDynamic(source);
  }

  String _translateDynamic(String source) {
    final patterns = <(RegExp, String Function(Match))>[
      (RegExp(r'^(\d+) folder levels$'), (m) => '${m[1]} 层子文件夹'),
      (RegExp(r'^Removed (.+)$'), (m) => '已移除 ${m[1]}'),
      (RegExp(r'^Signed in to (.+)$'), (m) => '已登录 ${m[1]}'),
      (RegExp(r'^"(.+)" added to your library$'), (m) => '“${m[1]}”已添加到媒体库'),
      (
        RegExp(r'^"(.+)" will no longer appear here\.$'),
        (m) => '“${m[1]}”将不再显示在这里。',
      ),
      (
        RegExp(
          r'^"(.+)" will no longer appear here\. You can add it again anytime\.$',
        ),
        (m) => '“${m[1]}”将不再显示在这里，你可以随时重新添加。',
      ),
      (
        RegExp(
          r'^"(.+)" will no longer appear here\. The files stay on your device\.$',
        ),
        (m) => '“${m[1]}”将不再显示在这里，设备上的文件不会被删除。',
      ),
      (
        RegExp(r'^Bookmarked (.+) to Home \((.+)\)$'),
        (m) => '已将 ${m[1]} 收藏到首页（${m[2]}）',
      ),
      (RegExp(r'^(.+) added to your library$'), (m) => '${m[1]} 已添加到媒体库'),
      (RegExp(r'^Continue from (.+)$'), (m) => '从 ${m[1]} 继续'),
      (RegExp(r'^(.+) · Continue from (.+)$'), (m) => '${m[1]} · 从 ${m[2]} 继续'),
      (RegExp(r'^Resume from (.+)$'), (m) => '从 ${m[1]} 继续播放'),
      (RegExp(r'^(\d+) comments$'), (m) => '${m[1]} 条弹幕'),
      (RegExp(r'^(\d+) chapters$'), (m) => '${m[1]} 个章节'),
      (RegExp(r'^(\d+) episodes$'), (m) => '${m[1]} 集'),
      (
        RegExp(r'^Saved (\d+) / (\d+) episode bindings$'),
        (m) => '已保存 ${m[1]} / ${m[2]} 个剧集匹配',
      ),
      (RegExp(r'^Episode (\d+)$'), (m) => '第 ${m[1]} 集'),
      (RegExp(r'^Local episode (\d+)$'), (m) => '本地第 ${m[1]} 集'),
      (RegExp(r'^Remote episode (\d+)$'), (m) => '远程第 ${m[1]} 集'),
      (RegExp(r'^Select danmaku series · (.+)$'), (m) => '选择弹幕系列 · ${m[1]}'),
      (RegExp(r'^Manual match · (.+)$'), (m) => '手动匹配 · ${m[1]}'),
      (RegExp(r'^(\d+) min$'), (m) => '${m[1]} 分钟'),
      (RegExp(r'^Chapters \((\d+)\)$'), (m) => '章节（${m[1]}）'),
      (
        RegExp(r'^(\d+) downloads'),
        (m) => '${m[1]} 次下载${source.substring(m.end)}',
      ),
      (RegExp(r'^Error: (.+)$'), (m) => '错误：${m[1]}'),
      (RegExp(r'^Auto-fetched: (.+)$'), (m) => '已自动获取：${m[1]}'),
      (
        RegExp(r'^Synced (\d+) item\(s\) to SIMKL$'),
        (m) => '已同步 ${m[1]} 项到 SIMKL',
      ),
      (
        RegExp(r'^Removes (.+) of cached images and temporary files\..+$'),
        (m) => '将清除 ${m[1]} 的缓存图片和临时文件。下次打开时可能需要重新联网加载海报和详情。',
      ),
      (RegExp(r'^Could not (.+)$'), (m) => '无法${m[1]}'),
      (RegExp(r'^(\d+)m ago$'), (m) => '${m[1]} 分钟前'),
      (RegExp(r'^(\d+)h ago$'), (m) => '${m[1]} 小时前'),
      (RegExp(r'^(\d+)d ago$'), (m) => '${m[1]} 天前'),
    ];
    for (final entry in patterns) {
      final match = entry.$1.firstMatch(source);
      if (match != null) return entry.$2(match);
    }
    return source;
  }

  static const Map<String, String> _zh = {
    'Offline artwork': '离线图片缓存',
    'Kept until manually cleared': '长期保留，可手动清理',
    'Clear offline artwork?': '清除离线图片缓存？',
    'Posters, backdrops, episode stills and cast photos will need to be downloaded again. Your library and videos are kept.':
        '海报、背景图、单集截图和演员照片需要重新下载。媒体库与视频文件会保留。',
    'Limits temporary files and danmaku; offline artwork is managed separately.':
        '限制临时文件与弹幕缓存；离线图片缓存单独管理。',
    'Library actions': '媒体库操作',
    'Clear library': '清空媒体库',
    'Clear library?': '清空媒体库？',
    'Clear continue watching': '清空继续观看',
    'Clear continue watching?': '清空继续观看？',
    'Removes library folders and the media index. Your video files, saved servers and watch history are kept.':
        '移除媒体库收藏目录和影片索引。保留视频文件、服务器配置与观看记录。',
    'Removes all entries from continue watching. Saved playback positions and watched marks are kept.':
        '移除继续观看列表中的全部条目。保留播放进度和已看标记。',
    'Could not clear library data.': '清空失败，请重试。',
    'Scan depth': '扫描层级',
    'Library scan settings': '媒体库扫描设置',
    'This STRM file could not be read': '无法读取此 STRM 文件，请检查文件内容与来源连接。',
    'STRM files are not supported from this network source':
        '此网络来源暂不支持 STRM，请使用本地文件夹或 WebDAV。',
    'Maximum folder levels below each library root': '每个媒体库根目录下最多扫描的文件夹层级',
    'Check for updates': '检查更新',
    'GitHub rate limit reached. Please try again later.': 'GitHub 请求已限流，请稍后再试。',
    'No public release is available yet.': '尚未找到公开发布的正式版本。',
    'The installed version or release information could not be verified.':
        '无法确认当前版本或发布信息，请稍后重试。',
    'GitHub release': 'GitHub 正式版本',
    'Installed version': '当前版本',
    'New version available': '发现新版本',
    'Published': '发布日期',
    'A new version is ready.': '新版本已发布。',
    'Download the IPA from the release page.': '请在发布页面下载 IPA，并使用现有侧载工具安装更新。',
    'Later': '稍后',
    'View release': '查看更新',
    'You are using the latest version.': '当前已是最新版本。',
    'Could not check for updates.': '无法检查更新，请稍后重试。',
    'Cache limit': '缓存上限',
    'Unlimited': '不限制',
    'Could not change cache limit.': '无法修改缓存上限。',
    'Could not clear cache.': '无法清理缓存，请稍后重试。',
    'Active playback files will be cleared after playback.':
        '播放中使用的缓存将在播放结束后继续清理。',
    'Limits temporary files, images and danmaku; keeps your library and watch history.':
        '限制临时文件、图片和弹幕缓存，保留媒体库与观看记录。',
    'Library': '媒体库',
    'Source library': '资源库',
    'My': '我的',
    'Recently watched': '最近观看',
    'Movies': '电影',
    'Anime': '动漫',
    'TV shows': '电视剧',
    'Sort': '排序',
    'Recently added': '最近入库',
    'Search titles, episodes or files': '搜索影片、剧集或文件',
    'No matching titles': '没有匹配的影片',
    'No titles yet': '暂无影片',
    'Saved servers': '已保存的服务器',
    'No saved servers': '暂无已保存的服务器',
    'Tap + to add a source.': '点击 + 添加来源。',
    'Could not refresh library. Please try again.': '无法刷新媒体库，请重试。',
    'Could not open video. Check the source and try again.': '无法打开视频，请检查来源后重试。',
    'Settings': '设置',
    'Storage': '存储',
    'Audio': '音频',
    'Player': '播放器',
    'Format': '格式',
    'Playback': '播放',
    'Metadata': '媒体信息',
    'Subtitles': '字幕',
    'General': '常规',
    'Sources': '弹幕源',
    'Appearance': '外观',
    'Theme': '主题',
    'Follow system': '跟随系统',
    'Light': '浅色',
    'Dark': '深色',
    'Could not save theme preference': '无法保存主题设置',
    'Cancel': '取消',
    'Save': '保存',
    'Delete': '删除',
    'Remove': '移除',
    'Edit': '编辑',
    'Retry': '重试',
    'Clear': '清除',
    'Reset': '重置',
    'Search': '搜索',
    'Play': '播放',
    'Pause': '暂停',
    'Off': '关闭',
    'On': '开启',
    'Back': '返回',
    'Close': '关闭',
    'Done': '完成',
    'Add': '添加',
    'Test': '测试',
    'Language': '语言',
    'Chinese': '中文',
    'English': 'English',
    'Chinese interface and TMDB metadata': '中文界面和 TMDB 中文元数据',
    'English interface and TMDB metadata': '英文界面和 TMDB 英文元数据',
    'Clear cache': '清除缓存',
    'Clear cache?': '清除缓存？',
    'Cache cleared': '缓存已清除',
    'Cached images and temporary files cleared': '缓存图片和临时文件已清除',
    'Press back again to exit': '再按一次返回键退出',
    'No folders yet. Tap + to add one.': '还没有媒体文件夹，点击 + 添加。',
    'Continue watching': '继续观看',
    'Add a source': '添加来源',
    'Add folder to library': '添加文件夹到媒体库',
    'Browse files on this device': '浏览此设备上的文件',
    'Internal storage': '内部存储',
    'Network shares': '网络共享',
    'SMB / NAS shares': 'SMB / NAS 共享',
    'SMB via the Files app': '通过“文件”应用使用 SMB',
    'Add a WebDAV server': '添加 WebDAV 服务器',
    'FTP or SFTP file server': 'FTP 或 SFTP 文件服务器',
    'Jellyfin / Emby media server': 'Jellyfin / Emby 媒体服务器',
    'DLNA / UPnP servers on this network': '局域网内的 DLNA / UPnP 服务器',
    'Play URL': '播放网址',
    'Stream a direct video link': '播放视频直链',
    'Enter a valid http(s) URL': '请输入有效的 HTTP(S) 地址',
    'Remove from library?': '从媒体库移除？',
    'Remove from Continue watching?': '从“继续观看”移除？',
    'No videos or folders here': '这里没有视频或文件夹',
    'Grant access': '授予访问权限',
    'Audio passthrough': '音频直通',
    'Off — decode to PCM (default)': '关闭——解码为 PCM（默认）',
    'Auto — passthrough when HDMI detected': '自动——检测到 HDMI 时启用直通',
    'Swipe gestures': '滑动手势',
    'Swipe left side for brightness, right side for volume':
        '左侧滑动调节亮度，右侧滑动调节音量',
    'Picture-in-picture': '画中画',
    'Keep playing in a floating window when you leave the app':
        '离开应用后在悬浮窗口中继续播放',
    'Auto-play next episode': '自动播放下一集',
    'Play the next episode when one ends': '本集结束后自动播放下一集',
    'On-screen badges': '屏幕信息标签',
    'Show format chips on screen while playing': '播放时显示格式标签',
    'Audio codec': '音频编码',
    'Video codec': '视频编码',
    'Resolution': '分辨率',
    'Spatial audio': '空间音频',
    'Server transcoding': '服务器转码',
    'Decoder': '解码器',
    'Volume Boost': '音量增强',
    'Night Mode': '夜间模式',
    'Compress dynamic range for quiet listening': '压缩动态范围，适合安静环境',
    'Video decoder': '视频解码器',
    'Auto — hardware when available': '自动——优先使用硬件解码',
    'Danmaku': '弹幕',
    'Danmaku settings': '弹幕设置',
    'Select episode': '选集',
    'Next episode': '下一集',
    'No next episode': '已经是最后一集',
    'Unable to load episodes': '无法加载剧集列表',
    'No episodes available': '暂无可播放剧集',
    'Speed': '倍速',
    'Sources, filters and appearance': '弹幕源、过滤与外观',
    'Show danmaku': '显示弹幕',
    'Hide danmaku': '隐藏弹幕',
    'Global switch for bullet comments': '弹幕全局开关',
    'No danmaku sources': '没有弹幕源',
    'Add a danmu_api deployment to get started': '添加一个 danmu_api 服务以开始使用',
    'Add source': '添加弹幕源',
    'Edit danmaku source': '编辑弹幕源',
    'Add danmaku source': '添加弹幕源',
    'Delete danmaku source?': '删除弹幕源？',
    'Scrolling comments': '滚动弹幕',
    'Top comments': '顶部弹幕',
    'Bottom comments': '底部弹幕',
    'Blocked words': '屏蔽词',
    'Clear danmaku cache': '清除弹幕缓存',
    'Clear danmaku cache?': '清除弹幕缓存？',
    'Danmaku cache cleared': '弹幕缓存已清除',
    'Test connection': '测试连接',
    'Connection successful': '连接成功',
    'Name': '名称',
    'Base URL': '服务地址',
    'Token (optional)': 'Token（可选）',
    'Font size': '字号',
    'Opacity': '不透明度',
    'Display area': '显示区域',
    'Scroll speed': '滚动速度',
    'Show more': '显示更多',
    'Show less': '收起',
    'Danmaku type': '弹幕类型',
    'Top': '顶部',
    'Bottom': '底部',
    'Scrolling': '滚动',
    'Loading comments...': '正在加载弹幕…',
    'Matched, but no comments': '已匹配，但没有弹幕',
    'No matching episode': '没有匹配的剧集',
    'Load failed': '加载失败',
    'No source configured': '未配置弹幕源',
    'Reload danmaku': '重新加载弹幕',
    'Add and enable a danmaku source in Settings first.': '请先在设置中添加并启用弹幕源。',
    'Scrape series danmaku': '刮削整季弹幕',
    'Match current episode danmaku': '匹配本集弹幕',
    'Pre-cache current episode': '缓存本集弹幕',
    'Cancel scraping': '取消刮削',
    'Retry failed': '重试失败项',
    'Force re-scrape': '强制重新刮削',
    'Pre-cache whole season': '预缓存整季弹幕',
    'This saves the bindings only. Comments load when an episode plays.':
        '这里只保存匹配关系，播放对应剧集时才加载弹幕。',
    'Select series and batch match': '选择系列并批量匹配',
    'Select first remote episode': '选择首集对应的远程弹幕',
    'Select exact danmaku episode': '选择具体弹幕剧集',
    'Search episode number or title': '搜索集号或标题',
    'Remote episode has no index': '该远程剧集没有可用集号',
    'Unmatched or duplicate candidates need manual matching. Select a remote series for batch matching, or tap an episode to change its source.':
        '未匹配或重复的候选项需要手动处理。请选择远程系列进行批量匹配，或点击单集修改弹幕来源。',
    'Batch match current season?': '批量匹配当前季？',
    'Match all': '匹配全部',
    'No danmaku series candidates found': '没有找到弹幕系列候选',
    'No matching remote episode found': '没有找到对应的远程剧集',
    'Configure source': '配置弹幕源',
    'TMDB API key': 'TMDB API 密钥',
    'Get Info': '获取媒体信息',
    'Find on TMDB': '在 TMDB 中查找',
    'Fix match': '修正匹配',
    'Remove info': '移除媒体信息',
    'TV Series': '电视剧',
    'Movie': '电影',
    'No results. Try a different title.': '没有结果，请尝试其他片名。',
    'Watch from beginning': '从头播放',
    'Watch from beginning (MPV)': '使用 MPV 从头播放',
    'Play with MPV': '使用 MPV 播放',
    'Try with MPV': '尝试使用 MPV',
    'SDR only — no Dolby Vision / HDR (Media3 handles those)':
        '仅支持 SDR——杜比视界 / HDR 请使用 Media3',
    'Search subtitles online': '在线搜索字幕',
    'Download language': '下载语言',
    'Subtitle reading language': '字幕识别语言',
    'Subtitle download language': '字幕下载语言',
    'Subtitle encoding': '字幕编码',
    'Auto (Default)': '自动（默认）',
    'Auto-fetch subtitles': '自动获取字幕',
    'Download best match when no subtitles found': '没有字幕时下载最佳匹配',
    'Search OpenSubtitles': '搜索 OpenSubtitles',
    'Downloading…': '正在下载…',
    'Computing file hash…': '正在计算文件哈希…',
    'Hash match enabled': '已启用哈希匹配',
    'Sign in': '登录',
    'Sign out': '退出登录',
    'Username': '用户名',
    'Password': '密码',
    'Self-signed certificate': '自签名证书',
    'Trust this server even when its TLS certificate is not publicly valid':
        '即使 TLS 证书未受公共机构信任，也信任此服务器',
    'Scan local network': '扫描局域网',
    'Scanning…': '正在扫描…',
    'No DLNA servers found': '未发现 DLNA 服务器',
    'Discover again': '重新发现',
    'Diagnostics': '诊断信息',
    'Nothing here': '这里没有内容',
    'No audio tracks found': '未找到音轨',
    'Audio tracks': '音轨',
    'Subtitle tracks': '字幕轨道',
    'Playback speed': '播放速度',
    '2× speed · Release to restore': '2× 倍速播放 · 松手恢复',
    'Sleep timer': '睡眠定时器',
    'Sleep timer finished — playback paused': '睡眠定时结束——播放已暂停',
    'Chapters': '章节',
    'Fit': '画面适配',
    'Repeat': '循环播放',
    'Shuffle': '随机播放',
    'Black outline': '黑色描边',
    'Shadow behind glyphs for readability': '在文字后添加阴影以提高可读性',
    'optional': '可选',
    'Your library': '你的媒体库',
    'Episodes': '剧集',
    'Overview': '简介',
    'Episode overview': '剧集简介',
    'Trailers': '预告片',
    'Stills': '剧照',
    'File info': '文件信息',
    'Video info': '视频信息',
    'Aspect ratio': '画面比例',
    'Engine': '播放引擎',
    'Downloaded': '已下载',
    'Videos you play will appear here.': '播放过的视频会显示在这里。',
    'All files access is needed to browse your storage': '需要“所有文件访问权限”才能浏览存储空间',
    'Browse device storage…': '浏览设备存储…',
    'Audio delay': '音频延迟',
    'Bass Boost': '低音增强',
    'Auto-play next': '自动播放下一项',
    'End of current video': '当前视频结束后',
    'Reopens at same position to switch decoder.': '将在相同位置重新打开以切换解码器。',
    'Takes effect on next video': '下个视频开始生效',
    'One word or phrase per line': '每行一个词或短语',
    'All downloaded comments will be removed. Source settings are kept.':
        '将删除所有已下载弹幕，并保留弹幕源设置。',
    'Downloaded comments will be fetched again when needed': '需要时会重新获取已下载弹幕',
    'Name is required': '名称不能为空',
    'Unmatched or duplicate candidates need manual matching.':
        '未匹配或重复候选项需要手动匹配。',
    'API key (v3 auth)': 'API 密钥（v3 认证）',
    '32-character hex string': '32 位十六进制字符串',
    'Get a free key at themoviedb.org/settings/api':
        '前往 themoviedb.org/settings/api 免费获取密钥',
    'No metadata loaded': '尚未加载媒体信息',
    'Search title': '搜索片名',
    'Search online subtitles…': '在线搜索字幕…',
    'Movie / episode name': '电影 / 剧集名称',
    'No subtitles found in this video': '此视频中没有字幕',
    'Load subtitle file…': '加载字幕文件…',
    'OpenSubtitles sign in': '登录 OpenSubtitles',
    'Sign in to OpenSubtitles': '登录 OpenSubtitles',
    'Anonymous = 5/day, free account = 20/day': '匿名用户每天 5 次，免费账户每天 20 次',
    'Trust HTTPS servers without a CA certificate': '信任没有 CA 证书的 HTTPS 服务器',
    'Guest — no username/password': '访客——无需用户名和密码',
    'Playback settings': '播放设置',
    'Repeat & shuffle': '循环与随机播放',
    'Random order inside the folder': '在文件夹内随机播放',
    'A-B repeat': 'A-B 段落循环',
    'Set A to current position': '将当前位置设为 A 点',
    'Set B to current position': '将当前位置设为 B 点',
    'Subtitle settings': '字幕设置',
    'Subtitle delay': '字幕延迟',
    'Size, color, background, delay': '大小、颜色、背景和延迟',
    'Sample subtitle line': '字幕示例文字',
    'Move subtitle text up (higher) or down (lower).': '向上或向下调整字幕位置。',
    'Video URL': '视频网址',
    'Remove folder?': '移除文件夹？',
    'The folder picker timed out. Please try again.': '文件夹选择器超时，请重试。',
    'Scanning your network…': '正在扫描局域网…',
    'Search failed. Try again in a moment.': '搜索失败，请稍后重试。',
    'Search is unavailable right now. Try again in a moment.': '搜索暂不可用，请稍后重试。',
    'Connect SIMKL': '连接 SIMKL',
    'Disconnect SIMKL': '断开 SIMKL',
    'Sync now': '立即同步',
    'Sign in to SIMKL first': '请先登录 SIMKL',
    'Sign out and stop syncing': '退出登录并停止同步',
    'SIMKL not configured': '尚未配置 SIMKL',
    'Sync watched history with simkl.com (free unlimited)':
        '与 simkl.com 同步观看历史（免费且不限量）',
    'Go to the address below and enter this code:': '请访问下方地址并输入此代码：',
    'Up': '返回上一级',
    'Server list': '服务器列表',
    'Refresh': '刷新',
    'Add server': '添加服务器',
    'Scan network': '扫描局域网',
    'Add to library': '添加到媒体库',
    'Bookmark this folder to Home': '将此文件夹收藏到首页',
    'Sync watched from SIMKL': '从 SIMKL 同步观看记录',
    'Add share': '添加共享',
    'Mark as watched': '标记为已观看',
    'Mark as unwatched': '标记为未观看',
    'Remove folder': '移除文件夹',
    'Discover': '发现设备',
    'Nothing yet': '暂无内容',
    'A TV-show folder, a movie folder\u2026': '电视剧文件夹、电影文件夹…',
    'Subtitles on NAS': 'NAS 上的字幕',
    'Live on iOS · reopens at same position on Android':
        'iOS 实时生效 · Android 将在相同位置重新打开',
    'LoudnessEnhancer (0–1500 mB)': '响度增强（0–1500 mB）',
    'Free account = 20/day (anonymous = 5/day). Create at opensubtitles.com':
        '免费账户每天 20 次（匿名用户每天 5 次），可在 opensubtitles.com 注册',
    'Positive values show subtitles later than authored — use it to fix out-of-sync files.':
        '正值会让字幕延后显示，可用于修正字幕不同步。',
    'This video isn\'t supported by the built-in player, so the fallback player is being used.':
        '内置播放器不支持此视频，已改用兼容播放器。',
    'Unmatched or duplicate candidates need manual matching. Manual selection is not supported here yet; no candidate was silently chosen.':
        '未匹配或重复的候选项需要手动匹配。此处暂不支持手动选择，系统不会擅自选取候选项。',
    'Trust HTTPS servers without a CA certificate (NAS, Nextcloud, etc.)':
        '信任没有 CA 证书的 HTTPS 服务器（NAS、Nextcloud 等）',
    'Scanning': '正在扫描',
    'Matching': '正在匹配',
    'Downloading': '正在下载',
    'Completed': '已完成',
    'Cancelled': '已取消',
    'Partially completed': '部分完成',
    'Failed': '失败',
    'Ready': '准备就绪',
    'cached': '已缓存',
    'success': '成功',
    'empty': '无弹幕',
    'noMatch': '未匹配',
    'failed': '失败',
    'cancelled': '已取消',
    'matched': '已匹配',
    'fetching': '正在获取',
    'pending': '等待中',
    'Hardware — fastest, HDR passthrough': '硬件——速度最快，支持 HDR 直通',
    'Software — compatibility fallback': '软件——兼容性后备方案',
    'Force hardware decoders': '强制使用硬件解码器',
    'Automatic (recommended)': '自动（推荐）',
    'Local file': '本地文件',
    'Document (SAF)': '文档（SAF）',
    'App asset': '应用资源',
    'Host is required': '服务器地址不能为空',
    'Enter a valid port (1–65535)': '请输入有效端口（1–65535）',
    'Server address is required': '服务器地址不能为空',
    'Enter a valid http(s) service URL': '请输入有效的 HTTP(S) 服务地址',
    'Enter the deployed danmu_api service URL, not its repository':
        '请输入已部署的 danmu_api 服务地址，而不是代码仓库地址',
  };
}

/// Drop-in localized replacement for ordinary Text widgets. It translates
/// known application copy but leaves dynamic media/server text untouched.
class AppText extends StatelessWidget {
  const AppText(
    this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  });

  final String data;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;

  @override
  Widget build(BuildContext context) => Text(
    AppLocalizations.of(context).tr(data),
    style: style,
    strutStyle: strutStyle,
    textAlign: textAlign,
    textDirection: textDirection,
    locale: locale,
    softWrap: softWrap,
    overflow: overflow,
    textScaler: textScaler,
    maxLines: maxLines,
    semanticsLabel: semanticsLabel,
    textWidthBasis: textWidthBasis,
    textHeightBehavior: textHeightBehavior,
    selectionColor: selectionColor,
  );
}

extension AppLocalizationContext on BuildContext {
  AppLocalizations get strings => AppLocalizations.of(this);
  String tr(String source) => strings.tr(source);
}
