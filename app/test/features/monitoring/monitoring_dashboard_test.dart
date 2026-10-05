import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/format/ru_format.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/features/monitoring/application/monitoring_providers.dart';
import 'package:my_tasker/features/monitoring/data/pulse_cache.dart';

import '../../support/monitoring_env.dart';

Map<String, Object?> _demo() => pulseBody(
  services: [
    pulseService(
      id: 'svc-down',
      name: 'Агент по лидам',
      status: 'down',
      downSince: '2026-10-05T11:28:00Z',
      h24: 2487,
      responseMs: null,
      critical: true,
      checks: [
        pulseCheck(
          id: 'down-http',
          status: 'down',
          responseMs: null,
          h24: 2487,
        ),
        pulseCheck(
          id: 'down-dns',
          kind: 'dns',
          name: 'Имя сайта',
          status: 'unknown',
          problem: 'resolve_failed',
          spark: const [],
          h24: null,
        ),
      ],
    ),
    pulseService(id: 'svc-up', name: 'Летим на Гаити', h24: 9884),
    pulseService(
      id: 'svc-slow',
      name: 'Бот',
      server: 'Резервный',
      serverId: 'srv-2',
      h24: 9710,
      responseMs: 1234,
    ),
    pulseService(
      id: 'svc-new',
      name: 'Новый',
      server: 'Резервный',
      serverId: 'srv-2',
      status: 'unknown',
      h24: null,
      responseMs: null,
      checks: [
        pulseCheck(
          id: 'new-tcp',
          kind: 'tcp',
          name: 'Порт',
          status: 'unknown',
          spark: const [],
          h24: null,
        ),
      ],
    ),
  ],
);

