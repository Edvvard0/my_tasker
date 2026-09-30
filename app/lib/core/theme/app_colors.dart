import 'package:flutter/material.dart';

/// Цветовые токены тёмной темы (02_DESIGN_SYSTEM, раздел 2.1).
///
/// Палитра — «чёрный, белый, серый, синий»: чистый чёрный фон, нейтральная
/// серая шкала (без оттенка), один синий акцент и один функциональный
/// приглушённый красный (только для удаления и критичных ошибок). Цветов
/// модулей, зелёного и жёлтого нет. Светлая тема не входит в MVP.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.bgBase,
    required this.surface1,
    required this.surface2,
    required this.surface3,
    required this.surface4,
    required this.surfaceInverse,
    required this.borderSubtle,
    required this.borderDefault,
    required this.borderStrong,
    required this.borderFocus,
    required this.borderDanger,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.textDisabled,
    required this.textOnInverse,
    required this.accent,
    required this.danger,
    required this.dangerMuted,
  });

  /// Тёмная тема — основная.
  static const dark = AppColors(
    bgBase: Color(0xFF000000),
    surface1: Color(0xFF141414),
    surface2: Color(0xFF1C1C1C),
    surface3: Color(0xFF262626),
    surface4: Color(0xFF3A3A3A),
    surfaceInverse: Color(0xFFFFFFFF),
    borderSubtle: Color(0xFF1F1F1F),
    borderDefault: Color(0xFF2A2A2A),
    borderStrong: Color(0xFF404040),
    borderFocus: accentValue,
    borderDanger: Color(0xFFF0625A),
    textPrimary: textPrimaryValue,
    textSecondary: Color(0xFFA6A6A6),
    textTertiary: Color(0xFF8F8F8F),
    textDisabled: Color(0xFF5C5C5C),
    textOnInverse: Color(0xFF000000),
    accent: accentValue,
    danger: Color(0xFFF0625A),
    dangerMuted: Color(0xFF2B1615),
  );

  // Фоны и поверхности.
  final Color bgBase;
  final Color surface1;
  final Color surface2;
  final Color surface3;

  /// Самая светлая поверхность: активный пункт навигации, нажатое.
  final Color surface4;

  /// Белая заливка главной кнопки (текст на ней — [textOnInverse]).
  final Color surfaceInverse;

  // Обводки.
  final Color borderSubtle;
  final Color borderDefault;
  final Color borderStrong;
  final Color borderFocus;
  final Color borderDanger;

  // Текст.
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color textDisabled;
  final Color textOnInverse;

  /// Единственный акцент: «сегодня/выбрано», фокус, ссылки, прогресс к цели.
  final Color accent;

  /// Функциональное исключение: удаление и критичные ошибки.
  final Color danger;
  final Color dangerMuted;

  /// Значение `text/primary` для const-контекстов.
  static const textPrimaryValue = Color(0xFFFFFFFF);

  /// Значение `accent` для const-контекстов.
  static const accentValue = Color(0xFF0A84FF);

  /// Оверлей наведения (белый 4 %).
  static const stateHover = Color(0x0AFFFFFF);

  /// Оверлей нажатия (белый 8 %).
  static const statePressed = Color(0x14FFFFFF);

  /// Оверлей выбранного (белый 12 %).
  static const stateSelected = Color(0x1FFFFFFF);

  /// Затемнение под модальным окном (чёрный 60 %).
  static const scrim = Color(0x99000000);

  /// Ряды графиков (2.1.7), не больше четырёх, порядок фиксирован: акцент,
  /// затем серые от светлого к тёмному. Ряды дополнительно различаются штрихом/заливкой.
  static const chartSeries = <Color>[
    accentValue,
    Color(0xFFE6E6E6),
    Color(0xFFA8A8A8),
    Color(0xFF808080),
  ];

  /// Серый «Прочее» для графиков.
  static const chartOther = Color(0xFF656565);

  /// Шкала heatmap (уровни 0–4): от пустой ячейки до белой заливки.
  static const heat = <Color>[
    Color(0xFF1A1A1A),
    Color(0xFF3A3A3A),
    Color(0xFF6B6B6B),
    Color(0xFFA8A8A8),
    Color(0xFFE6E6E6),
  ];

  /// Токены неизменяемы: копия совпадает с оригиналом.
  @override
  AppColors copyWith() => this;

  /// Палитра одна (тёмная), интерполяция не требуется.
  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) =>
      other is AppColors && t >= 0.5 ? other : this;
}
