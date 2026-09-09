import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'danmaku/service/danmaku_service.dart';
import 'l10n/app_localizations.dart';
import 'services/display_refresh_rate.dart';
import 'services/cache_quota_manager.dart';
import 'theme/theme_controller.dart';
import 'utils/tv_helper.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await useNativeDisplayRefreshRate();
  await AppLocaleController.instance.init();
  await AppThemeController.instance.init();
  await CacheQuotaManager.instance.initialize();
  unawaited(
    CacheQuotaManager.instance.trim().catchError((Object _) {
      // An unavailable cache volume must not prevent app startup.
    }),
  );
  unawaited(initTvMode());
  unawaited(DanmakuService.instance.init());
  runApp(const AlnPlayApp());
}
