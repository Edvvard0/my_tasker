import 'package:flutter/widgets.dart';

/// Класс ширины окна (02, раздел 2.3, «Брейкпоинты и раскладка»).
enum WindowClass {
  /// < 600 — телефон: плавающий таб-бар снизу + «+».
  compact,

  /// 600–1023 — узкое окно десктопа: рейл 72 px слева.
  medium,

  /// 1024–1439 — обычное окно: левая панель 256 px.
  expanded,

  /// ≥ 1440 — развёрнутое окно: левая панель 256 px (+ панель ИИ позже).
  large;

  static const double mediumFrom = 600;
  static const double expandedFrom = 1024;
  static const double largeFrom = 1440;

  static WindowClass fromWidth(double width) {
    if (width < mediumFrom) return compact;
    if (width < expandedFrom) return medium;
    if (width < largeFrom) return expanded;
    return large;
  }

  bool get isCompact => this == compact;

  /// Десктопная шкала типографики (все классы, кроме compact).
  bool get isDesktopScale => !isCompact;

  /// Поля экрана (gutter) по классу ширины.
  double get gutter => switch (this) {
    compact => 16,
    medium || expanded => 24,
    large => 32,
  };

  /// Высота верхней панели: 56 на телефоне, 64 на десктопе.
  double get topBarHeight => isCompact ? 56 : 64;
}

extension WindowClassContext on BuildContext {
  /// Класс ширины по текущему [MediaQuery].
  WindowClass get windowClass =>
      WindowClass.fromWidth(MediaQuery.sizeOf(this).width);
}
