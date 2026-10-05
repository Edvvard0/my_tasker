import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/core/db/local_settings_repository.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_models.dart';

/// Последний успешный снимок «Пульса» с его `ETag` и моментом, на который он
/// актуален.
class CachedPulse {
  const CachedPulse({
    required this.snapshot,
    required this.asOf,
    required this.raw,
    this.etag,
  });

  final PulseSnapshot snapshot;
  final Map<String, Object?> raw;
  final String? etag;

  /// Когда данные были получены (часы устройства): `200` — момент ответа,
  /// `304` — момент, когда сервер подтвердил, что снимок не изменился.
  final DateTime asOf;
}

/// Последняя загруженная первая страница инцидентов (без фильтра).
class CachedIncidents {
  const CachedIncidents({required this.page, required this.asOf});

  final IncidentPage page;
  final DateTime asOf;
}

/// Офлайн-кэш «Пульса» (spec `stage9_monitoring.md`, раздел 8): последний
/// снимок целиком и первая страница инцидентов лежат в `local_settings`
/// (локально, не синхронизируется, миграции схемы не нужно). Без сети экран
/// показывает их с подписью «Данные на 14:32 · нет сети». Повреждённая запись
/// читается как «кэша нет».
class PulseCache {
  PulseCache(this._settings);

  final LocalSettingsRepository _settings;

  static const String pulseKey = 'monitoring.pulse_cache';
  static const String incidentsKey = 'monitoring.incidents_cache';

  Future<CachedPulse?> readPulse() async {
    try {
      final text = await _settings.read(pulseKey);
      if (text == null) return null;
      final json = (jsonDecode(text) as Map).cast<String, Object?>();
      final raw = (json['snapshot']! as Map).cast<String, Object?>();
      final asOf = DateTime.tryParse(json['as_of']! as String);
      if (asOf == null) return null;
      return CachedPulse(
        snapshot: PulseSnapshot.fromJson(raw),
        raw: raw,
        etag: json['etag'] as String?,
        asOf: asOf.toUtc(),
      );
    } on Object {
      return null;
    }
  }

  Future<void> writePulse({
    required Map<String, Object?> raw,
    required DateTime asOf,
    String? etag,
  }) => _settings.write(
    pulseKey,
    jsonEncode({
      'etag': etag,
      'as_of': asOf.toUtc().toIso8601String(),
      'snapshot': raw,
    }),
  );

  /// Сервер подтвердил (`304`), что кэшированный снимок актуален.
  Future<void> touchPulse(DateTime asOf) async {
    final current = await readPulse();
    if (current == null) return;
    await writePulse(raw: current.raw, asOf: asOf, etag: current.etag);
  }

  Future<CachedIncidents?> readIncidents() async {
    try {
      final text = await _settings.read(incidentsKey);
      if (text == null) return null;
      final json = (jsonDecode(text) as Map).cast<String, Object?>();
      final asOf = DateTime.tryParse(json['as_of']! as String);
      if (asOf == null) return null;
      return CachedIncidents(
        page: IncidentPage.fromJson(
          (json['page']! as Map).cast<String, Object?>(),
        ),
        asOf: asOf.toUtc(),
      );
    } on Object {
      return null;
    }
  }

  Future<void> writeIncidents(IncidentPage page, DateTime asOf) =>
      _settings.write(
        incidentsKey,
        jsonEncode({
          'as_of': asOf.toUtc().toIso8601String(),
          'page': page.toJson(),
        }),
      );
}

final Provider<PulseCache> pulseCacheProvider = Provider<PulseCache>(
  (ref) => PulseCache(ref.watch(localSettingsRepositoryProvider)),
);
