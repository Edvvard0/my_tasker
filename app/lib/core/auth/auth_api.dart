import 'package:my_tasker/core/auth/auth_models.dart';
import 'package:my_tasker/core/network/api_client.dart';

/// Эндпоинты аккаунта: вход, обновление токена, выход, устройства
/// (spec 1).
class AuthApi {
  AuthApi(this._client);

  final ApiClient _client;

  /// `POST /auth/login`. Каждый вход создаёт новое устройство.
  Future<AuthSession> login({
    required String password,
    required String totpCode,
    required DeviceInfo device,
  }) async {
    final json = await _client.postJson(
      '/auth/login',
      auth: false,
      body: {
        'password': password,
        'totp_code': totpCode,
        'device': device.toJson(),
      },
    );
    return _session(json);
  }

  /// `POST /auth/refresh`: новый access **и новый refresh**; старый refresh
  /// перестаёт действовать сразу.
  Future<AuthSession> refresh(String refreshToken) async {
    final json = await _client.postJson(
      '/auth/refresh',
      auth: false,
      body: {'refresh_token': refreshToken},
    );
    return _session(json);
  }

  /// `POST /auth/logout`: отзывает текущее устройство.
  Future<void> logout() => _client.send('POST', '/auth/logout');

  /// `GET /auth/devices`.
  Future<List<RegisteredDevice>> devices({bool includeRevoked = false}) async {
    final json = await _client.getJson(
      '/auth/devices',
      query: {if (includeRevoked) 'include_revoked': 'true'},
    );
    final list = json['devices'];
    if (list is! List) {
      throw const ApiException(kind: ApiErrorKind.malformed);
    }
    return [
      for (final d in list)
        RegisteredDevice.fromJson((d! as Map).cast<String, Object?>()),
    ];
  }

  /// `DELETE /auth/devices/{id}`: идемпотентно; `404 device_not_found`.
  Future<void> revokeDevice(String id) =>
      _client.send('DELETE', '/auth/devices/$id');

  AuthSession _session(Map<String, Object?> json) {
    try {
      return AuthSession.fromJson(json);
    } on Object {
      throw const ApiException(kind: ApiErrorKind.malformed);
    }
  }
}
