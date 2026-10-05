import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/format/ru_format.dart';

import '../support/monitoring_env.dart';

/// Golden-тесты Этапа 9 (только ключевые экраны, 04, 2.4): дашборд «Пульс»
/// (телефон и десктоп) и форма проверки. Эталоны — `files/monitoring_*.png`;
/// обновление: `flutter test --update-goldens test/goldens`.
/// Длинный телефонный экран: на снимке виден весь список, а не первый экран.
const Size _tall = Size(390, 1500);

Future<void> _shot(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('files/$name.png'));

/// Демо «Пульса»: упавший сервис с недоступным DNS, живые сервисы с разной
/// доступностью и откликом, новый сервис без данных; два сервера.
Map<String, Object?> _demo() => pulseBody(
  services: [
    pulseService(
      id: 'lead',
      name: 'Агент по лидам',
      status: 'down',
      downSince: '2026-10-05T11:28:00Z',
      critical: true,
      h24: 2487,
      responseMs: null,
      checks: [
        pulseCheck(
          id: 'lead-http',
          status: 'down',
          responseMs: null,
          h24: 2487,
        ),
        pulseCheck(
          id: 'lead-tcp',
          kind: 'tcp',
          name: 'База',
          spark: const [12, 14, 13, 12, 15, 13, 12, 14, 13, 12, 14, 13],
        ),
        pulseCheck(
          id: 'lead-dns',
          kind: 'dns',
          name: 'Имя сайта',
          status: 'unknown',
          problem: 'resolve_failed',
          spark: const [],
          h24: null,
        ),
      ],
    ),
    pulseService(
      id: 'haiti',
      name: 'Летим на Гаити',
      h24: 9884,
      checks: [
        pulseCheck(id: 'haiti-http'),
        pulseCheck(
          id: 'haiti-ssl',
          kind: 'ssl',
          name: 'Сертификат',
          spark: const [],
        ),
      ],
    ),
    pulseService(
      id: 'bot',
      name: 'Бот разборов ИИ',
      server: 'Резервный VPS',
      serverId: 'srv-2',
      h24: 9710,
      responseMs: 640,
      checks: [
        pulseCheck(
          id: 'bot-http',
          name: 'Webhook',
          spark: const [220, 340, 410, 520, 640, 700, 480, 610, 590, 640],
        ),
      ],
    ),
    pulseService(
      id: 'new',
      name: 'Новый сервис',
      server: 'Резервный VPS',
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

  group('Серверы', () {
    testWidgets('«Пульс»: телефон', (tester) async {
      await pumpMonitoring(
        tester,
        api: FakeMonitoringApi(snapshot: _demo()),
        size: _tall,
      );
      expect(find.byKey(const Key('pulse-summary')), findsOneWidget);
      await _shot(tester, 'monitoring_pulse_phone');
    });

    testWidgets('«Пульс»: десктоп', (tester) async {
      await pumpMonitoring(
        tester,
        api: FakeMonitoringApi(snapshot: _demo()),
        size: desktopSize,
      );
      expect(find.byKey(const Key('pulse-summary')), findsOneWidget);
      await _shot(tester, 'monitoring_pulse_desktop');
    });

    testWidgets('форма проверки: HTTP с ошибкой адреса', (tester) async {
      await pumpMonitoring(
        tester,
        api: FakeMonitoringApi(snapshot: _demo()),
        size: const Size(390, 1100),
        seedWith: (c) =>
            seedMonitor(c, serverId: srvA, serviceId: svcA, checkId: chkA),
      );
      await tapKey(tester, 'pulse-tab-servers');
      await tapKey(tester, 'check-add-$svcA');
      await tester.enterText(find.byKey(const Key('check-name')), 'Здоровье');
      await tester.enterText(
        find.byKey(const Key('check-url')),
        'http://169.254.169.254/latest/meta-data/',
      );
      await tester.enterText(find.byKey(const Key('check-status')), '200');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('check-form')), findsOneWidget);
      await _shot(tester, 'monitoring_check_form_phone');
    });
  });
}
