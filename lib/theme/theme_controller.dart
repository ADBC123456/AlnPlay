import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// MaterialApp resolves system mode and reacts to platform brightness changes.
class AppThemeController extends ChangeNotifier {
  AppThemeController();

  static final instance = AppThemeController();
  static const preferenceKey = 'dreamplayer.themeMode';

  ThemeMode _themeMode = ThemeMode.system;
  Future<void> _pendingWrite = Future<void>.value();

  ThemeMode get themeMode => _themeMode;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = switch (prefs.getString(preferenceKey)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) {
    // Serial writes ensure rapid selections persist the last choice.
    final write = _pendingWrite.then((_) async {
      if (_themeMode == mode) return;
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(preferenceKey, mode.name)) {
        throw StateError('Could not save theme preference');
      }
      _themeMode = mode;
      notifyListeners();
    });
    _pendingWrite = write.catchError((Object _) {});
    return write;
  }
}
