import 'dart:async';

import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/core/sync/connectivity_monitor.dart';

/// Управляемая сеть для тестов.
class FakeConnectivity implements ConnectivityMonitor {
  FakeConnectivity({this.online = true});

  final StreamController<bool> controller = StreamController<bool>.broadcast();
  bool online;

  @override
  Future<bool> isOnline() async => online;

  @override
  Stream<bool> get onlineChanges => controller.stream;

  void set({required bool value}) {
    online = value;
    controller.add(value);
  }
}

/// Готовая сессия входа для тестов интерфейса.
AuthSession fakeSession({
  String deviceId = '0195f2a0-0000-7000-8000-00000000000a',
}) => AuthSession(
  deviceId: deviceId,
  accessToken: 'at-fake',
  accessExpiresAt: DateTime.utc(2100),
  refreshToken: 'rt-fake',
  refreshExpiresAt: DateTime.utc(2100),
);
