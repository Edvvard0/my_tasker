import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/features/monitoring/data/monitoring_api.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_models.dart';

import '../../support/monitoring_env.dart';

/// Адаптер: записывает запросы и отвечает по очереди заготовленными ответами.
class _Adapter implements HttpClientAdapter {
  _Adapter(this.responses);

  final List<({int status, Object? body, Map<String, String> headers})>
  responses;
  final List<RequestOptions> requests = [];
  DioException Function(RequestOptions)? fail;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (fail != null) throw fail!(options);
    final r = responses[(requests.length - 1).clamp(0, responses.length - 1)];
    return ResponseBody.fromString(
      r.body == null ? '' : jsonEncode(r.body),
      r.status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        for (final e in r.headers.entries) e.key: [e.value],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

({int status, Object? body, Map<String, String> headers}) _ok(
  Object? body, {
  Map<String, String> headers = const {},
  int status = 200,
}) => (status: status, body: body, headers: headers);

HttpMonitoringApi _api(_Adapter adapter) => HttpMonitoringApi(
  () async => ApiClient(
    dio: ApiClient.createDio(
      baseUrl: Uri.parse('https://tasker.test'),
      adapter: adapter,
    ),
    schemaVersion: 1,
  ),
);

Map<String, Object?> _snapshot() => pulseBody(
  services: [
    pulseService(
      id: 's1',
      name: 'Сайт',
      status: 'down',
      downSince: '2026-10-05T11:28:00Z',
    ),
  ],
);

void main() {
  group('GET /monitoring/pulse: ETag и 304', () {
    test('200: снимок, ETag и сырое тело для кэша', () async {
      final adapter = _Adapter([
        _ok(_snapshot(), headers: {'etag': '"abc"'}),
      ]);
      final fetch = await _api(adapter).pulse();
      expect(fetch.isNotModified, isFalse);
      expect(fetch.etag, '"abc"');
      expect(fetch.snapshot!.services.single.name, 'Сайт');
      expect(fetch.raw!['generated_at'], '2026-10-05T11:40:00Z');
      expect(adapter.requests.single.path, '/monitoring/pulse');
      expect(
        adapter.requests.single.headers.containsKey('If-None-Match'),
        isFalse,
      );
      expect(adapter.requests.single.headers['X-Client-Schema-Version'], '1');
    });

    test('If-None-Match уходит с известным тегом, 304 — не ошибка', () async {
      final adapter = _Adapter([
        _ok(null, status: 304, headers: {'etag': '"abc"'}),
      ]);
      final fetch = await _api(adapter).pulse(etag: '"abc"');
      expect(fetch.isNotModified, isTrue);
      expect(fetch.snapshot, isNull);
      expect(adapter.requests.single.headers['If-None-Match'], '"abc"');
    });

    test('«Проверить сейчас» — POST, ответ — снимок без тега', () async {
      final adapter = _Adapter([_ok(_snapshot())]);
      final fetch = await _api(adapter).refresh();
      expect(adapter.requests.single.method, 'POST');
      expect(adapter.requests.single.path, '/monitoring/refresh');
      expect(fetch.etag, isNull);
      expect(fetch.snapshot!.down, 1);
    });
  });

  group('инциденты, самопроверка, Telegram', () {
    test(
      'страница инцидентов: составной курсор и фильтр уходят параметрами',
      () async {
        final adapter = _Adapter([
          _ok({
            'incidents': [
              incidentJson(id: 'i1', startedAt: '2026-10-05T10:00:00Z'),
            ],
            'next_before': '2026-10-05T10:00:00Z',
            'next_before_id': 'i1',
          }),
        ]);
        final page = await _api(adapter).incidents(
          limit: 20,
          cursor: const IncidentCursor('2026-10-05T11:00:00Z', 'i0'),
          serviceId: 'svc-1',
        );
        expect(adapter.requests.single.queryParameters, {
          'limit': 20,
          'before': '2026-10-05T11:00:00Z',
          'before_id': 'i0',
          'service_id': 'svc-1',
        });
        expect(page.next, const IncidentCursor('2026-10-05T10:00:00Z', 'i1'));
      },
    );

    test('первая страница без курсора и без фильтра', () async {
      final adapter = _Adapter([
        _ok({'incidents': <Object?>[]}),
      ]);
      final page = await _api(adapter).incidents();
      expect(adapter.requests.single.queryParameters, {'limit': 50});
      expect(page.incidents, isEmpty);
      expect(page.next, isNull);
    });

    test('самопроверка и тест Telegram', () async {
      final adapter = _Adapter([
        _ok({
          'engine': {'configured': true},
          'config': {'checks_active': 3},
          'telegram': {'configured': true, 'queued': 1},
        }),
        _ok({'ok': false, 'error': 'rate_limited'}),
      ]);
      final api = _api(adapter);
      final self = await api.selfCheck();
      expect(self.checksActive, 3);
      expect(self.queued, 1);
      final test = await api.telegramTest();
      expect(test.ok, isFalse);
      expect(test.error, 'rate_limited');
      expect(adapter.requests.map((r) => '${r.method} ${r.path}'), [
        'GET /monitoring/self-check',
        'POST /monitoring/telegram/test',
      ]);
    });
  });

  group('ошибки', () {
    test('нет клиента (сервер не настроен) — notConfigured', () async {
      final api = HttpMonitoringApi(() async => null);
      await expectLater(
        api.pulse(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.notConfigured,
          ),
        ),
      );
      await expectLater(api.refresh(), throwsA(isA<ApiException>()));
      await expectLater(api.incidents(), throwsA(isA<ApiException>()));
      await expectLater(api.selfCheck(), throwsA(isA<ApiException>()));
      await expectLater(api.telegramTest(), throwsA(isA<ApiException>()));
    });

    test('обрыв соединения — сетевая ошибка', () async {
      final adapter = _Adapter([_ok(null)])
        ..fail = (o) =>
            DioException.connectionError(requestOptions: o, reason: 'x');
      await expectLater(
        _api(adapter).pulse(),
        throwsA(
          isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', isTrue),
        ),
      );
    });

    test(
      '429 с Retry-After и 503 monitoring_not_configured разбираются',
      () async {
        final adapter = _Adapter([
          _ok(
            {
              'error': {'code': 'rate_limited', 'message': 'slow down'},
            },
            status: 429,
            headers: {'retry-after': '7'},
          ),
          _ok({
            'error': {'code': 'monitoring_not_configured', 'message': 'x'},
          }, status: 503),
        ]);
        final api = _api(adapter);
        await expectLater(
          api.refresh(),
          throwsA(
            isA<ApiException>()
                .having((e) => e.status, 'status', 429)
                .having(
                  (e) => e.retryAfter,
                  'retryAfter',
                  const Duration(seconds: 7),
                ),
          ),
        );
        await expectLater(
          api.refresh(),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              'monitoring_not_configured',
            ),
          ),
        );
      },
    );

    test('тексты ошибок для человека', () {
      expect(monitoringErrorText(offlineError), 'Нет связи с сервером.');
      expect(
        monitoringErrorText(const ApiException.notConfigured()),
        contains('Сервер не настроен'),
      );
      expect(
        monitoringErrorText(rateLimitError()),
        'Слишком часто. Повторите через 7 с.',
      );
      expect(
        monitoringErrorText(
          const ApiException(kind: ApiErrorKind.http, status: 429),
        ),
        'Слишком часто. Повторите чуть позже.',
      );
      expect(
        monitoringErrorText(notConfiguredError),
        contains('нет движка проверок'),
      );
      expect(
        monitoringErrorText(
          const ApiException(
            kind: ApiErrorKind.http,
            status: 401,
            code: 'token_expired',
          ),
        ),
        'Нужно войти заново.',
      );
      expect(
        monitoringErrorText(
          const ApiException(kind: ApiErrorKind.http, status: 500, code: 'x'),
        ),
        contains('Сервер ответил ошибкой'),
      );
      expect(
        monitoringErrorText(
          const ApiException(kind: ApiErrorKind.http, status: 400, code: 'x'),
        ),
        contains('Не удалось получить данные'),
      );
      expect(
        monitoringErrorText(StateError('x')),
        contains('Не удалось получить данные'),
      );
    });
  });
}
