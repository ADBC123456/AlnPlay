import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppTheme {
  // Ordinary pages use scaffoldBackgroundColor; retained for legacy callers.
  static const libraryBackground = Color(0xFF171719);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final background = dark ? libraryBackground : const Color(0xFFFAFAFB);
    final foreground = dark ? const Color(0xFFF5F5F7) : const Color(0xFF19191C);
    final secondary = dark ? const Color(0xFFACACB4) : const Color(0xFF64646D);
    final panel = dark ? const Color(0xFF232326) : Colors.white;
    final elevated = dark ? const Color(0xFF303034) : const Color(0xFFEEEEF0);
    final outline = dark ? const Color(0xFF777780) : const Color(0xFF797982);
    final divider = dark ? const Color(0xFF38383D) : const Color(0xFFDEDEE3);
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF777777),
          brightness: brightness,
        ).copyWith(
          primary: foreground,
          onPrimary: background,
          primaryContainer: elevated,
          onPrimaryContainer: foreground,
          secondary: secondary,
          onSecondary: background,
          secondaryContainer: elevated,
          onSecondaryContainer: foreground,
          tertiary: foreground,
          onTertiary: background,
          tertiaryContainer: elevated,
          onTertiaryContainer: foreground,
          surface: background,
          onSurface: foreground,
          onSurfaceVariant: secondary,
          surfaceContainerLowest: dark ? const Color(0xFF101012) : Colors.white,
          surfaceContainerLow: panel,
          surfaceContainer: panel,
          surfaceContainerHigh: elevated,
          surfaceContainerHighest: dark
              ? const Color(0xFF3B3B40)
              : const Color(0xFFE5E5E9),
          outline: outline,
          outlineVariant: divider,
          surfaceTint: Colors.transparent,
          inverseSurface: foreground,
          onInverseSurface: background,
          inversePrimary: background,
        );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: background,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: foreground,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        systemOverlayStyle: systemOverlayStyle(brightness),
        titleTextStyle: TextStyle(
          color: foreground,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: background,
        indicatorColor: Colors.transparent,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? foreground
                : secondary,
            size: 28,
          ),
        ),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      searchBarTheme: SearchBarThemeData(
        backgroundColor: WidgetStatePropertyAll(elevated),
        elevation: const WidgetStatePropertyAll(0),
        hintStyle: WidgetStatePropertyAll(TextStyle(color: secondary)),
      ),
      cardTheme: CardThemeData(
        color: panel,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dialogTheme: DialogThemeData(backgroundColor: panel),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: panel,
        modalBackgroundColor: panel,
        surfaceTintColor: Colors.transparent,
      ),
      listTileTheme: ListTileThemeData(iconColor: secondary),
      dividerTheme: DividerThemeData(color: divider),
    );
  }

  static SystemUiOverlayStyle systemOverlayStyle(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: dark
          ? Brightness.light
          : Brightness.dark,
      systemNavigationBarContrastEnforced: false,
    );
  }
}
