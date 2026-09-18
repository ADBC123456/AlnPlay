import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/auto_play_store.dart';
import '../services/badge_prefs.dart';
import '../services/cache_cleaner.dart';
import '../services/cache_quota_manager.dart';
import '../services/image_cache_service.dart';
import '../widgets/update_settings_tile.dart';
import '../services/decoder_mode.dart';
import '../services/exo_player.dart';
import '../services/opensubtitles_client.dart';
import '../services/subtitle_encodings.dart';
import '../services/subtitle_languages.dart';
import '../services/subtitle_prefs.dart';
import '../config/simkl_keys.dart';
import '../services/simkl_client.dart';
import '../services/tmdb_client.dart';
import '../services/watched_store.dart';
import '../utils/tv_helper.dart';
import '../widgets/tv_overscan.dart';
import '../widgets/tv_tile.dart';
import '../theme/theme_controller.dart';
import 'danmaku_settings_screen.dart';
import '../l10n/app_localizations.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _diskBytes = 0;
  int _artworkBytes = 0;
  bool _cleared = false;
  bool _passthrough = false;
  bool _swipeGestures = true;
  bool _pipEnabled = true;
  bool _autoPlayNext = false;
  DecoderMode _decoderMode = DecoderMode.auto;
  double _audioBoost = 1.0;
  bool _nightMode = false;
  bool _simklConnected = false;
  DateTime? _simklLastSync;
  String? _osUsername;
  int? _osRemaining;
  bool _osLoggedIn = false;
  String _readingLang = 'system';
  String _downloadLang = 'eng';
  int _subEncoding = 0;
  bool _autoFetchSubs = false;
  bool _badgeEnabled = true;
  bool _badgeHdr = true;
  bool _badgeAudio = true;
  bool _badgeResolution = false;
  bool _badgeVideoCodec = false;
  bool _badgeSpatialAudio = true;
  bool _badgeServerTranscode = true;

  static String _themeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.system => 'Follow system',
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
  };

  Future<void> _pickTheme() async {
    final controller = AppThemeController.instance;
    final picked = await showDialog<ThemeMode>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const AppText('Theme'),
        children: [
          RadioGroup<ThemeMode>(
            groupValue: controller.themeMode,
            onChanged: (value) => Navigator.pop(dialogContext, value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mode in ThemeMode.values)
                  RadioListTile<ThemeMode>(
                    value: mode,
                    title: AppText(_themeLabel(mode)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null) return;
    try {
      await controller.setThemeMode(picked);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: AppText('Could not save theme preference')),
      );
    }
  }

  Future<void> _pickAppLanguage() async {
    final current = AppLocaleController.instance.locale.languageCode;
    final picked = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: AppText('Language'),
        children: [
          RadioGroup<String>(
            groupValue: current,
            onChanged: (value) => Navigator.pop(dialogContext, value),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<String>(
                  value: 'zh',
                  title: AppText('Chinese'),
                  subtitle: AppText('Chinese interface and TMDB metadata'),
                ),
                RadioListTile<String>(
                  value: 'en',
                  title: AppText('English'),
                  subtitle: AppText('English interface and TMDB metadata'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked != null) {
      await AppLocaleController.instance.setLanguage(picked);
    }
  }

  bool _badgeDecoder = false;
  String _tmdbKey = '';

  @override
  void initState() {
    super.initState();
    _refreshDiskSize();
    _loadPassthrough();
    _loadSwipeGestures();
    _loadPipEnabled();
    _loadAutoPlayNext();
    _loadDecoderMode();
    _loadAudioFilters();
    _loadSimkl();
    _loadOpensubtitles();
    _loadSubtitlePrefs();
    _loadBadgePrefs();
    _loadTmdbKey();
  }

  Future<void> _loadSimkl() async {
    final client = SimklClient();
    if (!client.isConfigured) return;
    try {
      final connected = await client.isAuthenticated();
      final lastSync = await client.lastSyncAt();
      if (mounted) {
        setState(() {
          _simklConnected = connected;
          _simklLastSync = lastSync;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadOpensubtitles() async {
    final c = OpensubtitlesClient.instance;
    if (!c.hasApiKey) return;
    try {
      await c
          .fetchUserInfo()
          .then((info) {
            final data = info['data'] as Map<String, dynamic>?;
            final remaining = data?['remaining_downloads'] as int?;
            if (mounted) {
              setState(() {
                _osLoggedIn = true;
                _osUsername = c.username;
                _osRemaining = remaining;
              });
            }
          })
          .catchError((_) {
            if (mounted) {
              setState(() {
                _osLoggedIn = false;
                _osUsername = null;
              });
            }
          });
      if (!c.isLoggedIn && mounted) {
        setState(() {
          _osLoggedIn = false;
          _osUsername = c.username;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _osLoggedIn = c.isLoggedIn;
          _osUsername = c.username;
        });
      }
    }
  }

  Future<void> _loadSubtitlePrefs() async {
    try {
      final reading = await SubtitlePrefs.loadReadingLanguage();
      final download = await SubtitlePrefs.loadDownloadLanguage();
      final enc = await SubtitlePrefs.loadEncoding();
      final auto = await SubtitlePrefs.loadAutoFetch();
      if (mounted) {
        setState(() {
          _readingLang = reading;
          _downloadLang = download;
          _subEncoding = enc;
          _autoFetchSubs = auto;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadBadgePrefs() async {
    try {
      final f = await BadgePrefs.load();
      if (mounted) {
        setState(() {
          _badgeEnabled = f.enabled;
          _badgeHdr = f.hdr;
          _badgeAudio = f.audio;
          _badgeResolution = f.resolution;
          _badgeVideoCodec = f.videoCodec;
          _badgeSpatialAudio = f.spatialAudio;
          _badgeServerTranscode = f.serverTranscode;
          _badgeDecoder = f.decoder;
        });
      }
    } catch (_) {}
  }

  Future<void> _pickLanguage({required bool isReading}) async {
    final current = isReading ? _readingLang : _downloadLang;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: AppText(
          isReading ? 'Subtitle reading language' : 'Download language',
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 360,
          child: RadioGroup<String>(
            groupValue: current,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: ListView.builder(
              itemCount: subtitleLanguages.length,
              itemBuilder: (_, i) {
                final l = subtitleLanguages[i];
                return RadioListTile<String>(
                  value: l.novaCode,
                  title: AppText(l.displayName),
                );
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const AppText('Cancel'),
          ),
        ],
      ),
    );
    if (picked != null) {
      if (isReading) {
        await SubtitlePrefs.saveReadingLanguage(picked);
        if (mounted) setState(() => _readingLang = picked);
      } else {
        await SubtitlePrefs.saveDownloadLanguage(picked);
        if (mounted) setState(() => _downloadLang = picked);
      }
    }
  }

  Future<void> _pickEncoding() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const AppText('Subtitle encoding'),
        content: SizedBox(
          width: double.maxFinite,
          height: 360,
          child: RadioGroup<int>(
            groupValue: _subEncoding,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: ListView.builder(
              itemCount: subtitleEncodings.length,
              itemBuilder: (_, i) {
                final e = subtitleEncodings[i];
                return RadioListTile<int>(
                  value: e.codepage,
                  title: AppText(e.displayName),
                );
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const AppText('Cancel'),
          ),
        ],
      ),
    );
    if (picked != null) {
      await SubtitlePrefs.saveEncoding(picked);
      if (mounted) setState(() => _subEncoding = picked);
    }
  }

  Future<void> _loginOpensubtitles() async {
    final uCtrl = TextEditingController();
    final pCtrl = TextEditingController();
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const AppText('OpenSubtitles sign in'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: uCtrl,
                decoration: InputDecoration(labelText: context.tr('Username')),
              ),
              TextField(
                controller: pCtrl,
                obscureText: true,
                decoration: InputDecoration(labelText: context.tr('Password')),
              ),
              if (err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: AppText(
                    err!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              AppText(
                'Free account = 20/day (anonymous = 5/day). Create at opensubtitles.com',
                style: TextStyle(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const AppText('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                try {
                  await OpensubtitlesClient.instance.login(
                    username: uCtrl.text.trim(),
                    password: pCtrl.text,
                  );
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } catch (e) {
                  setDlg(() => err = e.toString());
                }
              },
              child: const AppText('Sign in'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) await _loadOpensubtitles();
  }

  Future<void> _logoutOpensubtitles() async {
    await OpensubtitlesClient.instance.logout();
    if (mounted) {
      setState(() {
        _osLoggedIn = false;
        _osUsername = null;
        _osRemaining = null;
      });
    }
  }

  Future<void> _loadTmdbKey() async {
    final key = await TmdApi().effectiveApiKey();
    if (mounted) setState(() => _tmdbKey = key);
  }

  Future<void> _editTmdbKey() async {
    final ctrl = TextEditingController(text: _tmdbKey.isEmpty ? '' : _tmdbKey);
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const AppText('TMDB API key'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppText(
                'Get a free key at themoviedb.org/settings/api',
                style: TextStyle(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                decoration: InputDecoration(
                  labelText: context.tr('API key (v3 auth)'),
                  hintText: context.tr('32-character hex string'),
                ),
              ),
              if (err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: AppText(
                    err!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const AppText('Cancel'),
            ),
            if (_tmdbKey.isNotEmpty)
              TextButton(
                onPressed: () async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.remove(TmdApi.prefsKey);
                  if (ctx.mounted) Navigator.pop(ctx, true);
                },
                child: const AppText('Remove'),
              ),
            TextButton(
              onPressed: () async {
                final entered = ctrl.text.trim();
                if (entered.isNotEmpty && entered.length != 32) {
                  setDlg(() => err = 'Key must be 32 characters');
                  return;
                }
                final prefs = await SharedPreferences.getInstance();
                if (entered.isEmpty) {
                  await prefs.remove(TmdApi.prefsKey);
                } else {
                  await prefs.setString(TmdApi.prefsKey, entered);
                }
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const AppText('Save'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) await _loadTmdbKey();
  }

  Future<void> _loadPassthrough() async {
    final enabled = await isAudioPassthroughEnabled();
    if (mounted) setState(() => _passthrough = enabled);
  }

  Future<void> _loadSwipeGestures() async {
    try {
      final enabled = await areSwipeGesturesEnabled();
      if (mounted) setState(() => _swipeGestures = enabled);
    } catch (_) {}
  }

  Future<void> _loadPipEnabled() async {
    try {
      final enabled = await isPipEnabled();
      if (mounted) setState(() => _pipEnabled = enabled);
    } catch (_) {}
  }

  Future<void> _loadAutoPlayNext() async {
    try {
      final enabled = await isAutoPlayNextEnabled();
      if (mounted) setState(() => _autoPlayNext = enabled);
    } catch (_) {}
  }

  Future<void> _loadDecoderMode() async {
    try {
      final mode = await DecoderModeStore.load();
      if (mounted) setState(() => _decoderMode = mode);
    } catch (_) {}
  }

  Future<void> _loadAudioFilters() async {
    try {
      final boost = await PlaybackBoostStore.load();
      final night = await NightModeStore.load();
      if (mounted) {
        setState(() {
          _audioBoost = boost;
          _nightMode = night;
        });
      }
    } catch (_) {}
  }

  Future<void> _refreshDiskSize() async {
    final size = await CacheCleaner.diskSizeBytes();
    final artwork = await ImageCacheService.instance.diskSizeBytes();
    if (mounted) {
      setState(() {
        _diskBytes = size;
        _artworkBytes = artwork;
      });
    }
  }

  Future<void> _clearArtwork() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const AppText('Clear offline artwork?'),
        content: const AppText(
          'Posters, backdrops, episode stills and cast photos will need to be downloaded again. Your library and videos are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const AppText('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const AppText('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ImageCacheService.instance.clear();
      CacheCleaner.clearMemoryImages();
      await _refreshDiskSize();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: AppText('Could not clear cache.')),
        );
      }
    }
  }

  Future<void> _pickCacheLimit() async {
    final quota = CacheQuotaManager.instance;
    final selected = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const AppText('Cache limit'),
        children: [
          for (final gb in CacheQuotaManager.choices)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, gb),
              child: Row(
                children: [
                  Icon(
                    quota.limitBytes == gb * CacheQuotaManager.gib
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  const SizedBox(width: 12),
                  AppText(gb == 0 ? 'Unlimited' : '$gb GB'),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected == null) return;
    try {
      await quota.setLimit(selected * CacheQuotaManager.gib);
      await _refreshDiskSize();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: AppText('Could not change cache limit.')),
        );
      }
    }
  }

  Future<void> _clearCache() async {
    final totalBytes = _diskBytes + _artworkBytes + CacheCleaner.memoryBytes();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const AppText('Clear cache?'),
        content: AppText(
          'Removes ${CacheCleaner.formatBytes(totalBytes)} of cached images '
          'and temporary files. Posters and details may need to be reloaded '
          'from the network the next time you open them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const AppText('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const AppText('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await CacheQuotaManager.instance.clear();
      await ImageCacheService.instance.clear();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: AppText('Could not clear cache.')),
        );
      }
      return;
    }
    CacheCleaner.clearMemoryImages();
    if (!mounted) return;
    final pending = CacheQuotaManager.instance.pendingClear;
    setState(() => _cleared = !pending);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: AppText(
          pending
              ? 'Active playback files will be cleared after playback.'
              : 'Cache cleared',
        ),
      ),
    );
    await _refreshDiskSize();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isTv = isTvMode(context);

    return SafeArea(
      bottom: false,
      child: TvOverscan(
        child: ListView(
          padding: EdgeInsets.only(
            bottom: 24 + MediaQuery.paddingOf(context).bottom,
          ),
          children: _settingsGroups([
            _SettingsHeading('General'),
            TvTile(
              leading: const Icon(Icons.language),
              title: const AppText('Language'),
              subtitle: AppText(
                AppLocaleController.instance.isChinese ? 'Chinese' : 'English',
              ),
              onTap: _pickAppLanguage,
            ),
            const UpdateSettingsTile(),
            const Divider(),
            _SettingsHeading('Appearance'),
            ListenableBuilder(
              listenable: AppThemeController.instance,
              builder: (context, _) => TvTile(
                leading: const Icon(Icons.brightness_6_outlined),
                title: const AppText('Theme'),
                subtitle: AppText(
                  _themeLabel(AppThemeController.instance.themeMode),
                ),
                onTap: _pickTheme,
              ),
            ),
            const Divider(),
            _SettingsHeading('Storage'),
            TvTile(
              leading: const Icon(Icons.cleaning_services),
              title: const AppText('Clear cache'),
              subtitle: AppText(
                _cleared
                    ? 'Cached images and temporary files cleared'
                    : '${CacheCleaner.formatBytes(_diskBytes)} on disk · '
                          '${CacheCleaner.formatBytes(CacheCleaner.memoryBytes())} in memory',
              ),
              onTap: _clearCache,
            ),
            ListenableBuilder(
              listenable: CacheQuotaManager.instance,
              builder: (context, _) {
                final quota = CacheQuotaManager.instance;
                return TvTile(
                  leading: const Icon(Icons.storage_outlined),
                  title: const AppText('Cache limit'),
                  subtitle: Text(
                    '${CacheCleaner.formatBytes(quota.usedBytes)} / '
                    '${quota.limitBytes == 0 ? context.tr('Unlimited') : CacheCleaner.formatBytes(quota.limitBytes)}\n'
                    '${context.tr(quota.overLimit ? 'Active playback files will be cleared after playback.' : 'Limits temporary files and danmaku; offline artwork is managed separately.')}',
                  ),
                  onTap: _pickCacheLimit,
                );
              },
            ),
            TvTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const AppText('Offline artwork'),
              subtitle: Text(
                '${CacheCleaner.formatBytes(_artworkBytes)} · ${context.tr('Kept until manually cleared')}',
              ),
              onTap: _clearArtwork,
            ),
            if (defaultTargetPlatform == TargetPlatform.android) ...[
              const Divider(),
              _SettingsHeading('Audio'),
              SwitchListTile(
                secondary: const Icon(Icons.surround_sound),
                title: const AppText('Audio passthrough'),
                subtitle: AppText(
                  _passthrough
                      ? 'Auto — passthrough when HDMI detected'
                      : 'Off — decode to PCM (default)',
                ),
                value: _passthrough,
                onChanged: (value) async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool(kAudioPassthroughKey, value);
                  if (mounted) setState(() => _passthrough = value);
                },
              ),
            ],
            if (!isTv) ...[
              const Divider(),
              _SettingsHeading('Player'),
              SwitchListTile(
                secondary: const Icon(Icons.swipe),
                title: const AppText('Swipe gestures'),
                subtitle: const AppText(
                  'Swipe left side for brightness, right side for volume',
                ),
                value: _swipeGestures,
                onChanged: (value) async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool(kSwipeGesturesKey, value);
                  if (mounted) setState(() => _swipeGestures = value);
                },
              ),
              // PiP on both platforms: Android auto-enters from
              // onUserLeaveHint (native pref read), iOS arms
              // canStartPictureInPictureAutomaticallyFromInline from the same
              // pref. Pointless on TV, so it hides with the other
              // phone-only controls.
              if (defaultTargetPlatform == TargetPlatform.android ||
                  defaultTargetPlatform == TargetPlatform.iOS)
                SwitchListTile(
                  secondary: const Icon(Icons.picture_in_picture),
                  title: const AppText('Picture-in-picture'),
                  subtitle: const AppText(
                    'Keep playing in a floating window when you leave the app',
                  ),
                  value: _pipEnabled,
                  onChanged: (value) async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool(kPipEnabledKey, value);
                    if (mounted) setState(() => _pipEnabled = value);
                  },
                ),
              SwitchListTile(
                secondary: const Icon(Icons.skip_next),
                title: const AppText('Auto-play next episode'),
                subtitle: const AppText('Play the next episode when one ends'),
                value: _autoPlayNext,
                onChanged: (value) async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool(kAutoPlayNextKey, value);
                  if (mounted) setState(() => _autoPlayNext = value);
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.label),
                title: const AppText('On-screen badges'),
                subtitle: const AppText(
                  'Show format chips on screen while playing',
                ),
                value: _badgeEnabled,
                onChanged: (value) async {
                  await BadgePrefs.setEnabled(value);
                  if (mounted) setState(() => _badgeEnabled = value);
                },
              ),
              if (_badgeEnabled) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(56, 8, 16, 4),
                  child: AppText(
                    'Format',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _BadgeToggle(
                  icon: Icons.high_quality,
                  label: 'HDR',
                  subtitle: 'DV / HDR10 / HDR10+ / HLG / SDR',
                  value: _badgeHdr,
                  onChanged: (v) async {
                    await BadgePrefs.setHdr(v);
                    if (mounted) setState(() => _badgeHdr = v);
                  },
                ),
                _BadgeToggle(
                  icon: Icons.audiotrack,
                  label: 'Audio codec',
                  subtitle: 'E-AC3 · 5.1 / DTS-HD · 7.1 / AAC …',
                  value: _badgeAudio,
                  onChanged: (v) async {
                    await BadgePrefs.setAudio(v);
                    if (mounted) setState(() => _badgeAudio = v);
                  },
                ),
                _BadgeToggle(
                  icon: Icons.videocam,
                  label: 'Video codec',
                  subtitle: 'HEVC / H.264 / AV1',
                  value: _badgeVideoCodec,
                  onChanged: (v) async {
                    await BadgePrefs.setVideoCodec(v);
                    if (mounted) setState(() => _badgeVideoCodec = v);
                  },
                ),
                _BadgeToggle(
                  icon: Icons.aspect_ratio,
                  label: 'Resolution',
                  value: _badgeResolution,
                  onChanged: (v) async {
                    await BadgePrefs.setResolution(v);
                    if (mounted) setState(() => _badgeResolution = v);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(56, 8, 16, 4),
                  child: AppText(
                    'Playback',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _BadgeToggle(
                  icon: Icons.spatial_audio,
                  label: 'Spatial audio',
                  value: _badgeSpatialAudio,
                  onChanged: (v) async {
                    await BadgePrefs.setSpatialAudio(v);
                    if (mounted) setState(() => _badgeSpatialAudio = v);
                  },
                ),
                _BadgeToggle(
                  icon: Icons.sync,
                  label: 'Server transcoding',
                  value: _badgeServerTranscode,
                  onChanged: (v) async {
                    await BadgePrefs.setServerTranscode(v);
                    if (mounted) setState(() => _badgeServerTranscode = v);
                  },
                ),
                _BadgeToggle(
                  icon: Icons.memory,
                  label: 'Decoder',
                  subtitle: 'HW / SW / auto',
                  value: _badgeDecoder,
                  onChanged: (v) async {
                    await BadgePrefs.setDecoder(v);
                    if (mounted) setState(() => _badgeDecoder = v);
                  },
                ),
              ],
              // Subtitle appearance settings moved into the player's ⋮ sheet
              // (subtitle_settings_screen.dart is pushed from there now).
              // Volume Boost + Night Mode need Media3's LoudnessEnhancer
              // (Android only) — AVPlayer caps volume at 1.0 and exposes no
              // DRC, so showing these on iOS would be cosmetic no-ops.
              if (defaultTargetPlatform == TargetPlatform.android) ...[
                TvTile(
                  leading: const Icon(Icons.volume_up),
                  title: const AppText('Volume Boost'),
                  subtitle: AppText(
                    _audioBoost > 1.01
                        ? '${_audioBoost.toStringAsFixed(1)}× (LoudnessEnhancer)'
                        : 'Off — 1.0×',
                  ),
                  onTap: () async {
                    double temp = _audioBoost;
                    final picked = await showDialog<double>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const AppText('Volume Boost'),
                        content: StatefulBuilder(
                          builder: (context, setD) => Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Slider(
                                value: temp.clamp(1.0, 3.0),
                                min: 1.0,
                                max: 3.0,
                                divisions: 20,
                                label: '${temp.toStringAsFixed(1)}×',
                                onChanged: (v) => setD(
                                  () =>
                                      temp = double.parse(v.toStringAsFixed(1)),
                                ),
                              ),
                              AppText(
                                '${temp.toStringAsFixed(1)}×',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const AppText('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, temp),
                            child: const AppText('Save'),
                          ),
                        ],
                      ),
                    );
                    if (picked != null) {
                      await PlaybackBoostStore.save(picked);
                      if (mounted) setState(() => _audioBoost = picked);
                    }
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.nights_stay),
                  title: const AppText('Night Mode'),
                  subtitle: const AppText(
                    'Compress dynamic range for quiet listening',
                  ),
                  value: _nightMode,
                  onChanged: (value) async {
                    await NightModeStore.save(value);
                    if (mounted) setState(() => _nightMode = value);
                  },
                ),
              ],
              if (defaultTargetPlatform == TargetPlatform.android)
                TvTile(
                  leading: const Icon(Icons.memory),
                  title: const AppText('Video decoder'),
                  subtitle: AppText(switch (_decoderMode) {
                    DecoderMode.hw => 'Hardware — fastest, HDR passthrough',
                    DecoderMode.sw => 'Software — compatibility fallback',
                    _ => 'Auto — hardware when available',
                  }),
                  onTap: () async {
                    final picked = await showDialog<DecoderMode>(
                      context: context,
                      builder: (context) => SimpleDialog(
                        title: const AppText('Video decoder'),
                        children: [
                          RadioGroup<DecoderMode>(
                            groupValue: _decoderMode,
                            onChanged: (v) => Navigator.of(context).pop(v),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (final m in DecoderMode.values)
                                  RadioListTile<DecoderMode>(
                                    value: m,
                                    title: AppText(m.label),
                                    subtitle: AppText(switch (m) {
                                      DecoderMode.hw =>
                                        'Force hardware decoders',
                                      DecoderMode.sw =>
                                        'Prefer software decoders',
                                      _ =>
                                        'Let the system choose (recommended)',
                                    }),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                    if (picked != null) {
                      await DecoderModeStore.save(picked);
                      if (mounted) setState(() => _decoderMode = picked);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: AppText('Takes effect on next video'),
                        ),
                      );
                    }
                  },
                ),
            ],
            const Divider(),
            _SettingsHeading('Danmaku'),
            TvTile(
              leading: const Icon(Icons.forum_outlined),
              title: const AppText('Danmaku settings'),
              subtitle: const AppText('Sources, filters and appearance'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DanmakuSettingsScreen(),
                ),
              ),
            ),
            // Subtitles — OpenSubtitles (Nova-style): anonymous 5/day, free login 20/day
            const Divider(),
            _SettingsHeading('Metadata'),
            TvTile(
              leading: const Icon(Icons.movie),
              title: const AppText('TMDB API key'),
              subtitle: AppText(
                _tmdbKey.isEmpty
                    ? 'Not set — enter your own key'
                    : 'Set (${_tmdbKey.substring(0, 4)}…${_tmdbKey.substring(_tmdbKey.length - 4)})',
              ),
              onTap: _editTmdbKey,
            ),
            const Divider(),
            _SettingsHeading('Subtitles'),
            TvTile(
              leading: const Icon(Icons.subtitles),
              title: const AppText('OpenSubtitles'),
              subtitle: AppText(
                !OpensubtitlesClient.instance.hasApiKey
                    ? 'Add OPENSUBTITLES_API_KEY in .env and rebuild'
                    : _osLoggedIn
                    ? 'Signed in as ${_osUsername ?? ''}${_osRemaining != null ? ' · $_osRemaining remaining' : ''}'
                    : 'Anonymous — 5/day, sign in for 20/day',
              ),
              onTap: !OpensubtitlesClient.instance.hasApiKey
                  ? null
                  : _osLoggedIn
                  ? _logoutOpensubtitles
                  : _loginOpensubtitles,
            ),
            TvTile(
              leading: const Icon(Icons.closed_caption),
              title: const AppText('Subtitle reading language'),
              subtitle: AppText(displayNameForNovaCode(_readingLang)),
              onTap: () => _pickLanguage(isReading: true),
            ),
            TvTile(
              leading: const Icon(Icons.download),
              title: const AppText('Subtitle download language'),
              subtitle: AppText(displayNameForNovaCode(_downloadLang)),
              onTap: () => _pickLanguage(isReading: false),
            ),
            TvTile(
              leading: const Icon(Icons.text_fields),
              title: const AppText('Subtitle encoding'),
              subtitle: AppText(displayNameForCodepage(_subEncoding)),
              onTap: _pickEncoding,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.auto_awesome),
              title: const AppText('Auto-fetch subtitles'),
              subtitle: const AppText(
                'Download best match when no subtitles found',
              ),
              value: _autoFetchSubs,
              onChanged: (v) async {
                await SubtitlePrefs.saveAutoFetch(v);
                if (mounted) setState(() => _autoFetchSubs = v);
              },
            ),
            if (simklClientId.isNotEmpty) ...[
              const Divider(),
              _SettingsHeading('SIMKL'),
              if (_simklConnected) ...[
                TvTile(
                  leading: const Icon(Icons.sync),
                  title: const AppText('Sync now'),
                  subtitle: AppText(
                    _simklLastSync == null
                        ? 'Push watched + resume to SIMKL'
                        : 'Last synced ${_formatWhen(_simklLastSync!)}',
                  ),
                  onTap: _syncSimkl,
                ),
                TvTile(
                  leading: const Icon(Icons.link_off),
                  title: const AppText('Disconnect SIMKL'),
                  subtitle: const AppText('Sign out and stop syncing'),
                  onTap: () async {
                    await SimklClient().signOut();
                    if (mounted) {
                      setState(() {
                        _simklConnected = false;
                        _simklLastSync = null;
                      });
                    }
                  },
                ),
              ] else
                TvTile(
                  leading: const Icon(Icons.link),
                  title: const AppText('Connect SIMKL'),
                  subtitle: const AppText(
                    'Sync watched history with simkl.com (free unlimited)',
                  ),
                  onTap: _connectSimkl,
                ),
            ],
          ]),
        ),
      ),
    );
  }

  String _formatWhen(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Future<void> _connectSimkl() async {
    final client = SimklClient();
    try {
      final code = await client.requestPinCode();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _SimklConnectDialog(client: client, code: code),
      );
      await _loadSimkl();
    } on SimklException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: AppText(e.message)));
      }
    }
  }

  Future<void> _syncSimkl() async {
    final client = SimklClient();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final items = await _collectSimklItems();
      await client.markWatched(items);
      if (mounted) {
        setState(() => _simklLastSync = DateTime.now());
        messenger.showSnackBar(
          SnackBar(content: AppText('Synced ${items.length} item(s) to SIMKL')),
        );
      }
    } on SimklException catch (e) {
      messenger.showSnackBar(SnackBar(content: AppText(e.message)));
    }
  }

  Future<List<SimklWatchItem>> _collectSimklItems() async {
    final keys = await WatchedStore.load();
    final items = <SimklWatchItem>[];
    for (final key in keys) {
      final meta = TmdService.instance.metaFor(key);
      if (meta == null) continue;
      final movie = meta.movie;
      if (movie.id == 0) continue;
      final parsed = ParsedFileName.parse(key);
      items.add(
        SimklWatchItem(
          tmdbId: movie.id,
          isTv: movie.kind == TmdKind.tv,
          season: parsed.isEpisode ? parsed.season : null,
          episode: parsed.isEpisode ? parsed.episode : null,
        ),
      );
    }
    return items;
  }
}

/// Device-flow dialog: shows the user code + activation URL and polls in the
class _SimklConnectDialog extends StatefulWidget {
  const _SimklConnectDialog({required this.client, required this.code});
  final SimklClient client;
  final SimklPinCode code;
  @override
  State<_SimklConnectDialog> createState() => _SimklConnectDialogState();
}

class _SimklConnectDialogState extends State<_SimklConnectDialog> {
  String _status = 'Waiting for authorization…';
  @override
  void initState() {
    super.initState();
    _poll();
  }

  Future<void> _poll() async {
    try {
      final ok = await widget.client.pollForToken(widget.code);
      if (!mounted) return;
      setState(() => _status = ok ? 'Connected!' : 'Timed out — try again.');
      if (ok) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        if (mounted) Navigator.of(context).pop();
      }
    } on SimklException catch (e) {
      if (!mounted) return;
      setState(() => _status = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const AppText('Connect SIMKL'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppText('Go to the address below and enter this code:'),
            const SizedBox(height: 12),
            Center(
              child: AppText(
                widget.code.userCode,
                style: theme.textTheme.headlineMedium?.copyWith(
                  letterSpacing: 4,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: AppText(
                widget.code.verificationUrl,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(child: AppText(_status)),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const AppText('Cancel'),
        ),
      ],
    );
  }
}

class _SettingsHeading extends StatelessWidget {
  const _SettingsHeading(this.title);
  final String title;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

List<Widget> _settingsGroups(List<Widget> items) {
  final sections = <Widget>[];
  String? heading;
  var children = <Widget>[];
  void finish() {
    if (heading == null) return;
    sections.add(
      ExpansionTile(
        key: PageStorageKey('settings:$heading'),
        title: AppText(heading),
        initiallyExpanded: true,
        maintainState: true,
        shape: const Border(),
        collapsedShape: const Border(),
        children: children,
      ),
    );
    children = [];
  }

  for (final item in items) {
    if (item is _SettingsHeading) {
      finish();
      heading = item.title;
    } else if (item is! Divider) {
      children.add(item);
    }
  }
  finish();
  return sections;
}

/// Compact badge toggle row — icon + label + optional subtitle + switch.
/// Much lighter than a full CheckboxListTile: 40px height, no checkbox.
class _BadgeToggle extends StatelessWidget {
  const _BadgeToggle({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: Icon(
          icon,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        title: AppText(label, style: const TextStyle(fontSize: 14)),
        subtitle: subtitle != null
            ? AppText(subtitle!, style: const TextStyle(fontSize: 11))
            : null,
        trailing: Switch.adaptive(
          value: value,
          onChanged: onChanged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        onTap: () => onChanged(!value),
      ),
    );
  }
}
