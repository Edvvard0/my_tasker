import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'support/fonts.dart';
import 'support/golden_comparator.dart';

/// Общая настройка всех тестов: настоящие шрифты + допуск golden-сравнения.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadAppFonts();
  installTolerantGoldenComparator();
  await testMain();
}
