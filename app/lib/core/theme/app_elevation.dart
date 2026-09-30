import 'package:flutter/painting.dart';
import 'package:my_tasker/core/theme/app_colors.dart';

/// Глубина: поверхность + обводка, тень только у плавающих элементов
/// (02, раздел 2.5).
abstract final class AppElevation {
  /// `shadow/2`: смещение 0/4, размытие 16, чёрный 40 %.
  static const shadow2 = BoxShadow(
    color: Color(0x66000000),
    offset: Offset(0, 4),
    blurRadius: 16,
  );

  /// `shadow/3`: смещение 0/8, размытие 32, чёрный 55 %.
  static const shadow3 = BoxShadow(
    color: Color(0x8C000000),
    offset: Offset(0, 8),
    blurRadius: 32,
  );

  /// `elev/1`: карточки — `surface/1` + обводка 1 px `border/default`.
  static BoxDecoration card(AppColors c, {BorderRadius? radius}) =>
      BoxDecoration(
        color: c.surface1,
        borderRadius: radius ?? BorderRadius.circular(20),
        border: Border.all(color: c.borderDefault),
      );

  /// `elev/2`: bottom sheet, левая панель, диалоги.
  static BoxDecoration raised(AppColors c, {BorderRadius? radius}) =>
      BoxDecoration(
        color: c.surface2,
        borderRadius: radius,
        border: Border.all(color: const Color(0x0FFFFFFF)),
        boxShadow: const [shadow2],
      );

  /// `elev/3`: плавающий таб-бар, «+», меню, поповеры.
  static BoxDecoration floating(AppColors c, {BorderRadius? radius}) =>
      BoxDecoration(
        color: c.surface2,
        borderRadius: radius,
        border: Border.all(color: const Color(0x14FFFFFF)),
        boxShadow: const [shadow3],
      );
}
