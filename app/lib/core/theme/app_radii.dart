import 'package:flutter/painting.dart';

/// Радиусы скругления (02, раздел 2.4).
abstract final class AppRadii {
  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 20;
  static const double xl = 28;
  static const double full = 999;

  static const borderXs = BorderRadius.all(Radius.circular(xs));
  static const borderS = BorderRadius.all(Radius.circular(s));
  static const borderM = BorderRadius.all(Radius.circular(m));
  static const borderL = BorderRadius.all(Radius.circular(l));
  static const borderXl = BorderRadius.all(Radius.circular(xl));
  static const borderFull = BorderRadius.all(Radius.circular(full));
}