void main() {
  setUp(() => debugUtcOffset = const Duration(hours: 3));
  tearDown(() => debugUtcOffset = null);

  group('дашборд «Пульс»', () {
    testWidgets('карточки: статус, доступность, отклик, упавший первым', (
      tester,
    ) async {
      final api = FakeMonitoringApi(snapshot: _demo());
      await pumpMonitoring(tester, api: api);
      expect(find.byKey(const Key('pulse-screen')), findsOneWidget);
      expect(find.text('1 лежит из 4'), findsOneWidget);
      for (final id in ['svc-down', 'svc-up', 'svc-slow', 'svc-new']) {
        expect(find.byKey(Key('pulse-card-$id')), findsOneWidget, reason: id);
      }
      // Упавший сервис — первый в сетке; красная пилюля «ЛЕЖИТ».
      final downTop = tester
          .getTopLeft(find.byKey(const Key('pulse-card-svc-down')))
          .dy;
      final upTop = tester
          .getTopLeft(find.byKey(const Key('pulse-card-svc-up')))
          .dy;
      expect(downTop, lessThan(upTop));
      expect(find.text('ЛЕЖИТ'), findsOneWidget);
      expect(find.text('РАБОТАЕТ'), findsNWidgets(2));
      expect(find.text('НЕТ ДАННЫХ'), findsOneWidget);
      // Сколько лежит: 11:28 -> 11:40 = 12 минут.
      expect(
        tester.widget<Text>(find.byKey(const Key('pulse-down-svc-down'))).data,
        '12 мин',
      );
      // Метрики: значение — текстом, за порогом — с иконкой.
      expect(find.text('98,84 %'), findsOneWidget);
      expect(find.text('24,87 %'), findsOneWidget);
      expect(find.text('178 мс'), findsOneWidget);
      expect(find.text('1,2 с'), findsOneWidget);
      expect(find.text('Агент по лидам'), findsOneWidget);
      // Группы по серверам.
      expect(find.text('Основной VPS'), findsOneWidget);
      expect(find.text('Резервный'), findsOneWidget);
      expect(find.byKey(const Key('pulse-stale')), findsNothing);
      expect(find.byKey(const Key('pulse-engine-stale')), findsNothing);
    });

    testWidgets(
      'problem проверки показан понятным текстом, чип — полая точка',
      (tester) async {
        await pumpMonitoring(tester, api: FakeMonitoringApi(snapshot: _demo()));
        final problem = find.byKey(const Key('pulse-problem-down-dns'));
        expect(problem, findsOneWidget);
        expect(
          find.descendant(
            of: problem,
            matching: find.textContaining('Имя не разрешается в DNS'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: problem,
            matching: find.textContaining('Имя сайта'),
          ),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel(RegExp('не запускается')), findsWidgets);
      },
    );

    testWidgets(
      'мини-график: линия есть у карточки с историей, «данных нет» — у новой',
      (tester) async {
        await pumpMonitoring(tester, api: FakeMonitoringApi(snapshot: _demo()));
        expect(find.byKey(const Key('spark')), findsWidgets);
        expect(find.byKey(const Key('spark-empty')), findsOneWidget);
      },
    );

    testWidgets('«Выключить» нет нигде: ни на карточках, ни в деталях', (
      tester,
    ) async {
      await pumpMonitoring(tester, api: FakeMonitoringApi(snapshot: _demo()));
      expect(find.textContaining('Выключить'), findsNothing);
      expect(find.textContaining('Остановить'), findsNothing);
      await tester.tap(find.byKey(const Key('pulse-card-svc-down')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('service-details')), findsOneWidget);
      expect(find.textContaining('Выключить'), findsNothing);
    });

    testWidgets('все работают: итог белым, «Все N работают»', (tester) async {
      final api = FakeMonitoringApi(
        snapshot: pulseBody(
          services: [
            pulseService(id: 'a', name: 'A'),
            pulseService(id: 'b', name: 'B'),
          ],
        ),
      );
      await pumpMonitoring(tester, api: api);
      expect(find.text('Все 2 работают'), findsOneWidget);
    });

    testWidgets('сворачивание группы сервера скрывает карточки', (
      tester,
    ) async {
      await pumpMonitoring(tester, api: FakeMonitoringApi(snapshot: _demo()));
      expect(find.byKey(const Key('pulse-card-svc-slow')), findsOneWidget);
      await tapKey(tester, 'pulse-group-srv-2');
      expect(find.byKey(const Key('pulse-card-svc-slow')), findsNothing);
      expect(find.byKey(const Key('pulse-card-svc-up')), findsOneWidget);
      await tapKey(tester, 'pulse-group-srv-2');
      expect(find.byKey(const Key('pulse-card-svc-slow')), findsOneWidget);
    });

    testWidgets('десктоп: карточки в несколько колонок', (tester) async {
      await pumpMonitoring(
        tester,
        api: FakeMonitoringApi(snapshot: _demo()),
        size: desktopSize,
      );
      final a = tester.getTopLeft(find.byKey(const Key('pulse-card-svc-down')));
      final b = tester.getTopLeft(find.byKey(const Key('pulse-card-svc-up')));
      expect(a.dy, b.dy, reason: 'в одной строке сетки');
      expect(b.dx, greaterThan(a.dx + 280));
    });

    testWidgets('хост сервера из локальных данных виден в заголовке группы', (
      tester,
    ) async {
      await pumpMonitoring(
        tester,
        api: FakeMonitoringApi(
          snapshot: pulseBody(
            services: [
              pulseService(id: svcA, name: 'Сайт', serverId: srvA),
              pulseService(
                id: 'other',
                name: 'Чужой',
                serverId: 'srv-x',
                server: 'Без хоста',
              ),
            ],
          ),
        ),
        seedWith: (c) => seedMonitor(
          c,
          host: '93.184.216.34',
          serverId: srvA,
          serviceId: svcA,
          checkId: chkA,
        ),
      );
      expect(find.text('93.184.216.34'), findsOneWidget);
      expect(find.text('Основной VPS'), findsOneWidget);
      expect(find.text('Без хоста'), findsOneWidget);
    });
  });

  group('состояния экрана', () {
    testWidgets(
      'нет связи, кэш есть: «Данные на 14:15 · нет сети», проверка недоступна',
      (tester) async {
        final api = FakeMonitoringApi(snapshot: _demo())..error = offlineError;
        await pumpMonitoring(
          tester,
          api: api,
          location: '/work',
          seedWith: (c) => c
              .read(pulseCacheProvider)
              .writePulse(
                raw: _demo(),
                asOf: DateTime.utc(2026, 10, 5, 11, 15),
                etag: '"v1"',
              ),
        );
        await tapKey(tester, 'work-servers-link');
        await settleMonitoring(tester);
        expect(find.byKey(const Key('pulse-stale')), findsOneWidget);
        expect(find.text('Данные на 14:15 · нет сети'), findsOneWidget);
        expect(find.byKey(const Key('pulse-card-svc-up')), findsOneWidget);
        final button = tester.widget<ElevatedButton>(
          find.byKey(const Key('pulse-refresh')),
        );
        expect(button.onPressed, isNull);
        expect(api.refreshCalls, 0);
        expect(api.pulseEtags, ['"v1"']);
      },
    );

    testWidgets(
      'нет связи и нет кэша: понятное пустое состояние и «Повторить»',
      (tester) async {
        final api = FakeMonitoringApi(snapshot: _demo())..error = offlineError;
        await pumpMonitoring(tester, api: api);
        expect(find.byKey(const Key('pulse-offline-empty')), findsOneWidget);
        api.error = null;
        await tapKey(tester, 'pulse-retry');
        await settleMonitoring(tester);
        expect(find.byKey(const Key('pulse-card-svc-up')), findsOneWidget);
      },
    );

    testWidgets('ошибка сервера без данных: красная карточка с «Повторить»', (
      tester,
    ) async {
      final api = FakeMonitoringApi(snapshot: _demo())
        ..error = notConfiguredError;
      await pumpMonitoring(tester, api: api);
      expect(find.byKey(const Key('pulse-error')), findsOneWidget);
      expect(find.textContaining('нет движка проверок'), findsOneWidget);
      api.error = null;
      await tapKey(tester, 'pulse-retry');
      await settleMonitoring(tester);
      expect(find.byKey(const Key('pulse-error')), findsNothing);
      expect(find.byKey(const Key('pulse-summary')), findsOneWidget);
    });

    testWidgets('сервер не настроен в приложении: ошибка, а не падение', (
      tester,
    ) async {
      final api = FakeMonitoringApi(snapshot: _demo())
        ..error = const ApiException.notConfigured();
      await pumpMonitoring(tester, api: api);
      expect(find.byKey(const Key('pulse-error')), findsOneWidget);
      expect(find.textContaining('Сервер не настроен'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('движок не отвечает: «данные устарели», тревоги не идут', (
      tester,
    ) async {
      final api = FakeMonitoringApi(
        snapshot: pulseBody(
          services: [pulseService(id: 'a', name: 'A')],
          healthy: false,
          engineError: 'timeout',
        ),
      );
      await pumpMonitoring(tester, api: api);
      expect(find.byKey(const Key('pulse-engine-stale')), findsOneWidget);
      expect(
        find.textContaining('Данные устарели: движок не отвечает: timeout'),
        findsOneWidget,
      );
    });

    testWidgets('движок не подключён на сервере', (tester) async {
      final api = FakeMonitoringApi(
        snapshot: pulseBody(
          services: const [],
          configured: false,
          healthy: false,
        ),
      );
      await pumpMonitoring(tester, api: api);
      expect(find.byKey(const Key('pulse-engine-missing')), findsOneWidget);
    });

    testWidgets('серверов нет совсем: приглашение добавить сервер', (
      tester,
    ) async {
      final api = FakeMonitoringApi(snapshot: pulseBody(services: const []));
      await pumpMonitoring(tester, api: api);
      expect(find.byKey(const Key('pulse-empty')), findsOneWidget);
      expect(find.text('Сервисов пока нет'), findsOneWidget);
      await tapKey(tester, 'pulse-empty-add');
      expect(find.byKey(const Key('server-name')), findsOneWidget);
    });

    testWidgets('серверы есть, данных мониторинга ещё нет', (tester) async {
      final api = FakeMonitoringApi(snapshot: pulseBody(services: const []));
      await pumpMonitoring(tester, api: api, seedWith: seedMonitor);
      expect(find.byKey(const Key('pulse-empty-nodata')), findsOneWidget);
    });

    testWidgets(
      'ошибка запроса при имеющемся снимке — красная строка, снимок остаётся',
      (tester) async {
        final api = FakeMonitoringApi(snapshot: _demo());
        final container = await pumpMonitoring(tester, api: api);
        api.error = notConfiguredError;
        await tester.runAsync(
          () => container.read(pulseProvider.notifier).load(),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('pulse-fetch-error')), findsOneWidget);
        expect(find.byKey(const Key('pulse-card-svc-up')), findsOneWidget);
      },
    );
  });

  group('«Проверить сейчас»', () {
    testWidgets('обновляет карточки; повторное нажатие сразу — подсказка', (
      tester,
    ) async {
      final api = FakeMonitoringApi(snapshot: _demo());
      await pumpMonitoring(tester, api: api);
      api.snapshot = pulseBody(
        services: [pulseService(id: 'only', name: 'Единственный')],
      );
      await tapKey(tester, 'pulse-refresh');
      await settleMonitoring(tester);
      expect(api.refreshCalls, 1);
      expect(find.byKey(const Key('pulse-card-only')), findsOneWidget);
      expect(find.text('Проверить'), findsOneWidget);
      await tapKey(tester, 'pulse-refresh');
      expect(api.refreshCalls, 1, reason: 'частое нажатие не уходит на сервер');
      expect(find.byKey(const Key('pulse-notice')), findsOneWidget);
      expect(find.textContaining('Подождите'), findsOneWidget);
    });

    testWidgets('лимит сервера: сообщение с паузой, красной ошибки нет', (
      tester,
    ) async {
      final api = FakeMonitoringApi(snapshot: _demo());
      await pumpMonitoring(tester, api: api);
      api.refreshError = rateLimitError(15);
      await tapKey(tester, 'pulse-refresh');
      await settleMonitoring(tester);
      expect(find.text('Слишком часто. Повторите через 15 с.'), findsOneWidget);
      expect(find.byKey(const Key('pulse-card-svc-up')), findsOneWidget);
    });

    testWidgets('сервер без движка: «мониторинг не настроен»', (tester) async {
      final api = FakeMonitoringApi(snapshot: _demo());
      await pumpMonitoring(tester, api: api);
      api.refreshError = notConfiguredError;
      await tapKey(tester, 'pulse-refresh');
      await settleMonitoring(tester);
      expect(find.textContaining('нет движка проверок'), findsOneWidget);
    });
  });

  group('детали сервиса', () {
    testWidgets('проверки, доступность за 24 ч / 7 / 30 дней и инциденты', (
      tester,
    ) async {
      final api = FakeMonitoringApi(
        snapshot: _demo(),
        incidentPages: [
          incidentPage([
            incidentJson(
              id: 'i1',
              startedAt: '2026-10-05T11:28:00Z',
              serviceId: 'svc-down',
              serviceName: 'Агент по лидам',
            ),
            incidentJson(
              id: 'i0',
              startedAt: '2026-10-04T08:00:00Z',
              endedAt: '2026-10-04T08:20:00Z',
              duration: 1200,
              serviceId: 'svc-down',
              serviceName: 'Агент по лидам',
              reason: 'timeout',
            ),
          ]),
        ],
      );
      await pumpMonitoring(tester, api: api, size: const Size(390, 1200));
      await tester.tap(find.byKey(const Key('pulse-card-svc-down')));
      await settleMonitoring(tester);
      final sheet = find.byKey(const Key('service-details'));
      expect(sheet, findsOneWidget);
      expect(
        find.descendant(of: sheet, matching: find.text('24 ЧАСА')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('7 ДНЕЙ')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('30 ДНЕЙ')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('details-check-down-http')), findsOneWidget);
      expect(find.byKey(const Key('details-check-down-dns')), findsOneWidget);
      expect(find.text('НЕ ЗАПУСКАЕТСЯ'), findsOneWidget);
      expect(find.textContaining('Имя не разрешается в DNS'), findsWidgets);
      // Инциденты сервиса: открытый и закрытый.
      expect(api.incidentCalls.single.serviceId, 'svc-down');
      expect(find.text('ЛЕЖИТ'), findsWidgets);
      expect(find.text('ЗАКРЫТ'), findsOneWidget);
      expect(find.textContaining('timeout'), findsOneWidget);
    });

    testWidgets('без инцидентов; правка сервиса из деталей', (tester) async {
      final api = FakeMonitoringApi(
        snapshot: pulseBody(
          services: [
            pulseService(id: svcA, name: 'Сайт', serverId: srvA),
            pulseService(id: 'no-local', name: 'Без записи', serverId: 'srv-x'),
          ],
        ),
        incidentPages: [incidentPage(const [])],
      );
      await pumpMonitoring(
        tester,
        api: api,
        seedWith: (c) =>
            seedMonitor(c, serverId: srvA, serviceId: svcA, checkId: chkA),
      );
      // Сервис, которого нет среди данных устройства, править нельзя.
      await tester.tap(find.byKey(const Key('pulse-card-no-local')));
      await settleMonitoring(tester);
      expect(find.byKey(const Key('details-no-incidents')), findsOneWidget);
      expect(find.text('Инцидентов не было.'), findsOneWidget);
      expect(find.byKey(const Key('details-edit')), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await settleMonitoring(tester);
      await tester.tap(find.byKey(const Key('pulse-card-$svcA')));
      await settleMonitoring(tester);
      expect(find.byKey(const Key('details-edit')), findsOneWidget);
      await tapKey(tester, 'details-edit');
      expect(find.byKey(const Key('service-name')), findsOneWidget);
      expect(find.text('Сайт'), findsWidgets);
    });

    testWidgets('сервис исчез из снимка: подсказка вместо деталей', (
      tester,
    ) async {
      final api = FakeMonitoringApi(
        snapshot: pulseBody(
          services: [pulseService(id: 'a', name: 'A')],
        ),
        incidentPages: [incidentPage(const [])],
      );
      final container = await pumpMonitoring(tester, api: api);
      await tester.tap(find.byKey(const Key('pulse-card-a')));
      await settleMonitoring(tester);
      api.snapshot = pulseBody(
        services: [pulseService(id: 'b', name: 'B')],
      );
      await tester.runAsync(
        () => container.read(pulseProvider.notifier).refreshNow(),
      );
      await settleMonitoring(tester);
      expect(find.textContaining('Сервис не найден'), findsOneWidget);
    });
  });
}
