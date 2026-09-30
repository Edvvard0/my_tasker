import 'package:flutter/material.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_colors.dart';

/// Имена семейств шрифтов, встроенных в приложение.
abstract final class AppFonts {
  static const sans = 'Inter';
  static const mono = 'JetBrains Mono';

  /// Все встроенные файлы: (семейство, вес, путь ассета).
  static const files = <(String, int, String)>[
    (sans, 400, 'assets/fonts/Inter-Regular.ttf'),
    (sans, 500, 'assets/fonts/Inter-Medium.ttf'),
    (sans, 600, 'assets/fonts/Inter-SemiBold.ttf'),
    (sans, 700, 'assets/fonts/Inter-Bold.ttf'),
    (mono, 400, 'assets/fonts/JetBrainsMono-Regular.ttf'),
    (mono, 500, 'assets/fonts/JetBrainsMono-Medium.ttf'),
    (mono, 600, 'assets/fonts/JetBrainsMono-SemiBold.ttf'),
    (mono, 700, 'assets/fonts/JetBrainsMono-Bold.ttf'),
  ];
}

FontWeight _w(int w) => FontWeight.values[(w ~/ 100) - 1];

TextStyle _style({
  required String family,
  required int weight,
  required double size,
  required double line,
  double tracking = 0,
  Color color = AppColors.textPrimaryValue,
}) => TextStyle(
  fontFamily: family,
  fontWeight: _w(weight),
  fontSize: size,
  height: line / size,
  letterSpacing: size * tracking,
  color: color,
);

/// Шкала текстовых стилей (02, раздел 2.2.2). Цвет по умолчанию —
/// `text/primary`; вторичные цвета задаются через `copyWith`.
@immutable
class AppTextStyles extends ThemeExtension<AppTextStyles> {
  const AppTextStyles({
    required this.display,
    required this.kpi,
    required this.h1,
    required this.h2,
    required this.h3,
    required this.body,
    required this.bodyStrong,
    required this.bodyS,
    required this.label,
    required this.caption,
    required this.tabLabel,
    required this.overline,
    required this.monoL,
    required this.monoM,
    required this.monoS,
  });

  /// Мобильная шкала (Compact).
  factory AppTextStyles.mobile() => AppTextStyles(
    display: _mono(600, 34, 40, -0.01),
    kpi: _mono(600, 26, 32, -0.005),
    h1: _sans(700, 26, 32, -0.01),
    h2: _sans(600, 20, 26, -0.005),
    h3: _sans(600, 17, 22),
    body: _sans(400, 15, 22),
    bodyStrong: _sans(500, 15, 22),
    bodyS: _sans(400, 13, 18),
    label: _sans(500, 14, 20, 0.002),
    caption: _sans(400, 12, 16, 0.002),
    tabLabel: _sans(500, 11, 14, 0.002),
    overline: _sans(500, 11, 14, 0.06),
    monoL: _mono(500, 17, 22),
    monoM: _mono(400, 14, 20),
    monoS: _mono(400, 12, 16),
  );

  /// Десктопная шкала (Medium и шире).
  factory AppTextStyles.desktop() => AppTextStyles(
    display: _mono(600, 32, 38, -0.01),
    kpi: _mono(600, 24, 30, -0.005),
    h1: _sans(700, 24, 32, -0.01),
    h2: _sans(600, 18, 24, -0.005),
    h3: _sans(600, 15, 20),
    body: _sans(400, 14, 20),
    bodyStrong: _sans(500, 14, 20),
    bodyS: _sans(400, 13, 18),
    label: _sans(500, 13, 18, 0.002),
    caption: _sans(400, 12, 16, 0.002),
    tabLabel: _sans(500, 11, 14, 0.002),
    overline: _sans(500, 11, 14, 0.06),
    monoL: _mono(500, 16, 22),
    monoM: _mono(400, 13, 18),
    monoS: _mono(400, 12, 16),
  );

  factory AppTextStyles.forWindow(WindowClass windowClass) =>
      windowClass.isDesktopScale
      ? AppTextStyles.desktop()
      : AppTextStyles.mobile();

  static TextStyle _sans(
    int weight,
    double size,
    double line, [
    double tracking = 0,
  ]) => _style(
    family: AppFonts.sans,
    weight: weight,
    size: size,
    line: line,
    tracking: tracking,
  );

  static TextStyle _mono(
    int weight,
    double size,
    double line, [
    double tracking = 0,
  ]) => _style(
    family: AppFonts.mono,
    weight: weight,
    size: size,
    line: line,
    tracking: tracking,
  );

  final TextStyle display;
  final TextStyle kpi;
  final TextStyle h1;
  final TextStyle h2;
  final TextStyle h3;
  final TextStyle body;
  final TextStyle bodyStrong;
  final TextStyle bodyS;
  final TextStyle label;
  final TextStyle caption;

  /// Подпись таб-бара: 11/14.
  final TextStyle tabLabel;

  /// UPPERCASE-лейбл метрики; сам текст в верхний регистр переводит вызывающий.
  final TextStyle overline;
  final TextStyle monoL;
  final TextStyle monoM;
  final TextStyle monoS;

  /// Стиль Material [TextTheme], собранный из шкалы.
  TextTheme toTextTheme() => TextTheme(
    displayLarge: display,
    displayMedium: kpi,
    displaySmall: kpi,
    headlineLarge: h1,
    headlineMedium: h2,
    headlineSmall: h2,
    titleLarge: h2,
    titleMedium: h3,
    titleSmall: bodyStrong,
    bodyLarge: body,
    bodyMedium: body,
    bodySmall: bodyS,
    labelLarge: label,
    labelMedium: label,
    labelSmall: overline,
  );

  @override
  AppTextStyles copyWith() => this;

  @override
  AppTextStyles lerp(ThemeExtension<AppTextStyles>? other, double t) =>
      other is AppTextStyles && t >= 0.5 ? other : this;
}
