import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/network/connection_checker.dart';
import 'package:my_tasker/features/settings/data/server_connection_repository.dart';

/// Сохранённые настройки сервера (читаются из локальной БД).
final serverConnectionSettingsProvider =
    FutureProvider<ServerConnectionSettings>(
      (ref) => ref.watch(serverConnectionRepositoryProvider).load(),
    );

/// Состояние проверки соединения на экране настроек сервера.
@immutable
sealed class ConnectionCheckState {
  const ConnectionCheckState();
}

/// Проверка ещё не запускалась.
final class ConnectionIdle extends ConnectionCheckState {
  const ConnectionIdle();
}

/// Идёт запрос `GET /health/ready`.
final class ConnectionChecking extends ConnectionCheckState {
  const ConnectionChecking();
}

/// Проверка завершена.
final class ConnectionDone extends ConnectionCheckState {
  const ConnectionDone(this.result);

  final ConnectionResult result;
}

class ConnectionCheckNotifier extends Notifier<ConnectionCheckState> {
  @override
  ConnectionCheckState build() => const ConnectionIdle();

  /// Запускает проверку; повторный запуск во время проверки игнорируется.
  Future<void> check({required String url, required String? caPem}) async {
    if (state is ConnectionChecking) return;
    state = const ConnectionChecking();
    final result = await ref
        .read(connectionCheckerProvider)
        .check(url: url, caPem: caPem);
    state = ConnectionDone(result);
  }

  void reset() => state = const ConnectionIdle();
}

final connectionCheckProvider =
    NotifierProvider<ConnectionCheckNotifier, ConnectionCheckState>(
      ConnectionCheckNotifier.new,
    );
