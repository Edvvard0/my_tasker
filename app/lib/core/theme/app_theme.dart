import 'package:flutter/material.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_colors.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_typography.dart';

/// Сборка [ThemeData] из дизайн-токенов. Тёмная тема — основная.
abstract final class AppTheme {
  static final ThemeData _mobile = _build(AppTextStyles.mobile());
  static final ThemeData _desktop = _build(AppTextStyles.desktop());

  /// Тёмная тема для заданного класса ширины (влияет на шкалу шрифтов).
  static ThemeData dark([WindowClass windowClass = WindowClass.compact]) =>
      windowClass.isDesktopScale ? _desktop : _mobile;

  static ThemeData _build(AppTextStyles text) {
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
        fillColor: c.surface3,
        hintStyle: text.body.copyWith(color: c.textTertiary),
        errorStyle: text.bodyS.copyWith(color: c.danger),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 15,
        ),
        border: border(Colors.transparent),
        enabledBorder: border(Colors.transparent),
        hoverColor: AppColors.stateHover,
        focusedBorder: border(c.borderFocus, 2),
        errorBorder: border(c.borderDanger),
        focusedErrorBorder: border(c.borderDanger, 2),
        disabledBorder: border(Colors.transparent),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: c.textOnAccent,
          disabledBackgroundColor: c.surface3,
          disabledForegroundColor: c.textDisabled,
          minimumSize: const Size(64, 48),
          textStyle: text.label.copyWith(fontWeight: FontWeight.w600),
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.borderM),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: c.surface3,
          foregroundColor: c.textPrimary,
          disabledBackgroundColor: c.surface3,
          disabledForegroundColor: c.textDisabled,
          elevation: 0,
          minimumSize: const Size(64, 48),
          textStyle: text.label,
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.borderM),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.textPrimary,
          side: BorderSide(color: c.borderStrong),
          minimumSize: const Size(64, 48),
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
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.borderL),
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
