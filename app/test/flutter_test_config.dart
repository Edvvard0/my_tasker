import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';

import 'support/fonts.dart';
import 'support/golden_comparator.dart';

/// Общая настройка всех тестов: настоящие шрифты + допуск golden-сравнения.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Тесты синхронизации поднимают по нескольку БД в памяти (устройства).
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  await loadAppFonts();
  installTolerantGoldenComparator();
  await testMain();
}
