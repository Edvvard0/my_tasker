import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/auth/auth_controller.dart';
import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/core/network/api_client.dart';

/// Показывать ли отозванные устройства (`?include_revoked=true`).
class ShowRevoked extends Notifier<bool> {
  @override
  bool build() => false;

  // Сеттер-подобный метод: `state = ...` снаружи Notifier недоступен.
  // ignore: use_setters_to_change_properties
  void set({required bool value}) => state = value;
}

final showRevokedDevicesProvider = NotifierProvider<ShowRevoked, bool>(
  ShowRevoked.new,
);

/// Список устройств с сервера (`GET /auth/devices`).
final FutureProvider<List<RegisteredDevice>> devicesProvider =
    FutureProvider.autoDispose<List<RegisteredDevice>>((ref) async {
      final api = ref.watch(authApiProvider);
      if (api == null) throw const ApiException.notConfigured();
      final include = ref.watch(showRevokedDevicesProvider);
      return await api.devices(includeRevoked: include);
    }, retry: (_, _) => null);
