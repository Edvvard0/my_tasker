import 'package:flutter/material.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_colors.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_typography.dart';

/// Сборка [ThemeData] из дизайн-токенов. Тёмная тема — основная.
abstract final class AppTheme {
  static final ThemeData _mobile = _build(
    AppTextStyles.mobile(),
    desktop: false,
  );
  static final ThemeData _desktop = _build(
    AppTextStyles.desktop(),
    desktop: true,
  );

  /// Тёмная тема для заданного класса ширины (влияет на шкалу шрифтов).
  static ThemeData dark([WindowClass windowClass = WindowClass.compact]) =>
      windowClass.isDesktopScale ? _desktop : _mobile;

  /// Размеры по 02, 2.3: кнопка 48 (телефон) / 36 (десктоп), поле ввода
  /// 52 / 40. [desktop] выбирает набор.
  static ThemeData _build(AppTextStyles text, {required bool desktop}) {
    final buttonHeight = desktop ? 36.0 : 48.0;
    final fieldPadding = desktop ? 10.0 : 15.0;
    final tapTarget = desktop
        ? MaterialTapTargetSize.shrinkWrap
        : MaterialTapTargetSize.padded;
    // Фокус клавиатуры кнопок: обводка 2 px акцента.
    final focusSide = WidgetStateProperty.resolveWith<BorderSide?>(
      (states) => states.contains(WidgetState.focused)
          ? BorderSide(color: AppColors.dark.borderFocus, width: 2)
          : null,
    );
    const c = AppColors.dark;
    final scheme = ColorScheme.dark(
      primary: c.accent,
      onPrimary: c.textOnAccent,
      secondary: c.accent,
      onSecondary: c.textOnAccent,
      error: c.danger,
      onError: c.textOnInverse,
      surface: c.surface1,
      onSurface: c.textPrimary,
      onSurfaceVariant: c.textSecondary,
      surfaceContainerLowest: c.bgBase,
      surfaceContainerLow: c.surface1,
      surfaceContainer: c.surface2,
      surfaceContainerHigh: c.surface3,
      surfaceContainerHighest: c.surface3,
      outline: c.borderStrong,
      outlineVariant: c.borderDefault,
      inverseSurface: c.surfaceInverse,
      onInverseSurface: c.textOnInverse,
    );

    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: AppRadii.borderS,
          borderSide: BorderSide(color: color, width: width),
        );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: c.bgBase,
      canvasColor: c.bgBase,
      fontFamily: AppFonts.sans,
      textTheme: text.toTextTheme(),
      primaryTextTheme: text.toTextTheme(),
      extensions: [c, text],
      splashFactory: InkRipple.splashFactory,
      dividerTheme: DividerThemeData(
        color: c.borderSubtle,
        thickness: 1,
        space: 1,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: c.bgBase,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: text.h1,
      ),
      cardTheme: CardThemeData(
        color: c.surface1,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadii.borderL,
          side: BorderSide(color: c.borderDefault),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        isDense: true,
        // Высота поля 02, 2.3: 52 на телефоне, 40 на десктопе.
        constraints: BoxConstraints(minHeight: desktop ? 40 : 52),
        fillColor: c.surface3,
        hintStyle: text.body.copyWith(color: c.textTertiary),
        errorStyle: text.bodyS.copyWith(color: c.danger),
        contentPadding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: fieldPadding,
        ),
        border: border(Colors.transparent),
        enabledBorder: border(Colors.transparent),
        hoverColor: AppColors.stateHover,
        // Кольцо фокуса рисует AppTextField снаружи (2 px + зазор 2 px).
        focusedBorder: border(Colors.transparent),
        errorBorder: border(c.borderDanger),
        focusedErrorBorder: border(c.borderDanger),
        disabledBorder: border(Colors.transparent),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: c.textOnAccent,
          disabledBackgroundColor: c.surface3,
          disabledForegroundColor: c.textDisabled,
          minimumSize: Size(64, buttonHeight),
          tapTargetSize: tapTarget,
          textStyle: text.label.copyWith(fontWeight: FontWeight.w600),
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.borderM),
        ).copyWith(side: focusSide),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: c.surface3,
          foregroundColor: c.textPrimary,
          disabledBackgroundColor: c.surface3,
          disabledForegroundColor: c.textDisabled,
          elevation: 0,
          minimumSize: Size(64, buttonHeight),
          tapTargetSize: tapTarget,
          textStyle: text.label,
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.borderM),
        ).copyWith(side: focusSide),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.textPrimary,
          side: BorderSide(color: c.borderStrong),
          minimumSize: Size(64, buttonHeight),
          tapTargetSize: tapTarget,
          textStyle: text.label,
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.borderM),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.accent,
          textStyle: text.label,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.surfaceInverse,
        contentTextStyle: text.body.copyWith(color: c.textOnInverse),
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.borderM),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface2,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: AppColors.scrim,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadii.xl),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surface2,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          // Мобильные модальные окна — radius/xl (28), десктоп — radius/l (20).
          borderRadius: desktop ? AppRadii.borderL : AppRadii.borderXl,
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: AppRadii.borderS,
        ),
        textStyle: text.bodyS,
      ),
    );
  }
}

/// Доступ к токенам из [BuildContext].
extension AppThemeContext on BuildContext {
  /// Цветовые токены.
  AppColors get colors => Theme.of(this).extension<AppColors>()!;

  /// Шкала текстовых стилей.
  AppTextStyles get text => Theme.of(this).extension<AppTextStyles>()!;
}
