import 'package:flutter/material.dart';

/// Shared design tokens.
///
/// The palette is deliberately warm: a cream ground, terracotta accents and
/// warm-tinted greys. The earlier cold blue-on-white read as a utility and
/// made the app feel clinical. Warmth here is not just hue — the greys carry
/// a little red so nothing on screen is a dead neutral.
///
/// The AR path overlay stays blue and white on purpose. It has to read as a
/// machine-placed guide against unpredictable street colour, and warm tones
/// disappear against brick, tarmac and evening light.
class AppColors {
  static const brand = Color(0xFFE2613C); // terracotta
  static const brandDeep = Color(0xFFC2451F);
  static const brandLift = Color(0xFFFF9166); // the light end of the header
  static const brandSoft = Color(0xFFFDEBE3);

  static const amber = Color(0xFFE8A33D);
  static const sage = Color(0xFF6B8F71); // calm counterweight to all the warmth

  static const bg = Color(0xFFFCF7F3);
  static const card = Colors.white;
  static const ink = Color(0xFF2A1D17);
  static const inkSoft = Color(0xFF8C7A70);
  static const line = Color(0xFFEFE2D9);
  static const danger = Color(0xFFC2410C);
}

/// Wide, soft and warm-tinted. A neutral black shadow on a cream ground
/// looks like dirt rather than depth.
const kCardShadow = [
  BoxShadow(color: Color(0x14754C33), blurRadius: 20, offset: Offset(0, 7)),
  BoxShadow(color: Color(0x0D5A3A28), blurRadius: 3, offset: Offset(0, 1)),
];

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.brand,
    brightness: Brightness.light,
  ).copyWith(
    primary: AppColors.brand,
    surface: AppColors.card,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    splashFactory: InkSparkle.splashFactory,
    textTheme: const TextTheme(
      headlineLarge: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.6, color: AppColors.ink),
      titleMedium: TextStyle(fontWeight: FontWeight.w700, color: AppColors.ink),
      bodyMedium: TextStyle(color: AppColors.inkSoft, height: 1.4),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.brand,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.bg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
  );
}
