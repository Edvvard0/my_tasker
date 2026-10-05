import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/features/monitoring/application/monitoring_providers.dart';
import 'package:my_tasker/features/monitoring/data/monitoring_api.dart';
import 'package:my_tasker/features/monitoring/data/pulse_cache.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_models.dart';

import '../../support/in_memory_opener.dart';
import '../../support/monitoring_env.dart';

/// Сервер-подобный API инцидентов: новые первыми, курсор — пара
/// `(started_at, id)`; `before` без `before_id` — строго раньше момента.
class _PagingApi extends FakeMonitoringApi {
  _PagingApi(this.data);

  final List<Map<String, Object?>> data;
  int pageSize = 2;

  @override
  Future<IncidentPage> incidents({
    int limit = 50,
    IncidentCursor? cursor,
    String? serviceId,
  }) async {
    incidentCalls.add((cursor: cursor, serviceId: serviceId));
    final failure = error;
    if (failure != null) throw failure;
    final sorted =
        [
          for (final i in data)
            if (serviceId == null || i['service_id'] == serviceId) i,
        ]..sort((a, b) {
          final byTime = (b['started_at']! as String).compareTo(
            a['started_at']! as String,
          );
          return byTime != 0
              ? byTime
              : (b['id']! as String).compareTo(a['id']! as String);
        });
    final rest = cursor == null
        ? sorted
        : [
            for (final i in sorted)
              if ((i['started_at']! as String).compareTo(cursor.before) < 0 ||
                  ((i['started_at']! as String) == cursor.before &&
                      (i['id']! as String).compareTo(cursor.beforeId) < 0))
                i,
          ];
    final page = rest.take(pageSize).toList();
    final more = rest.length > pageSize;
    return incidentPage(
      page,
      nextBefore: more ? page.last['started_at']! as String : null,
      nextBeforeId: more ? page.last['id']! as String : null,
    );
  }
}

