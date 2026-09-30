import 'dart:async';

/// Взаимное исключение для асинхронного кода: задачи выполняются строго
/// по одной в порядке постановки.
class AsyncMutex {
  Future<void> _tail = Future<void>.value();
  int _waiting = 0;

  /// Выполняется ли сейчас задача или есть ожидающие.
  bool get isLocked => _waiting > 0;

  /// Выполняет [task], когда все предыдущие завершатся. Исключение задачи
  /// передаётся вызывающему и не блокирует следующие.
  Future<T> protect<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    final previous = _tail;
    _waiting++;
    _tail = completer.future.then<void>((_) {}, onError: (_) {});
    unawaited(
      previous.then((_) async {
        try {
          completer.complete(await task());
        } on Object catch (error, stack) {
          completer.completeError(error, stack);
        } finally {
          _waiting--;
        }
      }),
    );
    return completer.future;
  }
}
