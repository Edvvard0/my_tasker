import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/monitoring/data/monitoring_repository.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_models.dart';
import 'package:my_tasker/features/monitoring/presentation/monitoring_editors.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

import '../../support/monitoring_env.dart';

FakeMonitoringApi _api() =>
    FakeMonitoringApi(snapshot: pulseBody(services: const []));

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  bool seed = true,
  Size size = phoneSize,
}) async {
  final c = await pumpMonitoring(
    tester,
    api: _api(),
    size: size,
    seedWith: seed
        ? (c) => seedMonitor(
            c,
            serverId: srvA,
            serviceId: svcA,
            checkId: chkA,
            critical: true,
          )
        : null,
  );
  await tapKey(tester, 'pulse-tab-servers');
  await settleMonitoring(tester);
  return c;
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.enterText(find.byKey(Key(key)), text);
  await tester.pump();
}

Future<void> _save(WidgetTester tester, String prefix) async {
  await tapKey(tester, '$prefix-save');
  await settleMonitoring(tester);
}

void main() {
  group('вкладка «Серверы»', () {
    testWidgets('иерархия: сервер, сервис, проверки с целью и интервалом', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.byKey(const Key('server-edit-$srvA')), findsOneWidget);
      expect(find.text('Основной VPS'), findsOneWidget);
      expect(find.text('example.com'), findsOneWidget);
      expect(find.byKey(const Key('service-edit-$svcA')), findsOneWidget);
      expect(find.text('Сайт'), findsOneWidget);
      expect(find.text('1 шт.'), findsOneWidget);
      expect(find.text('Главная'), findsOneWidget);
      expect(
        find.text('HTTP · https://example.com · каждые 20 с'),
        findsOneWidget,
      );
      expect(find.textContaining('Выключить'), findsNothing);
      expect(find.textContaining('Пауза'), findsNothing);
    });

    testWidgets(
      'пусто: приглашение; провайдер и заметка видны в строке сервера',
      (tester) async {
        await _pump(tester, seed: false);
        expect(find.byKey(const Key('servers-empty')), findsOneWidget);
        await tapKey(tester, 'servers-empty-add');
        await _type(tester, 'server-name', 'Резерв');
        await _type(tester, 'server-host', 'backup.example.org');
        await _type(tester, 'server-provider', 'Timeweb');
        await _save(tester, 'server');
        expect(find.byKey(const Key('servers-empty')), findsNothing);
        expect(find.text('backup.example.org · Timeweb'), findsOneWidget);
        expect(find.text('Резерв'), findsOneWidget);
      },
    );

    testWidgets('сервис без проверок помечен; десктоп — панель справа', (
      tester,
    ) async {
      final c = await _pump(tester, size: desktopSize);
      await tester.runAsync(
        () => c
            .read(monitoringRepositoryProvider)
            .createService(
              const MonitorService(id: 'a1', serverId: srvA, name: 'Бот'),
            ),
      );
      await settleMonitoring(tester);
      expect(find.text('без проверок'), findsOneWidget);
      await tapKey(tester, 'server-add');
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byKey(const Key('server-name')), findsOneWidget);
    });
  });

  group('запись удалена на другом устройстве, пока открыта форма', () {
    Future<void> check(
      WidgetTester tester, {
      required String openKey,
      required String prefix,
      required Future<void> Function(MonitoringRepository repo) remove,
    }) async {
      final c = await _pump(tester);
      await tapKey(tester, openKey);
      await settleMonitoring(tester);
      await tester.runAsync(() => remove(c.read(monitoringRepositoryProvider)));
      await _save(tester, prefix);
      expect(find.byKey(Key('$prefix-error')), findsOneWidget);
      expect(find.text('Запись удалена на другом устройстве.'), findsOneWidget);
      // Форма не зависла: кнопка снова нажимается.
      final save = tester.widget<FilledButton>(find.byKey(Key('$prefix-save')));
      expect(save.onPressed, isNotNull);
    }

    testWidgets('сервер', (tester) async {
      await check(
        tester,
        openKey: 'server-edit-$srvA',
        prefix: 'server',
        remove: (r) => r.deleteServer(srvA),
      );
    });

    testWidgets('сервис', (tester) async {
      await check(
        tester,
        openKey: 'service-edit-$svcA',
        prefix: 'service',
        remove: (r) => r.deleteService(svcA),
      );
    });

    testWidgets('проверка', (tester) async {
      await check(
        tester,
        openKey: 'check-edit-$chkA',
        prefix: 'check',
        remove: (r) => r.deleteCheck(chkA),
      );
    });
  });

  group('редактор сервера', () {
    testWidgets(
      'адрес из внутренней сети: ошибка под полем сразу и при сохранении',
      (tester) async {
        final c = await _pump(tester, seed: false);
        await tapKey(tester, 'servers-empty-add');
        await _type(tester, 'server-name', 'Мой');
        await _type(tester, 'server-host', 'localhost');
        expect(find.textContaining('Имя без точки'), findsOneWidget);
        await _type(tester, 'server-host', '192.168.1.10');
        expect(find.textContaining('внутренней сети'), findsOneWidget);
        await _save(tester, 'server');
        expect(find.byKey(const Key('server-error')), findsOneWidget);
        expect(
          find.byKey(const Key('server-name')),
          findsOneWidget,
          reason: 'форма осталась',
        );
        expect(
          await c.read(monitoringRepositoryProvider).getServer('any'),
          isNull,
        );
        await _type(tester, 'server-host', '8.8.8.8');
        expect(
          find.descendant(
            of: find.byKey(const Key('server-host')),
            matching: find.textContaining('внутренней сети'),
          ),
          findsNothing,
        );
        await _save(tester, 'server');
        expect(find.byKey(const Key('server-name')), findsNothing);
        expect(find.text('8.8.8.8'), findsOneWidget);
      },
    );

    testWidgets('правка и удаление с подтверждением (каскад: сервисы уходят)', (
      tester,
    ) async {
      final c = await _pump(tester);
      await tapKey(tester, 'server-edit-$srvA');
      expect(find.text('Основной VPS'), findsWidgets);
      await _type(tester, 'server-name', 'Главный VPS');
      await _save(tester, 'server');
      expect(
        (await c.read(monitoringRepositoryProvider).getServer(srvA))!.name,
        'Главный VPS',
      );
      expect(find.text('Главный VPS'), findsOneWidget);

      await tapKey(tester, 'server-edit-$srvA');
      await tapKey(tester, 'server-delete');
      expect(find.byKey(const Key('confirm-dialog')), findsOneWidget);
      expect(
        find.textContaining(
          'Сервисы и проверки сервера уйдут в корзину на 30 дней',
        ),
        findsOneWidget,
      );
      await tapKey(tester, 'confirm-cancel');
      expect(
        await c.read(monitoringRepositoryProvider).getServer(srvA),
        isNotNull,
      );
      await tapKey(tester, 'server-delete');
      await tapKey(tester, 'confirm-ok');
      await settleMonitoring(tester);
      expect(
        await c.read(monitoringRepositoryProvider).getServer(srvA),
        isNull,
      );
      expect(find.byKey(const Key('servers-empty')), findsOneWidget);
      expect(find.byKey(const Key('service-edit-$svcA')), findsNothing);
    });

    testWidgets('сервер удалили на другом устройстве: «не найден»', (
      tester,
    ) async {
      await _pump(tester);
      final context = tester.element(find.byKey(const Key('pulse-screen')));
      unawaited(showServerEditor(context, serverId: 'нет-такого'));
      await settleMonitoring(tester);
      expect(find.textContaining('Сервер не найден'), findsOneWidget);
    });
  });

  group('редактор сервиса', () {
    testWidgets('создание: критичный, связь с проектом Работы, заметка', (
      tester,
    ) async {
      final c = await _pump(tester);
      late String projectId;
      await tester.runAsync(() async {
        final work = c.read(workRepositoryProvider);
        projectId = work.newId();
        await work.createProject(
          WorkProject(
            id: projectId,
            title: 'Бот разборов',
            status: ProjectStatus.active,
          ),
        );
      });
      await settleMonitoring(tester);
      await tapKey(tester, 'service-add-$srvA');
      await _type(tester, 'service-name', 'API');
      await tapKey(tester, 'service-critical');
      await tapKey(tester, 'service-project-$projectId');
      await _type(tester, 'service-note', 'prod');
      await _save(tester, 'service');
      final rows = (await tester.runAsync(
        () => c.read(syncStoreProvider).visibleRows('monitor_services'),
      ))!;
      final api = rows.firstWhere((r) => r['name'] == 'API');
      expect(api['server_id'], srvA);
      expect(api['critical'], isTrue);
      expect(api['work_project_id'], projectId);
      expect(api['note'], 'prod');
      expect(find.text('API'), findsOneWidget);
    });

    testWidgets(
      'правка: поля загружены, «Без проекта» снимает связь, пустое название — ошибка',
      (tester) async {
        final c = await _pump(tester);
        await tapKey(tester, 'service-edit-$svcA');
        expect(find.byKey(const Key('service-critical')), findsOneWidget);
        expect(
          tester
              .widget<SwitchListTile>(find.byKey(const Key('service-critical')))
              .value,
          isTrue,
        );
        await _type(tester, 'service-name', '  ');
        await _save(tester, 'service');
        expect(find.byKey(const Key('service-error')), findsOneWidget);
        expect(find.textContaining('название'), findsWidgets);
        await _type(tester, 'service-name', 'Сайт 2');
        await tapKey(tester, 'service-critical');
        await _save(tester, 'service');
        final s = (await c
            .read(monitoringRepositoryProvider)
            .getService(svcA))!;
        expect(s.name, 'Сайт 2');
        expect(s.critical, isFalse);
        expect(s.serverId, srvA);
      },
    );

    testWidgets(
      'удаление сервиса уносит проверки; предупреждение «Выключить» отсутствует',
      (tester) async {
        final c = await _pump(tester);
        await tapKey(tester, 'service-edit-$svcA');
        expect(
          find.textContaining('Пауза и «Выключить» не предусмотрены'),
          findsOneWidget,
        );
        await tapKey(tester, 'service-delete');
        await tapKey(tester, 'confirm-ok');
        await settleMonitoring(tester);
        expect(
          await c.read(monitoringRepositoryProvider).getService(svcA),
          isNull,
        );
        // Проверки скрыты вместе с сервисом (каскад делает сервер).
        expect(
          await c.read(syncStoreProvider).visibleRows('monitor_checks'),
          isEmpty,
        );
        expect(find.byKey(const Key('check-edit-$chkA')), findsNothing);
      },
    );

    testWidgets('сервис не найден', (tester) async {
      await _pump(tester);
      final context = tester.element(find.byKey(const Key('pulse-screen')));
      unawaited(showServiceEditor(context, serverId: srvA, serviceId: 'нет'));
      await settleMonitoring(tester);
      expect(find.textContaining('Сервис не найден'), findsOneWidget);
    });
  });

  group('форма проверки', () {
    Future<void> open(WidgetTester tester) async {
      await tapKey(tester, 'check-add-$svcA');
      expect(find.byKey(const Key('check-form')), findsOneWidget);
    }

    testWidgets(
      'HTTP: SSRF-ошибка видна сразу под полем; на сохранение не пускает',
      (tester) async {
        final c = await _pump(tester);
        await open(tester);
        await _type(tester, 'check-name', 'Здоровье');
        for (final (url, text) in [
          ('http://localhost', 'Имя без точки'),
          ('http://127.0.0.1:8080/', 'внутренней сети'),
          ('http://169.254.169.254/latest/meta-data/', 'внутренней сети'),
          ('http://metadata.google.internal/', 'Внутренняя зона'),
          ('https://user:pw@example.com/', 'Логин и пароль'),
          ('https://example.com/#top', 'Уберите «#…»'),
          ('https://example.com:99999/', 'Порт — число'),
          ('ftp://example.com', 'http://'),
          ('http://0x7f.0.0.1/', 'Неверное окончание'),
          ('http://[::1]/', 'внутренней сети'),
        ]) {
          await _type(tester, 'check-url', url);
          expect(find.textContaining(text), findsWidgets, reason: url);
        }
        await _save(tester, 'check');
        expect(find.byKey(const Key('check-error')), findsOneWidget);
        expect(
          await c.read(monitoringRepositoryProvider).getCheck('x'),
          isNull,
        );
        await _type(tester, 'check-url', 'https://example.com/health');
        await _save(tester, 'check');
        expect(find.byKey(const Key('check-form')), findsNothing);
        expect(find.text('Здоровье'), findsOneWidget);
        expect(
          find.text('HTTP · https://example.com/health · каждые 20 с'),
          findsOneWidget,
        );
      },
    );

    testWidgets('HTTP: ожидаемый код и ключевое слово записываются', (
      tester,
    ) async {
      final c = await _pump(tester);
      await open(tester);
      await _type(tester, 'check-name', 'API');
      await _type(tester, 'check-url', 'https://example.com/api');
      await _type(tester, 'check-status', '200');
      await _type(tester, 'check-keyword', 'two words');
      expect(find.textContaining('Нужно одно слово'), findsOneWidget);
      await _type(tester, 'check-keyword', 'ok');
      await _save(tester, 'check');
      final checks = await tester.runAsync(
        () => c.read(monitoringRepositoryProvider).getCheck(chkA),
      );
      expect(checks, isNotNull);
      final all = await tester.runAsync(
        () => c.read(syncStoreProvider).visibleRows('monitor_checks'),
      );
      final api = all!.firstWhere((r) => r['name'] == 'API');
      expect(api['expected_status'], 200);
      expect(api['keyword'], 'ok');
      expect(api['kind'], 'http');
      expect(api['host'], isNull);
    });

    testWidgets('TCP: хост и порт; порт вне диапазона — ошибка', (
      tester,
    ) async {
      final c = await _pump(tester);
      await open(tester);
      await tapKey(tester, 'check-kind-tcp');
      await _type(tester, 'check-name', 'База');
      await _type(tester, 'check-host', '10.0.0.5');
      expect(
        find.descendant(
          of: find.byKey(const Key('check-host')),
          matching: find.textContaining('внутренней сети'),
        ),
        findsOneWidget,
      );
      await _type(tester, 'check-host', 'db.example.com');
      await _type(tester, 'check-port', '70000');
      expect(find.text('От 1 до 65535'), findsOneWidget);
      await _save(tester, 'check');
      expect(find.byKey(const Key('check-error')), findsOneWidget);
      await _type(tester, 'check-port', '5432');
      await _save(tester, 'check');
      final row = (await tester.runAsync(
        () => c.read(syncStoreProvider).visibleRows('monitor_checks'),
      ))!.firstWhere((r) => r['name'] == 'База');
      expect(
        (row['kind'], row['host'], row['port'], row['url']),
        ('tcp', 'db.example.com', 5432, null),
      );
      expect(
        find.text('TCP · db.example.com:5432 · каждые 20 с'),
        findsOneWidget,
      );
    });

    testWidgets('DNS: тип записи и ожидаемое значение', (tester) async {
      final c = await _pump(tester);
      await open(tester);
      await tapKey(tester, 'check-kind-dns');
      await _type(tester, 'check-name', 'Почта');
      await _type(tester, 'check-host', 'example.com');
      await tapKey(tester, 'check-record-MX');
      await _type(tester, 'check-expected', 'bad value');
      expect(find.textContaining('Допустимы буквы'), findsOneWidget);
      await _type(tester, 'check-expected', 'mail.example.com');
      await _save(tester, 'check');
      final row = (await tester.runAsync(
        () => c.read(syncStoreProvider).visibleRows('monitor_checks'),
      ))!.firstWhere((r) => r['name'] == 'Почта');
      expect(
        (row['kind'], row['dns_record_type'], row['expected_value']),
        ('dns', 'MX', 'mail.example.com'),
      );
      expect(find.text('DNS · MX example.com · каждые 20 с'), findsOneWidget);
    });

    testWidgets('SSL: порт и минимум дней необязательны', (tester) async {
      final c = await _pump(tester);
      await open(tester);
      await tapKey(tester, 'check-kind-ssl');
      await _type(tester, 'check-name', 'Сертификат');
      await _type(tester, 'check-host', 'nas.lan');
      expect(find.textContaining('Внутренняя зона'), findsOneWidget);
      await _type(tester, 'check-host', 'example.com');
      await _type(tester, 'check-days', '400');
      expect(find.text('От 1 до 365'), findsOneWidget);
      await _type(tester, 'check-days', '30');
      await _save(tester, 'check');
      final row = (await tester.runAsync(
        () => c.read(syncStoreProvider).visibleRows('monitor_checks'),
      ))!.firstWhere((r) => r['name'] == 'Сертификат');
      expect(
        (row['kind'], row['ssl_min_days'], row['port']),
        ('ssl', 30, null),
      );
    });

    testWidgets('интервал и таймаут: границы и «таймаут меньше интервала»', (
      tester,
    ) async {
      await _pump(tester);
      await open(tester);
      await _type(tester, 'check-name', 'X');
      await _type(tester, 'check-url', 'https://example.com');
      await _type(tester, 'check-interval', '5');
      expect(find.text('От 10 до 3600'), findsOneWidget);
      await _type(tester, 'check-interval', '10');
      await _type(tester, 'check-timeout', '10');
      await _save(tester, 'check');
      expect(find.text('Таймаут должен быть меньше интервала'), findsOneWidget);
      await _type(tester, 'check-timeout', '31');
      expect(find.text('От 1 до 30'), findsOneWidget);
      await _type(tester, 'check-interval', '');
      await _save(tester, 'check');
      expect(find.byKey(const Key('check-error')), findsOneWidget);
    });

    testWidgets(
      'правка: вид зафиксирован, поля загружены; удаление уходит в корзину',
      (tester) async {
        final c = await _pump(tester);
        await tapKey(tester, 'check-edit-$chkA');
        expect(find.byKey(const Key('check-kind-fixed')), findsOneWidget);
        expect(find.byKey(const Key('check-kind-tcp')), findsNothing);
        expect(find.text('HTTP · вид не меняется'), findsOneWidget);
        expect(
          tester
              .widget<TextField>(
                find.descendant(
                  of: find.byKey(const Key('check-url')),
                  matching: find.byType(TextField),
                ),
              )
              .controller!
              .text,
          'https://example.com',
        );
        await _type(tester, 'check-interval', '60');
        await _save(tester, 'check');
        expect(
          (await c.read(monitoringRepositoryProvider).getCheck(chkA))!
              .intervalSeconds,
          60,
        );
        expect(find.textContaining('каждые 1 мин'), findsOneWidget);

        await tapKey(tester, 'check-edit-$chkA');
        await tapKey(tester, 'check-delete');
        expect(
          find.textContaining('Вид проверки не меняется: нужна другая'),
          findsOneWidget,
        );
        await tapKey(tester, 'confirm-ok');
        await settleMonitoring(tester);
        expect(
          await c.read(monitoringRepositoryProvider).getCheck(chkA),
          isNull,
        );
        expect(find.text('без проверок'), findsOneWidget);
      },
    );

    testWidgets('проверка не найдена; «Выключить» нет', (tester) async {
      await _pump(tester);
      final context = tester.element(find.byKey(const Key('pulse-screen')));
      unawaited(showCheckEditor(context, serviceId: svcA, checkId: 'нет'));
      await settleMonitoring(tester);
      expect(find.textContaining('Проверка не найдена'), findsOneWidget);
      expect(find.textContaining('Выключить'), findsNothing);
    });
  });
}