void main() {
  late DateTime now;
  late FakeMonitoringApi api;
  late ProviderContainer container;

  ProviderContainer make({Duration? poll, FakeMonitoringApi? fake}) {
    api = fake ?? api;
    final c = ProviderContainer(
      overrides: [
        databaseOpenerProvider.overrideWithValue(InMemoryDatabaseOpener()),
        monitoringApiProvider.overrideWithValue(api),
        clockProvider.overrideWithValue(() => now),
        pulsePollIntervalProvider.overrideWithValue(poll),
      ],
    );
    addTearDown(c.dispose);
    container = c;
    return c;
  }

  Future<void> pump([int ms = 40]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  setUp(() {
    now = DateTime.utc(2026, 10, 5, 11, 40);
    api = FakeMonitoringApi(
      snapshot: pulseBody(
        services: [pulseService(id: 's1', name: 'Сайт')],
      ),
    );
  });

  group('«Пульс»: снимок, кэш, ETag', () {
    test('200: снимок показан и сохранён в кэш вместе с ETag', () async {
      make();
      container.listen(pulseProvider, (_, _) {});
      expect(container.read(pulseProvider).loading, isTrue);
      await pump();
      final state = container.read(pulseProvider);
      expect(state.snapshot!.services.single.name, 'Сайт');
      expect(state.loading, isFalse);
      expect(state.offline, isFalse);
      expect(state.asOf, now);
      expect(api.pulseEtags, [null]);
      final cached = await container.read(pulseCacheProvider).readPulse();
      expect(cached!.etag, '"v1"');
      expect(cached.asOf, now);
      expect(cached.snapshot.total, 1);
    });

    test(
      'повторный запрос идёт с If-None-Match, 304 подтверждает кэш',
      () async {
        make();
        container.listen(pulseProvider, (_, _) {});
        await pump();
        now = now.add(const Duration(minutes: 3));
        await container.read(pulseProvider.notifier).load();
        expect(api.pulseEtags, [null, '"v1"']);
        final state = container.read(pulseProvider);
        expect(state.snapshot!.total, 1);
        expect(state.asOf, now);
        expect(state.offline, isFalse);
        final cached = await container.read(pulseCacheProvider).readPulse();
        expect(cached!.asOf, now);
        expect(cached.etag, '"v1"');
        // Данные изменились: новый тег, новый снимок.
        api
          ..etag = '"v2"'
          ..snapshot = pulseBody(
            services: [
              pulseService(
                id: 's1',
                name: 'Сайт',
                status: 'down',
                downSince: '2026-10-05T11:30:00Z',
              ),
            ],
          );
        await container.read(pulseProvider.notifier).load();
        expect(container.read(pulseProvider).snapshot!.down, 1);
        expect(api.pulseEtags.last, '"v1"');
        expect(
          (await container.read(pulseCacheProvider).readPulse())!.etag,
          '"v2"',
        );
      },
    );

    test('при старте кэш показывается сразу, ETag берётся из кэша', () async {
      make();
      await container
          .read(pulseCacheProvider)
          .writePulse(
            raw: pulseBody(
              services: [pulseService(id: 'old', name: 'Старый')],
            ),
            asOf: DateTime.utc(2026, 10, 5, 8),
            etag: '"v1"',
          );
      container.listen(pulseProvider, (_, _) {});
      await pump();
      // Сервер ответил 304 на тег из кэша: кэш остался, время обновилось.
      expect(api.pulseEtags, ['"v1"']);
      final state = container.read(pulseProvider);
      expect(state.snapshot!.services.single.name, 'Старый');
      expect(state.asOf, now);
    });

    test('нет сети: показан кэш с моментом, пометка «нет связи»', () async {
      api.error = offlineError;
      make();
      await container
          .read(pulseCacheProvider)
          .writePulse(
            raw: pulseBody(
              services: [pulseService(id: 'old', name: 'Старый')],
            ),
            asOf: DateTime.utc(2026, 10, 5, 8, 15),
            etag: '"v1"',
          );
      container.listen(pulseProvider, (_, _) {});
      await pump();
      final state = container.read(pulseProvider);
      expect(state.offline, isTrue);
      expect(state.loading, isFalse);
      expect(state.error, isNull);
      expect(state.snapshot!.services.single.name, 'Старый');
      expect(state.asOf, DateTime.utc(2026, 10, 5, 8, 15));
      // Связь вернулась: пометка снимается.
      api.error = null;
      await container.read(pulseProvider.notifier).load();
      expect(container.read(pulseProvider).offline, isFalse);
    });

    test('нет сети и нет кэша: данных нет, загрузка закончена', () async {
      api.error = offlineError;
      make();
      container.listen(pulseProvider, (_, _) {});
      await pump();
      final state = container.read(pulseProvider);
      expect(state.hasData, isFalse);
      expect(state.offline, isTrue);
      expect(state.loading, isFalse);
    });

    test('ошибка сервера (не сеть): текст, снимок остаётся', () async {
      make();
      container.listen(pulseProvider, (_, _) {});
      await pump();
      api.error = notConfiguredError;
      await container.read(pulseProvider.notifier).load();
      final state = container.read(pulseProvider);
      expect(state.offline, isFalse);
      expect(state.error, contains('нет движка проверок'));
      expect(state.snapshot, isNotNull);
    });

    test('повреждённый кэш читается как «кэша нет»', () async {
      make();
      await container
          .read(localSettingsRepositoryProvider)
          .write(PulseCache.pulseKey, '{не json');
      expect(await container.read(pulseCacheProvider).readPulse(), isNull);
      await container
          .read(localSettingsRepositoryProvider)
          .write(PulseCache.incidentsKey, '[]');
      expect(await container.read(pulseCacheProvider).readIncidents(), isNull);
      // 304 без кэша ничего не пишет.
      await container.read(pulseCacheProvider).touchPulse(now);
      await container
          .read(localSettingsRepositoryProvider)
          .delete(PulseCache.pulseKey);
      expect(await container.read(pulseCacheProvider).readPulse(), isNull);
    });

    test(
      'само обновляется по таймеру, а при закрытии экрана — останавливается',
      () async {
        make(poll: const Duration(milliseconds: 25));
        final sub = container.listen(pulseProvider, (_, _) {});
        await pump(160);
        expect(api.pulseEtags.length, greaterThanOrEqualTo(3));
        sub.close();
        await pump(30);
        final calls = api.pulseEtags.length;
        await pump(100);
        expect(api.pulseEtags.length, calls);
      },
    );

    test('закрытие экрана во время запроса не роняет контроллер', () async {
      make();
      container.listen(pulseProvider, (_, _) {}).close();
      await pump(60);
      expect(api.pulseEtags, isNotEmpty);
    });
  });

  group('«Проверить сейчас»', () {
    test(
      'обновляет снимок и кэш; частые нажатия не уходят на сервер',
      () async {
        make();
        container.listen(pulseProvider, (_, _) {});
        await pump();
        api.snapshot = pulseBody(
          services: [
            pulseService(
              id: 's1',
              name: 'Сайт',
              status: 'down',
              downSince: '2026-10-05T11:39:00Z',
            ),
          ],
        );
        final notifier = container.read(pulseProvider.notifier);
        final first = await notifier.refreshNow();
        expect(first.ok, isTrue);
        expect(api.refreshCalls, 1);
        expect(container.read(pulseProvider).snapshot!.down, 1);
        expect(container.read(pulseProvider).refreshing, isFalse);
        expect(
          (await container.read(pulseCacheProvider).readPulse())!.snapshot.down,
          1,
        );

        now = now.add(const Duration(seconds: 2));
        final second = await notifier.refreshNow();
        expect(second.outcome, ActionOutcome.tooSoon);
        expect(second.message, contains('Подождите'));
        expect(api.refreshCalls, 1);

        now = now.add(const Duration(seconds: 4));
        expect((await notifier.refreshNow()).ok, isTrue);
        expect(api.refreshCalls, 2);
        // После «Проверить» ETag сброшен: следующий опрос идёт без него.
        await notifier.load();
        expect(api.pulseEtags.last, isNull);
      },
    );

    test('без связи кнопка не отправляет запрос', () async {
      api.error = offlineError;
      make();
      container.listen(pulseProvider, (_, _) {});
      await pump();
      final result = await container.read(pulseProvider.notifier).refreshNow();
      expect(result.outcome, ActionOutcome.offline);
      expect(result.message, contains('Нет связи'));
      expect(api.refreshCalls, 0);
    });

    test('сеть оборвалась прямо в запросе: помечено «нет сети»', () async {
      make();
      container.listen(pulseProvider, (_, _) {});
      await pump();
      api.refreshError = offlineError;
      final result = await container.read(pulseProvider.notifier).refreshNow();
      expect(result.outcome, ActionOutcome.offline);
      expect(container.read(pulseProvider).offline, isTrue);
      expect(container.read(pulseProvider).refreshing, isFalse);
    });

    test('лимит 429: ждём Retry-After, повторно не стучимся', () async {
      make();
      container.listen(pulseProvider, (_, _) {});
      await pump();
      api.refreshError = rateLimitError(30);
      final notifier = container.read(pulseProvider.notifier);
      final limited = await notifier.refreshNow();
      expect(limited.outcome, ActionOutcome.rateLimited);
      expect(limited.message, 'Слишком часто. Повторите через 30 с.');
      expect(api.refreshCalls, 1);
      now = now.add(const Duration(seconds: 10));
      final soon = await notifier.refreshNow();
      expect(soon.outcome, ActionOutcome.tooSoon);
      expect(soon.message, contains('21 с'));
      expect(api.refreshCalls, 1);
      now = now.add(const Duration(seconds: 25));
      expect((await notifier.refreshNow()).ok, isTrue);
    });

    test('503 monitoring_not_configured — понятная ошибка', () async {
      make();
      container.listen(pulseProvider, (_, _) {});
      await pump();
      api.refreshError = notConfiguredError;
      final result = await container.read(pulseProvider.notifier).refreshNow();
      expect(result.outcome, ActionOutcome.failed);
      expect(result.message, contains('нет движка проверок'));
    });
  });

  group('инциденты: пагинация по составному курсору', () {
    // Пять инцидентов начались в одну секунду, один — раньше.
    final data = [
      for (var n = 1; n <= 5; n++)
        incidentJson(
          id: 'inc-$n',
          startedAt: '2026-10-05T10:00:00Z',
          endedAt: '2026-10-05T10:05:00Z',
          duration: 300,
        ),
      incidentJson(
        id: 'inc-0',
        startedAt: '2026-10-05T09:00:00Z',
        serviceId: 'svc-2',
        serviceName: 'Бот',
      ),
    ];

    test(
      'одинаковый started_at: ни одной потери и дубля, курсор — пара',
      () async {
        final paging = _PagingApi(data);
        make(fake: paging);
        container.listen(incidentsProvider(null), (_, _) {});
        await pump();
        var state = container.read(incidentsProvider(null));
        expect([for (final i in state.items) i.id], ['inc-5', 'inc-4']);
        expect(
          state.next,
          const IncidentCursor('2026-10-05T10:00:00Z', 'inc-4'),
        );
        final notifier = container.read(incidentsProvider(null).notifier);
        await notifier.loadMore();
        state = container.read(incidentsProvider(null));
        expect(
          [for (final i in state.items) i.id],
          ['inc-5', 'inc-4', 'inc-3', 'inc-2'],
        );
        await notifier.loadMore();
        state = container.read(incidentsProvider(null));
        expect(
          [for (final i in state.items) i.id],
          ['inc-5', 'inc-4', 'inc-3', 'inc-2', 'inc-1', 'inc-0'],
        );
        expect(state.hasMore, isFalse);
        // Следующие запросы уходили с обеими половинами курсора.
        expect(paging.incidentCalls.map((c) => c.cursor?.beforeId), [
          null,
          'inc-4',
          'inc-2',
        ]);
        expect(paging.incidentCalls[1].cursor!.before, '2026-10-05T10:00:00Z');
        // Конец ленты: «Показать ещё» ничего не делает.
        await notifier.loadMore();
        expect(paging.incidentCalls, hasLength(3));
      },
    );

    test('повтор уже показанного инцидента на следующей странице не '
        'дублируется', () async {
      final fake = FakeMonitoringApi(
        incidentPages: [
          incidentPage(
            [
              incidentJson(id: 'a', startedAt: '2026-10-05T10:00:00Z'),
              incidentJson(id: 'b', startedAt: '2026-10-05T09:00:00Z'),
            ],
            nextBefore: '2026-10-05T09:00:00Z',
            nextBeforeId: 'b',
          ),
          incidentPage([
            incidentJson(id: 'b', startedAt: '2026-10-05T09:00:00Z'),
            incidentJson(id: 'c', startedAt: '2026-10-05T08:00:00Z'),
          ]),
        ],
      );
      make(fake: fake);
      container.listen(incidentsProvider(null), (_, _) {});
      await pump();
      await container.read(incidentsProvider(null).notifier).loadMore();
      expect(
        [for (final i in container.read(incidentsProvider(null)).items) i.id],
        ['a', 'b', 'c'],
      );
    });

    test('первая страница кэшируется; без сети — кэш с пометкой', () async {
      make(fake: _PagingApi(data));
      container.listen(incidentsProvider(null), (_, _) {});
      await pump();
      final cached = await container.read(pulseCacheProvider).readIncidents();
      expect(cached!.page.incidents, hasLength(2));
      expect(
        cached.page.next,
        const IncidentCursor('2026-10-05T10:00:00Z', 'inc-4'),
      );
      expect(cached.asOf, now);

      // Новый «запуск»: связи нет, кэш показан.
      final offlineApi = _PagingApi(data)..error = offlineError;
      final second = ProviderContainer(
        overrides: [
          databaseOpenerProvider.overrideWithValue(InMemoryDatabaseOpener()),
          monitoringApiProvider.overrideWithValue(offlineApi),
          clockProvider.overrideWithValue(() => now),
        ],
      );
      addTearDown(second.dispose);
      await second
          .read(pulseCacheProvider)
          .writeIncidents(cached.page, cached.asOf);
      second.listen(incidentsProvider(null), (_, _) {});
      await pump();
      final state = second.read(incidentsProvider(null));
      expect(state.offline, isTrue);
      expect(state.items, hasLength(2));
      expect(state.asOf, now);
      expect(state.loading, isFalse);
    });

    test(
      'фильтр по сервису не трогает кэш и не смешивается с общей лентой',
      () async {
        final paging = _PagingApi(data);
        make(fake: paging);
        container.listen(incidentsProvider('svc-2'), (_, _) {});
        await pump();
        final state = container.read(incidentsProvider('svc-2'));
        expect([for (final i in state.items) i.id], ['inc-0']);
        expect(paging.incidentCalls.single.serviceId, 'svc-2');
        expect(
          await container.read(pulseCacheProvider).readIncidents(),
          isNull,
        );
      },
    );

    test('ошибки: нет сети на первой странице и на «Показать ещё»', () async {
      final paging = _PagingApi(data);
      make(fake: paging);
      container.listen(incidentsProvider(null), (_, _) {});
      await pump();
      paging.error = offlineError;
      final notifier = container.read(incidentsProvider(null).notifier);
      await notifier.loadMore();
      var state = container.read(incidentsProvider(null));
      expect(state.offline, isTrue);
      expect(state.loadingMore, isFalse);
      expect(state.items, hasLength(2));
      paging.error = rateLimitError();
      await notifier.reload();
      state = container.read(incidentsProvider(null));
      expect(state.error, contains('Слишком часто'));
      expect(state.items, hasLength(2));
      paging.error = null;
      await notifier.reload();
      state = container.read(incidentsProvider(null));
      expect(state.error, isNull);
      expect(state.offline, isFalse);
    });

    test(
      'копия страницы не дублирует инциденты при повторной подгрузке',
      () async {
        final paging = _PagingApi(data)..pageSize = 10;
        make(fake: paging);
        container.listen(incidentsProvider(null), (_, _) {});
        await pump();
        expect(container.read(incidentsProvider(null)).items, hasLength(6));
        expect(container.read(incidentsProvider(null)).hasMore, isFalse);
      },
    );
  });

  group('Telegram: тестовое сообщение', () {
    test('успех, потом защита от частых нажатий (10 секунд)', () async {
      make();
      final notifier = container.read(telegramTestProvider.notifier);
      container.listen(telegramTestProvider, (_, _) {});
      final first = await notifier.send();
      expect(first.ok, isTrue);
      expect(api.telegramCalls, 1);
      expect(container.read(telegramTestProvider), isFalse);
      now = now.add(const Duration(seconds: 3));
      final soon = await notifier.send();
      expect(soon.outcome, ActionOutcome.tooSoon);
      expect(soon.message, contains('Подождите 8 с'));
      expect(api.telegramCalls, 1);
      now = now.add(const Duration(seconds: 8));
      expect((await notifier.send()).ok, isTrue);
      expect(api.telegramCalls, 2);
    });

    test('сервер сказал rate_limited: объясняем, не повторяем', () async {
      api.testResult = const TelegramTestResult(
        ok: false,
        error: 'rate_limited',
      );
      make();
      container.listen(telegramTestProvider, (_, _) {});
      final result = await container.read(telegramTestProvider.notifier).send();
      expect(result.outcome, ActionOutcome.rateLimited);
      expect(result.message, contains('раз в 10 секунд'));
    });

    test('ошибки Telegram названы словами', () async {
      api.testResult = const TelegramTestResult(
        ok: false,
        error: 'chat_not_found',
      );
      make();
      container.listen(telegramTestProvider, (_, _) {});
      final notifier = container.read(telegramTestProvider.notifier);
      var result = await notifier.send();
      expect(result.outcome, ActionOutcome.failed);
      expect(result.message, contains('TELEGRAM_CHAT_ID'));
      now = now.add(const Duration(seconds: 11));
      api.testResult = const TelegramTestResult(
        ok: false,
        error: 'not_configured',
      );
      result = await notifier.send();
      expect(result.message, contains('Бот не настроен'));
    });

    test('нет сети и лимит 429 от самого API', () async {
      make();
      container.listen(telegramTestProvider, (_, _) {});
      final notifier = container.read(telegramTestProvider.notifier);
      api.error = offlineError;
      expect((await notifier.send()).outcome, ActionOutcome.offline);
      now = now.add(const Duration(seconds: 11));
      api.error = rateLimitError(20);
      final limited = await notifier.send();
      expect(limited.outcome, ActionOutcome.rateLimited);
      now = now.add(const Duration(seconds: 12));
      // Пауза сервера (20 с) длиннее клиентской: рано.
      expect((await notifier.send()).outcome, ActionOutcome.tooSoon);
      now = now.add(const Duration(seconds: 10));
      api.error = null;
      expect((await notifier.send()).ok, isTrue);
    });

    test('параллельный второй вызов во время запроса не уходит', () async {
      final slow = _SlowTelegramApi();
      make(fake: slow);
      container.listen(telegramTestProvider, (_, _) {});
      final notifier = container.read(telegramTestProvider.notifier);
      final first = notifier.send();
      await pump(5);
      expect(container.read(telegramTestProvider), isTrue);
      expect((await notifier.send()).outcome, ActionOutcome.tooSoon);
      slow.gate.complete();
      expect((await first).ok, isTrue);
      expect(slow.telegramCalls, 1);
    });
  });

  group('самопроверка', () {
    test('провайдер читает самопроверку один раз и не повторяет сам', () async {
      api.error = offlineError;
      make();
      final sub = container.listen(selfCheckProvider, (_, _) {});
      await pump(80);
      expect(container.read(selfCheckProvider).hasError, isTrue);
      expect(api.selfCalls, 1);
      sub.close();
    });
  });
}

class _SlowTelegramApi extends FakeMonitoringApi {
  final Completer<void> gate = Completer<void>();

  @override
  Future<TelegramTestResult> telegramTest() async {
    telegramCalls++;
    await gate.future;
    return const TelegramTestResult(ok: true);
  }
}
