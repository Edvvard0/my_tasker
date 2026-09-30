import 'package:connectivity_plus/connectivity_plus.dart';

/// Наличие сети. Реализация по умолчанию — `connectivity_plus`; тесты
/// подставляют управляемую.
abstract interface class ConnectivityMonitor {
  /// Есть ли сетевое подключение (не гарантирует доступ к серверу).
  Future<bool> isOnline();

  /// Изменения: `true` — появилось подключение.
  Stream<bool> get onlineChanges;
}

/// Платформенная реализация.
// Тонкая обёртка над плагином: в тестах плагина нет.
// coverage:ignore-start
class PlatformConnectivityMonitor implements ConnectivityMonitor {
  PlatformConnectivityMonitor([Connectivity? connectivity])
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  static bool _online(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  @override
  Future<bool> isOnline() async {
    try {
      return _online(await _connectivity.checkConnectivity());
    } on Object {
      // Не удалось узнать состояние сети — считаем, что сеть есть: об
      // обрывах всё равно сообщит сам запрос к серверу.
      return true;
    }
  }

  @override
  Stream<bool> get onlineChanges => _connectivity.onConnectivityChanged
      .map(_online)
      .distinct()
      .handleError((Object _) {});
}
// coverage:ignore-end
