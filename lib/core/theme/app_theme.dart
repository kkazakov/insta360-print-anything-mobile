import 'package:flutter/material.dart';

/// Material 3 theme for the app.
///
/// The gallery sits on a near-black surface in dark mode so the thumbnails
/// carry the colour, with a single warm accent borrowed from Insta360's yellow.
abstract final class AppTheme {
  static const Color _seed = Color(0xFFFFC42E);
  static const Color _darkSurface = Color(0xFF0C0C0E);
  static const Color _lightSurface = Color(0xFFFBFAF7);

  static ThemeData get dark => _build(_darkScheme());

  static ThemeData get light => _build(_lightScheme());

  static ColorScheme _darkScheme() =>
      ColorScheme.fromSeed(
        seedColor: _seed,
        brightness: Brightness.dark,
      ).copyWith(
        surface: _darkSurface,
        surfaceContainerLowest: const Color(0xFF08080A),
        surfaceContainerLow: const Color(0xFF121216),
        surfaceContainer: const Color(0xFF16161B),
        surfaceContainerHigh: const Color(0xFF1D1D23),
        surfaceContainerHighest: const Color(0xFF26262E),
      );

  static ColorScheme _lightScheme() =>
      ColorScheme.fromSeed(seedColor: _seed).copyWith(
        surface: _lightSurface,
        surfaceContainerLowest: Colors.white,
        surfaceContainerLow: const Color(0xFFF5F3ED),
        surfaceContainer: const Color(0xFFF0EEE7),
        surfaceContainerHigh: const Color(0xFFEAE7DF),
        surfaceContainerHighest: const Color(0xFFE3E0D7),
      );

  static ThemeData _build(ColorScheme scheme) {
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    const buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(16)),
    );

    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 20,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
          color: scheme.onSurface,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 52),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          shape: buttonShape,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 52),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          shape: buttonShape,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.8)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 44),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        modalBackgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: 0.4),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.5),
        space: 1,
        thickness: 1,
      ),
    );
  }
}
