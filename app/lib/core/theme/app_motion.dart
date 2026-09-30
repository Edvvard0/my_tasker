import 'package:flutter/animation.dart';

/// Длительности и кривые анимаций (02, раздел 2.7).
abstract final class AppMotion {
  static const instant = Duration(milliseconds: 80);
  static const fast = Duration(milliseconds: 150);
  static const base = Duration(milliseconds: 220);
  static const enter = Duration(milliseconds: 300);
  static const exit = Duration(milliseconds: 200);

  static const standard = Cubic(0.2, 0, 0, 1);
  static const decelerate = Cubic(0.05, 0.7, 0.1, 1);
  static const accelerate = Cubic(0.3, 0, 0.8, 0.15);
}
