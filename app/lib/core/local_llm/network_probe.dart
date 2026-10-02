import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// Тип текущего подключения (важно только для политики «модель — по Wi-Fi»).
enum NetworkKind {
  none,
  wifi,
  ethernet,

  /// Мобильная сеть (платный трафик).
  cellular,

  /// VPN, Bluetooth и т. п.: тип нижележащей сети неизвестен.
  other;

  /// Неограниченный (бесплатный) трафик: Wi-Fi или кабель.
  bool get isUnmetered => this == wifi || this == ethernet;

  bool get isOnline => this != none;
}

/// Тип подключения. Реализация по умолчанию — `connectivity_plus`.
abstract interface class NetworkProbe {
  Future<NetworkKind> current();

  Stream<NetworkKind> get changes;
}

/// Самый «дешёвый» вид из списка активных подключений.
NetworkKind networkKindOf(List<ConnectivityResult> results) {
  if (results.contains(ConnectivityResult.wifi)) return NetworkKind.wifi;
  if (results.contains(ConnectivityResult.ethernet)) {
    return NetworkKind.ethernet;
  }
  if (results.contains(ConnectivityResult.mobile)) return NetworkKind.cellular;
  if (results.every((r) => r == ConnectivityResult.none)) {
    return NetworkKind.none;
  }
  return NetworkKind.other;
}

/// Платформенная реализация.
// Тонкая обёртка над плагином: в тестах плагина нет.
// coverage:ignore-start
class PlatformNetworkProbe implements NetworkProbe {
  PlatformNetworkProbe([Connectivity? connectivity])
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Future<NetworkKind> current() async {
    try {
      return networkKindOf(await _connectivity.checkConnectivity());
    } on Object {
      // Не удалось узнать: считаем сеть неизвестной (не Wi-Fi), чтобы не
      // качать гигабайты по платному каналу.
      return NetworkKind.other;
    }
  }

  @override
  Stream<NetworkKind> get changes => _connectivity.onConnectivityChanged
      .map(networkKindOf)
      .distinct()
      .handleError((Object _) {});
}
// coverage:ignore-end
