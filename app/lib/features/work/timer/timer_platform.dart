import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Что показать в системе, пока идёт таймер: Android — постоянное
/// уведомление с хронометром и кнопкой «Стоп», Windows — иконка в трее
/// (02, 4.11). Платформа получает только «что показывать», время считает
/// сама по [startedAt]: тикать из Dart в фоне не нужно, а запись времени
/// живёт в БД, поэтому таймер переживает закрытие приложения.
@immutable
class TimerNotice {
  const TimerNotice({
    required this.entryId,
    required this.title,
    required this.startedAt,
  });

  /// Запись `time_entries`, которую остановит кнопка «Стоп».
  final String entryId;

  /// Проект (или «проект · доработка»).
  final String title;

  /// Начало (UTC): от него платформа ведёт хронометр.
  final DateTime startedAt;

  @override
  bool operator ==(Object other) =>
      other is TimerNotice &&
      other.entryId == entryId &&
      other.title == title &&
      other.startedAt == startedAt;

  @override
  int get hashCode => Object.hash(entryId, title, startedAt);
}

/// Тонкая платформенная прослойка таймера. Реализации:
/// `createPlatformTimerNotifier` (Android — уведомление), «пустышка» —
/// Windows (трей не подключён, см. отчёт этапа) и тесты.
abstract interface class TimerPlatform {
  /// Показывает (или обновляет) индикатор идущего таймера.
  Future<void> show(TimerNotice notice);

  /// Убирает индикатор.
  Future<void> hide();
}

/// Ничего не показывает.
class NoTimerPlatform implements TimerPlatform {
  const NoTimerPlatform();

  @override
  Future<void> show(TimerNotice notice) async {}

  @override
  Future<void> hide() async {}
}

/// Шина запросов «Стоп» из системы (кнопка уведомления, меню трея):
/// платформа кладёт id записи, приложение останавливает таймер.
class TimerActions {
  final StreamController<String> _stops = StreamController<String>.broadcast();

  Stream<String> get stops => _stops.stream;

  void requestStop(String entryId) => _stops.add(entryId);

  Future<void> dispose() => _stops.close();
}

/// Платформа таймера; в `main.dart` подменяется настоящей.
final timerPlatformProvider = Provider<TimerPlatform>(
  (ref) => const NoTimerPlatform(),
);

final timerActionsProvider = Provider<TimerActions>((ref) {
  final actions = TimerActions();
  ref.onDispose(() => unawaited(actions.dispose()));
  return actions;
});
