import 'dart:async';

import 'package:my_tasker/core/config/app_config.dart';
import 'package:my_tasker/core/network/connection_checker.dart';

/// Проверка соединения для виджет-тестов: возвращает заданный результат,
/// опционально ждёт [gate] (чтобы поймать состояние «проверяем»).
class FakeConnectionChecker extends ConnectionChecker {
  FakeConnectionChecker(this.result, {this.gate})
    : super(config: const AppConfig(allowInsecureLocalhost: false));

  ConnectionResult result;
  final Completer<void>? gate;
  final calls = <({String url, String? caPem})>[];

  @override
  Future<ConnectionResult> check({
    required String url,
    required String? caPem,
  }) async {
    calls.add((url: url, caPem: caPem));
    if (gate != null) await gate!.future;
    return result;
  }
}
