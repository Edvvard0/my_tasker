import 'package:flutter/painting.dart';

/// Шкала отступов (02, раздел 2.3). Основной шаг 8, кратно 4.
abstract final class AppSpacing {
  /// `space/0.5`
  static const double s05 = 2;

  /// `space/1`
  static const double s1 = 4;

  /// `space/2`
  static const double s2 = 8;

  /// `space/3`
  static const double s3 = 12;

  /// `space/4`
  static const double s4 = 16;

  /// `space/5`
  static const double s5 = 20;

  /// `space/6`
  static const double s6 = 24;

  /// `space/8`
  static const double s8 = 32;

  /// `space/12`
  static const double s12 = 48;

  /// Отступ под плавающий таб-бар и «+» (contенt не прячется под ними):
  /// высота таб-бара 64 + отступ снизу 12 + запас `space/12`.
  static const double floatingBarInset = 64 + 12 + s12;

  /// Поля экрана по классу ширины: Compact 16, Medium/Expanded 24, Large 32.
  static const double gutterCompact = s4;
  static const double gutterMedium = s6;
  static const double gutterLarge = s8;

  /// Высоты ключевых элементов (mobile / desktop).
  static const double topBarMobile = 56;
  static const double topBarDesktop = 64;
  static const double tabBarHeight = 64;
  static const double fabSize = 56;
  static const double railWidth = 72;
  static const double sidePanelWidth = 256;

  static EdgeInsets all(double v) => EdgeInsets.all(v);
}
