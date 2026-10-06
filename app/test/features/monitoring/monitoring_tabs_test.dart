import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/format/ru_format.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_models.dart';

import '../../support/monitoring_env.dart';

FakeMonitoringApi _api({
  List<IncidentPage> pages = const [],
  SelfCheck? self,
}) => FakeMonitoringApi(
  snapshot: pulseBody(services: const []),
  incidentPages: pages,
  self: self,
);

SelfCheck _self({
  bool engine = true,
  String? engineError,
  int? lag = 4,
  String? polledAt = '2026-10-05T11:39:56Z',
  bool telegram = true,
  String? telegramError,
  String? telegramOk = '2026-10-05T10:00:00Z',
  int queued = 0,
  List<Map<String, String>> rejected = const [],
}) => SelfCheck.fromJson({
  'engine': {
    'configured': engine,
    'last_poll_at': polledAt,
    'lag_seconds': lag,
    'error': engineError,
  },
  'config': {
    'synced_at': '2026-10-05T11:39:00Z',
    'checks_active': 5,
    'checks_rejected': rejected,
  },
  'telegram': {
    'configured': telegram,
    'last_success_at': telegramOk,
    'last_error': telegramError,
    'queued': queued,
  },
});

void main() {
  setUp(() => debugUtcOffset = const Duration(hours: 3));
  tearDown(() => debugUtcOffset = null);

  group('вкладка «Инциденты»', () {
    testWidgets('лента: открытый и закрытый, причина, длительность', (
      tester,
    ) async {
      final api = _api(
        pages: [
          incidentPage([
            incidentJson(
              id: 'i2',
              startedAt: '2026-10-05T11:28:00Z',
              serviceName: 'Агент',
            ),
            incidentJson(
              id: 'i1',
              startedAt: '2026-10-04T08:00:00Z',
              endedAt: '2026-10-04T08:20:00Z',
              duration: 1200,
              serviceName: null,
              reason: 'timeout',
            ),
          ]),
        ],
      );
      await pumpMonitoring(tester, api: api);
      await tapKey(tester, 'pulse-tab-incidents');
      await settleMonitoring(tester);
      expect(find.byKey(const Key('incident-i2')), findsOneWidget);
      expect(find.text('Агент'), findsOneWidget);
      expect(find.textContaining('сейчас (12 мин)'), findsOneWidget);
      expect(find.text('HTTP 502'), findsOneWidget);
      expect(find.text('Сервис удалён'), findsOneWidget);
      expect(find.textContaining('(20 мин)'), findsOneWidget);
      expect(find.text('ЛЕЖИТ'), findsOneWidget);
      expect(find.text('ЗАКРЫТ'), findsOneWidget);
      expect(find.byKey(const Key('incidents-more')), findsNothing);
    });

    testWidgets('«Показать ещё»: курсор — пара, страницы дописываются', (
      tester,
    ) async {
      final api = _api(
        pages: [
          incidentPage(
            [
              incidentJson(id: 'a', startedAt: '2026-10-05T10:00:00Z'),
              incidentJson(id: 'b', startedAt: '2026-10-05T10:00:00Z'),
            ],
            nextBefore: '2026-10-05T10:00:00Z',
            nextBeforeId: 'b',
          ),
          incidentPage([
            incidentJson(id: 'c', startedAt: '2026-10-05T10:00:00Z'),
          ]),
        ],
      );
      await pumpMonitoring(tester, api: api, size: const Size(390, 1400));
      await tapKey(tester, 'pulse-tab-incidents');
      await settleMonitoring(tester);
      expect(find.byKey(const Key('incident-c')), findsNothing);
      await tapKey(tester, 'incidents-more');
      await settleMonitoring(tester);
      expect(find.byKey(const Key('incident-a')), findsOneWidget);
      expect(find.byKey(const Key('incident-b')), findsOneWidget);
      expect(find.byKey(const Key('incident-c')), findsOneWidget);
      expect(find.byKey(const Key('incidents-more')), findsNothing);
      expect(
        api.incidentCalls[1].cursor,
        const IncidentCursor('2026-10-05T10:00:00Z', 'b'),
      );
    });

    testWidgets('«Показать ещё» после обрыва связи не блокируется: '
        '«Повторить» догружает ленту', (tester) async {
      final api = _api(
        pages: [
          incidentPage(
            [incidentJson(id: 'a', startedAt: '2026-10-05T10:00:00Z')],
            nextBefore: '2026-10-05T10:00:00Z',
            nextBeforeId: 'a',
          ),
          incidentPage([
            incidentJson(id: 'b', startedAt: '2026-10-05T09:00:00Z'),
          ]),
        ],
      );
      await pumpMonitoring(tester, api: api, size: const Size(390, 1400));
      await tapKey(tester, 'pulse-tab-incidents');
      await settleMonitoring(tester);
      api.error = offlineError;
      await tapKey(tester, 'incidents-more');
      await settleMonitoring(tester);
      final more = find.byKey(const Key('incidents-more'));
      expect(
        find.descendant(of: more, matching: find.text('Повторить')),
        findsOneWidget,
      );
      expect(tester.widget<ElevatedButton>(more).onPressed, isNotNull);
      // Связь вернулась: нажатие снова идёт на сервер и догружает ленту.
      api.error = null;
      await tapKey(tester, 'incidents-more');
      await settleMonitoring(tester);
      expect(find.byKey(const Key('incident-b')), findsOneWidget);
      expect(more, findsNothing);
      expect(find.byKey(const Key('incidents-stale')), findsNothing);
    });

    testWidgets('фильтр по сервису: запрос с service_id', (tester) async {
      final api = _api(
        pages: [
          incidentPage([
            incidentJson(id: 'a', startedAt: '2026-10-05T10:00:00Z'),
          ]),
        ],
      );
      await pumpMonitoring(
        tester,
        api: api,
        seedWith: (c) async {
          await seedMonitor(c, serverId: srvA, serviceId: svcA, checkId: chkA);
          await seedMonitor(
            c,
            serverId: '01900000-0000-7000-8000-00000000b001',
            serviceId: '01900000-0000-7000-8000-00000000b002',
            checkId: '01900000-0000-7000-8000-00000000b003',
            serviceName: 'Бот',
          );
        },
      );
      await tapKey(tester, 'pulse-tab-incidents');
      await settleMonitoring(tester);
      await tapKey(tester, 'incidents-filter-$svcA');
      await settleMonitoring(tester);
      expect(api.incidentCalls.last.serviceId, svcA);
      await tapKey(tester, 'incidents-filter-all');
      await settleMonitoring(tester);
      expect(api.incidentCalls.last.serviceId, isNull);
    });

    testWidgets('пусто, ошибка и нет связи', (tester) async {
      final api = _api(pages: [incidentPage(const [])]);
      await pumpMonitoring(tester, api: api);
      await tapKey(tester, 'pulse-tab-incidents');
      await settleMonitoring(tester);
      expect(find.byKey(const Key('incidents-empty')), findsOneWidget);

      api.error = notConfiguredError;
      await tapKey(tester, 'pulse-tab-dashboard');
      await tapKey(tester, 'pulse-tab-incidents');
      await settleMonitoring(tester);
      expect(find.byKey(const Key('incidents-error')), findsOneWidget);
      api.error = null;
      await tapKey(tester, 'incidents-retry');
      await settleMonitoring(tester);
      expect(find.byKey(const Key('incidents-empty')), findsOneWidget);

      api.error = offlineError;
      await tapKey(tester, 'pulse-tab-dashboard');
      await tapKey(tester, 'pulse-tab-incidents');
      await settleMonitoring(tester);
      expect(find.byKey(const Key('incidents-offline-empty')), findsOneWidget);
    });

    testWidgets('нет связи: показана последняя страница из кэша с пометкой', (
      tester,
    ) async {
      final api = _api(
        pages: [
          incidentPage([
            incidentJson(id: 'a', startedAt: '2026-10-05T10:00:00Z'),
          ]),
        ],
      );
      await pumpMonitoring(tester, api: api);
      await tapKey(tester, 'pulse-tab-incidents');
      await settleMonitoring(tester);
      expect(find.byKey(const Key('incident-a')), findsOneWidget);
      // Закрыли вкладку, связь пропала, открыли снова: кэш.
      api.error = offlineError;
      await tapKey(tester, 'pulse-tab-dashboard');
      await tapKey(tester, 'pulse-tab-incidents');
      await settleMonitoring(tester);
      expect(find.byKey(const Key('incident-a')), findsOneWidget);
      expect(find.byKey(const Key('incidents-stale')), findsOneWidget);
      expect(find.text('Данные на 14:40 · нет сети'), findsOneWidget);
    });
  });

  group('вкладка «Самопроверка»', () {
    testWidgets('всё работает: движок, конфигурация, Telegram, очередь', (
      tester,
    ) async {
      final api = _api(self: _self(queued: 2));
      await pumpMonitoring(tester, api: api);
      await tapKey(tester, 'pulse-tab-selfCheck');
      await settleMonitoring(tester);
      expect(find.text('РАБОТАЕТ'), findsOneWidget);
      expect(
        find.textContaining('Последний опрос: только что'),
        findsOneWidget,
      );
      expect(find.text('Проверок в работе: 5'), findsOneWidget);
      expect(find.text('Отклонённых проверок нет.'), findsOneWidget);
      expect(find.text('НАСТРОЕН'), findsOneWidget);
      expect(
        find.textContaining('Последнее сообщение: сегодня в 13:00'),
        findsOneWidget,
      );
      expect(find.text('В очереди: 2 сообщения.'), findsOneWidget);
      expect(find.byKey(const Key('telegram-test')), findsOneWidget);
      expect(find.textContaining('TELEGRAM_BOT_TOKEN'), findsNothing);
    });

    testWidgets(
      'движок не отвечает и не подключён; отклонённые проверки с причинами',
      (tester) async {
        final api = _api(
          self: _self(
            engineError: 'timeout',
            lag: 300,
            rejected: [
              {'check_id': chkA, 'reason': 'resolve_failed'},
              {'check_id': 'unknown-check', 'reason': 'target_bad_tld'},
            ],
          ),
        );
        await pumpMonitoring(
          tester,
          api: api,
          seedWith: (c) =>
              seedMonitor(c, serverId: srvA, serviceId: svcA, checkId: chkA),
        );
        await tapKey(tester, 'pulse-tab-selfCheck');
        await settleMonitoring(tester);
        expect(find.text('НЕ ОТВЕЧАЕТ'), findsOneWidget);
        expect(find.byKey(const Key('self-engine-error')), findsOneWidget);
        expect(find.text('Не запускаются: 2'), findsOneWidget);
        expect(
          find.textContaining('Сайт · Главная: Имя не разрешается в DNS'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Проверка: Цель проверки не подходит'),
          findsOneWidget,
        );

        api.self = _self(engine: false, polledAt: null, lag: null);
        await tapKey(tester, 'pulse-tab-dashboard');
        await tapKey(tester, 'pulse-tab-selfCheck');
        await settleMonitoring(tester);
        expect(find.text('НЕ ПОДКЛЮЧЁН'), findsOneWidget);
        expect(find.textContaining('не задан адрес движка'), findsOneWidget);
      },
    );

    testWidgets('без связи «Отправить тест» неактивна, со связью — снова '
        'доступна', (tester) async {
      final api = _api(self: _self());
      final status = _FakeStatus();
      await pumpMonitoring(
        tester,
        api: api,
        overrides: [syncStatusProvider.overrideWith(() => status)],
      );
      await tapKey(tester, 'pulse-tab-selfCheck');
      await settleMonitoring(tester);
      VoidCallback? onPressed() => tester
          .widget<ElevatedButton>(find.byKey(const Key('telegram-test')))
          .onPressed;
      expect(onPressed(), isNotNull);
      expect(find.byKey(const Key('self-telegram-offline')), findsNothing);
      status.setOnline(online: false);
      await tester.pump();
      expect(onPressed(), isNull);
      expect(find.byKey(const Key('self-telegram-offline')), findsOneWidget);
      status.setOnline(online: true);
      await tester.pump();
      expect(onPressed(), isNotNull);
      expect(api.telegramCalls, 0);
    });

    testWidgets(
      'Telegram не настроен: кнопка «Отправить тест» неактивна, объяснение',
      (tester) async {
        final api = _api(
          self: _self(
            telegram: false,
            telegramOk: null,
            telegramError: 'not_configured',
          ),
        );
        await pumpMonitoring(tester, api: api);
        await tapKey(tester, 'pulse-tab-selfCheck');
        await settleMonitoring(tester);
        expect(find.text('НЕ НАСТРОЕН'), findsOneWidget);
        expect(find.text('Сообщений ещё не отправлялось.'), findsOneWidget);
        expect(
          find.byKey(const Key('self-telegram-not-configured')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('self-telegram-error')), findsOneWidget);
        expect(
          tester
              .widget<ElevatedButton>(find.byKey(const Key('telegram-test')))
              .onPressed,
          isNull,
        );
        expect(api.telegramCalls, 0);
      },
    );

    testWidgets(
      '«Отправить тест»: успех, затем частое нажатие не уходит на сервер',
      (tester) async {
        final api = _api(self: _self());
        await pumpMonitoring(tester, api: api);
        await tapKey(tester, 'pulse-tab-selfCheck');
        await settleMonitoring(tester);
        await tapKey(tester, 'telegram-test');
        await settleMonitoring(tester);
        expect(api.telegramCalls, 1);
        expect(
          find.text('Тестовое сообщение отправлено: проверьте Telegram.'),
          findsOneWidget,
        );
        await tapKey(tester, 'telegram-test');
        await settleMonitoring(tester);
        expect(api.telegramCalls, 1, reason: 'клиент не спамит');
        expect(find.textContaining('Подождите'), findsOneWidget);
      },
    );

    testWidgets(
      'rate_limited от сервера объяснён словами; ошибка бота — красная строка',
      (tester) async {
        final api = _api(self: _self())
          ..testResult = const TelegramTestResult(
            ok: false,
            error: 'rate_limited',
          );
        await pumpMonitoring(tester, api: api);
        await tapKey(tester, 'pulse-tab-selfCheck');
        await settleMonitoring(tester);
        await tapKey(tester, 'telegram-test');
        await settleMonitoring(tester);
        expect(
          find.text(
            'Слишком часто: тестовое сообщение можно отправлять раз в 10 секунд.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('ошибка Telegram: chat_not_found', (tester) async {
      final api = _api(self: _self())
        ..testResult = const TelegramTestResult(
          ok: false,
          error: 'chat_not_found',
        );
      await pumpMonitoring(tester, api: api);
      await tapKey(tester, 'pulse-tab-selfCheck');
      await settleMonitoring(tester);
      await tapKey(tester, 'telegram-test');
      await settleMonitoring(tester);
      expect(find.textContaining('Чат не найден'), findsOneWidget);
    });

    testWidgets('нет связи / ошибка сервера: понятные карточки с «Повторить»', (
      tester,
    ) async {
      final api = _api(self: _self())..error = offlineError;
      await pumpMonitoring(tester, api: api);
      await tapKey(tester, 'pulse-tab-selfCheck');
      await settleMonitoring(tester);
      expect(find.byKey(const Key('self-offline')), findsOneWidget);
      api.error = notConfiguredError;
      await tapKey(tester, 'self-retry');
      await settleMonitoring(tester);
      expect(find.byKey(const Key('self-error')), findsOneWidget);
      api.error = null;
      await tapKey(tester, 'self-retry');
      await settleMonitoring(tester);
      expect(find.byKey(const Key('self-engine')), findsOneWidget);
    });
  });

  group('экран', () {
    testWidgets(
      'четыре вкладки; «Бэкапы» не входят в Этап 9; кнопка добавления сервера',
      (tester) async {
        await pumpMonitoring(tester, api: _api());
        for (final tab in ['dashboard', 'servers', 'incidents', 'selfCheck']) {
          expect(find.byKey(Key('pulse-tab-$tab')), findsOneWidget);
        }
        expect(find.text('Бэкапы'), findsNothing);
        expect(find.text('Работа ›'), findsOneWidget);
        await tapKey(tester, 'pulse-add-server');
        expect(find.byKey(const Key('server-name')), findsOneWidget);
      },
    );
  });
}

/// Состояние синхронизации без настоящего движка: управляется только связь.
class _FakeStatus extends Notifier<SyncStatus> implements SyncStatusNotifier {
  @override
  SyncStatus build() => const SyncStatus();

  void setOnline({required bool online}) =>
      state = state.copyWith(online: online);
}
