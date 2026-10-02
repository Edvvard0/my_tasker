import 'dart:async';

/// Выгружает модель из памяти после паузы без запросов.
///
/// Gemma 4 E2B держит около 3 ГБ ОЗУ: если пользователь закончил чат, телефон
/// не должен хранить её сколько угодно. [touch] (начало и конец каждого
/// ответа) сбрасывает таймер, по истечении [after] вызывается [unload].
class IdleUnloader {
  IdleUnloader({required this.unload, this.after = const Duration(minutes: 5)});

  final Future<void> Function() unload;
  final Duration after;
  Timer? _timer;

  /// Есть активность: отсчёт начинается заново.
  void touch() {
    _timer?.cancel();
    _timer = Timer(after, () => unawaited(unload()));
  }

  /// Идёт работа (генерация): таймер остановлен до следующего [touch].
  void hold() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => hold();
}
