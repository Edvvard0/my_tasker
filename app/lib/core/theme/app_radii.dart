import 'package:flutter/painting.dart';

/// Радиусы скругления (02, раздел 2.4): крупные, как в референсе.
abstract final class AppRadii {
  static const double xs = 6;
  static const double s = 10;
  static const double m = 16;

  /// Карточки.
  static const double l = 24;

  /// Bottom sheet и модальные окна.
  static const double xl = 32;
  static const double full = 999;

  static const borderXs = BorderRadius.all(Radius.circular(xs));
  static const borderS = BorderRadius.all(Radius.circular(s));
  static const borderM = BorderRadius.all(Radius.circular(m));
  static const borderL = BorderRadius.all(Radius.circular(l));
  static const borderXl = BorderRadius.all(Radius.circular(xl));
  static const borderFull = BorderRadius.all(Radius.circular(full));
}
