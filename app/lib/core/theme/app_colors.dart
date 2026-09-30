import 'package:flutter/material.dart';

/// Цветовые токены тёмной темы (02_DESIGN_SYSTEM, раздел 2.1).
///
/// Имена токенов повторяют дизайн-систему: `bg/base` -> [bgBase] и т. д.
/// Светлая тема не входит в MVP, но токены собраны в один класс, чтобы её
/// можно было добавить второй константой.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.bgBase,
    required this.surface1,
    required this.surface2,
    required this.surface3,
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
    required this.textOnAccent,
    required this.textOnInverse,
    required this.accent,
    required this.accentHover,
    required this.accentPressed,
    required this.accentMuted,
    required this.accentMutedStrong,
    required this.success,
    required this.successMuted,
    required this.warning,
    required this.warningMuted,
    required this.danger,
    required this.dangerMuted,
    required this.info,
    required this.infoMuted,
    required this.moduleCalendar,
    required this.moduleWork,
    required this.moduleFinance,
    required this.moduleStudy,
    required this.moduleSleep,
    required this.moduleAi,
  });

  /// Тёмная тема — основная.
  static const dark = AppColors(
    bgBase: Color(0xFF0B0C0C),
    surface1: Color(0xFF141615),
    surface2: Color(0xFF1B1E1C),
    surface3: Color(0xFF232725),
    surfaceInverse: Color(0xFFEDEFEE),
    borderSubtle: Color(0xFF1F2321),
    borderDefault: Color(0xFF2A2E2C),
    borderStrong: Color(0xFF3A403C),
    borderFocus: Color(0xFF3BE08C),
    borderDanger: Color(0xFFFF6B6B),
    textPrimary: textPrimaryValue,
    textSecondary: Color(0xFFA3AAA6),
    textTertiary: Color(0xFF878F8A),
    textDisabled: Color(0xFF50564F),
    textOnAccent: Color(0xFF06150D),
    textOnInverse: Color(0xFF0B0C0C),
    accent: Color(0xFF3BE08C),
    accentHover: Color(0xFF62E6A3),
    accentPressed: Color(0xFF32BE77),
    accentMuted: Color(0xFF1A3628),
    accentMutedStrong: Color(0xFF1D4632),
    success: Color(0xFF3BE08C),
    successMuted: Color(0xFF1A3628),
    warning: Color(0xFFFFB547),
    warningMuted: Color(0xFF3A2F1D),
    danger: Color(0xFFFF6B6B),
    dangerMuted: Color(0xFF3A2423),
    info: Color(0xFF5AB0FF),
    infoMuted: Color(0xFF1F2F3A),
    moduleCalendar: Color(0xFF4CC9DC),
    moduleWork: Color(0xFF6E9CFF),
    moduleFinance: Color(0xFFE3BE5E),
    moduleStudy: Color(0xFFF08DB0),
    moduleSleep: Color(0xFFA08CFF),
    moduleAi: Color(0xFFF29B6B),
  );

  // Фоны и поверхности.
  final Color bgBase;
  final Color surface1;
  final Color surface2;
  final Color surface3;
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
  final Color textOnAccent;
  final Color textOnInverse;

  // Акцент.
  final Color accent;
  final Color accentHover;
  final Color accentPressed;
  final Color accentMuted;
  final Color accentMutedStrong;

  // Семантика.
  final Color success;
  final Color successMuted;
  final Color warning;
  final Color warningMuted;
  final Color danger;
  final Color dangerMuted;
  final Color info;
  final Color infoMuted;

  // Цвета модулей.
  final Color moduleCalendar;
  final Color moduleWork;
  final Color moduleFinance;
  final Color moduleStudy;
  final Color moduleSleep;
  final Color moduleAi;

  /// Значение `text/primary` для const-контекстов.
  static const textPrimaryValue = Color(0xFFEDEFEE);

  /// Оверлей наведения (белый 4 %).
  static const stateHover = Color(0x0AFFFFFF);

  /// Оверлей нажатия (белый 8 %).
  static const statePressed = Color(0x14FFFFFF);

  /// Оверлей выбранного (белый 12 %).
  static const stateSelected = Color(0x1FFFFFFF);

  /// Затемнение под модальным окном (чёрный 60 %).
  static const scrim = Color(0x99000000);

  /// Категориальная палитра графиков (2.1.7), порядок фиксирован.
  static const chartCategories = <Color>[
    Color(0xFF6E9CFF),
    Color(0xFFE3BE5E),
    Color(0xFFA08CFF),
    Color(0xFF4CC9DC),
    Color(0xFFF08DB0),
    Color(0xFFF29B6B),
  ];

  /// Серый «Прочее» для графиков.
  static const chartOther = Color(0xFF6B736E);

  /// Шкала heatmap (уровни 0–4).
  static const heat = <Color>[
    Color(0xFF1E2220),
    Color(0xFF15432B),
    Color(0xFF1F6E43),
    Color(0xFF2CA362),
    Color(0xFF3BE08C),
  ];

  /// Токены неизменяемы: копия совпадает с оригиналом.
  @override
  AppColors copyWith() => this;

  /// Палитра одна (тёмная), интерполяция не требуется.
  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) =>
      other is AppColors && t >= 0.5 ? other : this;
}
