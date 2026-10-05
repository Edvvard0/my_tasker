import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/registered_tables.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_table.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/monitoring/data/monitoring_sync_specs.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_models.dart';

import '../../support/calendar_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/manual_clock.dart';
import '../../support/monitoring_env.dart';

String _uuid(int n) =>
    '01900000-0000-7000-8000-${n.toString().padLeft(12, '0')}';

/// Таблицы «Серверов» через общий стек синхронизации и фейковый сервер:
/// реестр, неизменяемые поля, два устройства, каскад «сервер -> сервисы ->
/// проверки», корзина.
void main() {
  late ManualClock clock;
  late FakeSyncServer server;
  late MonitoringDevice phone;
  late MonitoringDevice pc;
  var counter = 0;

  setUp(() async {
    clock = ManualClock(DateTime.utc(2026, 10, 5, 11).millisecondsSinceEpoch);
    server = appServer(clock);
    counter = 0;
    String next() => _uuid(9000 + ++counter);
    phone = await MonitoringDevice.create(server, clock: clock, newId: next);
    pc = await MonitoringDevice.create(server, clock: clock, newId: next);
  });
  tearDown(() async {
    await phone.close();
    await pc.close();
    await server.dispose();
  });

  Future<void> syncBoth() async {
    for (var i = 0; i < 3; i++) {
      expect(await phone.device.sync(), SyncOutcome.success);
      expect(await pc.device.sync(), SyncOutcome.success);
    }
    expect((await phone.device.store.outboxSummary()).rejected, 0);
    expect((await pc.device.store.outboxSummary()).rejected, 0);
  }

  Future<({String server, String service, String check})> seed(
    MonitoringDevice d,
  ) async {
    final s = await d.repo.createServer(
      MonitorServer(id: d.repo.newId(), name: 'VPS', host: 'example.com'),
    );
    final v = await d.repo.createService(
      MonitorService(
        id: d.repo.newId(),
        serverId: s,
        name: 'Сайт',
        critical: true,
      ),
    );
    final c = await d.repo.createCheck(
      MonitorCheck(
        id: d.repo.newId(),
        serviceId: v,
        kind: CheckKind.http,
        name: 'Главная',
        url: 'https://example.com/health',
        expectedStatus: 200,
        intervalSeconds: 20,
        timeoutSeconds: 5,
      ),
    );
    return (server: s, service: v, check: c);
  }

  group('реестр', () {
    test('три таблицы Этапа 9: порядок, родители и неизменяемые поля', () {
      expect(
        [for (final s in monitoringSyncSpecs) s.name],
        ['monitor_servers', 'monitor_services', 'monitor_checks'],
      );
      final all = [for (final s in registeredSyncTables) s.name];
      for (final s in monitoringSyncSpecs) {
        expect(all, contains(s.name));
      }
      // Родители вперёд.
      expect(
        all.indexOf('monitor_servers') < all.indexOf('monitor_services'),
        isTrue,
      );
      expect(
        all.indexOf('monitor_services') < all.indexOf('monitor_checks'),
        isTrue,
      );
      SyncRegistry(registeredSyncTables);
      Set<String> fixed(SyncTableSpec s) => {
        for (final c in s.columns)
          if (c.immutable) c.name,
      };
      expect(fixed(monitorServersSpec), isEmpty);
      expect(fixed(monitorServicesSpec), {'server_id'});
      expect(fixed(monitorChecksSpec), {'service_id', 'kind'});
      expect(monitorServersSpec.parents, isEmpty);
      expect(
        [
          for (final r in monitorServicesSpec.parents)
            (r.column, r.parentTable),
        ],
        [('server_id', 'monitor_servers')],
      );
      expect(
        [for (final r in monitorChecksSpec.parents) (r.column, r.parentTable)],
        [('service_id', 'monitor_services')],
      );
      // `work_project_id` — мягкая ссылка: не родитель.
      expect(monitorServicesSpec.column('work_project_id')!.nullable, isTrue);
      expect(monitorServicesSpec.column('critical')!.nullable, isFalse);
      expect(monitorChecksSpec.column('interval_seconds')!.nullable, isFalse);
      expect(monitorChecksSpec.column('url')!.nullable, isTrue);
    });

    test('заголовки строк в корзине — названия', () {
      expect(monitorServersSpec.titleOf({'name': 'VPS'}), 'VPS');
      expect(monitorServicesSpec.titleOf({'name': 'Сайт'}), 'Сайт');
      expect(monitorChecksSpec.titleOf({'name': 'Главная'}), 'Главная');
    });
  });

  group('запись и синхронизация', () {
    test(
      'круг двух устройств: цепочка попадает на второе устройство',
      () async {
        final ids = await seed(phone);
        expect((await phone.device.store.outboxSummary()).pending, 3);
        await syncBoth();

        final servers = await pc.device.store.visibleRows('monitor_servers');
        expect(servers.single['name'], 'VPS');
        final services = await pc.device.store.visibleRows('monitor_services');
        expect(services.single['server_id'], ids.server);
        expect(services.single['critical'], isTrue);
        final checks = await pc.device.store.visibleRows('monitor_checks');
        expect(checks.single['service_id'], ids.service);
        expect(checks.single['kind'], 'http');
        expect(checks.single['url'], 'https://example.com/health');
        expect(checks.single['expected_status'], 200);
        expect(checks.single['port'], isNull);
        expect(checks.single['keyword'], isNull);
        // На сервере — те же строки.
        expect(
          server.row('monitor_checks', ids.check)!['interval_seconds'],
          20,
        );
        expect((await pc.repo.getCheck(ids.check))!.name, 'Главная');
      },
    );

    test('правки разных полей двух устройств сливаются', () async {
      final ids = await seed(phone);
      await syncBoth();
      clock.advance(const Duration(minutes: 1));
      final a = (await phone.repo.getCheck(ids.check))!;
      await phone.repo.updateCheck(
        MonitorCheck(
          id: a.id,
          serviceId: a.serviceId,
          kind: a.kind,
          name: 'Главная страница',
          url: a.url,
          expectedStatus: a.expectedStatus,
          intervalSeconds: a.intervalSeconds,
          timeoutSeconds: a.timeoutSeconds,
        ),
      );
      clock.advance(const Duration(minutes: 1));
      final b = (await pc.repo.getCheck(ids.check))!;
      await pc.repo.updateCheck(
        MonitorCheck(
          id: b.id,
          serviceId: b.serviceId,
          kind: b.kind,
          name: b.name,
          url: b.url,
          expectedStatus: b.expectedStatus,
          keyword: 'ok',
          intervalSeconds: 30,
          timeoutSeconds: 5,
        ),
      );
      await syncBoth();
      for (final d in [phone, pc]) {
        final c = (await d.repo.getCheck(ids.check))!;
        expect(c.name, 'Главная страница');
        expect(c.keyword, 'ok');
        expect(c.intervalSeconds, 30);
      }
    });

    test('правка без изменений не создаёт операций', () async {
      final ids = await seed(phone);
      await syncBoth();
      final before = (await phone.device.store.outboxSummary()).pending;
      final check = (await phone.repo.getCheck(ids.check))!;
      await phone.repo.updateCheck(check);
      final service = (await phone.repo.getService(ids.service))!;
      await phone.repo.updateService(service);
      final srv = (await phone.repo.getServer(ids.server))!;
      await phone.repo.updateServer(srv);
      expect((await phone.device.store.outboxSummary()).pending, before);
    });

    test('пробелы обрезаются, пустые необязательные поля — null', () async {
      final id = await phone.repo.createServer(
        MonitorServer(
          id: phone.repo.newId(),
          name: '  VPS  ',
          host: ' Example.COM ',
          provider: '   ',
          note: ' заметка ',
        ),
      );
      final s = (await phone.repo.getServer(id))!;
      expect(s.name, 'VPS');
      expect(s.host, 'Example.COM');
      expect(s.provider, isNull);
      expect(s.note, 'заметка');
    });

    test('поля чужих видов не пишутся (проверка TCP без url)', () async {
      final ids = await seed(phone);
      final id = await phone.repo.createCheck(
        MonitorCheck(
          id: phone.repo.newId(),
          serviceId: ids.service,
          kind: CheckKind.tcp,
          name: 'База',
          host: 'db.example.com',
          port: 5432,
          url: 'https://stray.example.com',
          keyword: 'x',
          intervalSeconds: 20,
          timeoutSeconds: 5,
        ),
      );
      final c = (await phone.repo.getCheck(id))!;
      expect(c.url, isNull);
      expect(c.keyword, isNull);
      expect(c.port, 5432);
    });
  });

  group('проверки при записи — как на сервере', () {
    test(
      'цель из внутренней сети не записывается и не уходит в очередь',
      () async {
        final ids = await seed(phone);
        await syncBoth();
        final before = (await phone.device.store.outboxSummary()).pending;
        await expectLater(
          phone.repo.createServer(
            MonitorServer(id: _uuid(1), name: 'x', host: '192.168.0.10'),
          ),
          throwsA(isA<ValidationError>()),
        );
        await expectLater(
          phone.repo.createCheck(
            MonitorCheck(
              id: _uuid(2),
              serviceId: ids.service,
              kind: CheckKind.http,
              name: 'x',
              url: 'http://169.254.169.254/latest',
              intervalSeconds: 20,
              timeoutSeconds: 5,
            ),
          ),
          throwsA(isA<ValidationError>()),
        );
        await expectLater(
          phone.repo.updateServer(
            MonitorServer(id: ids.server, name: 'VPS', host: 'localhost'),
          ),
          throwsA(isA<ValidationError>()),
        );
        expect((await phone.device.store.outboxSummary()).pending, before);
      },
    );

    test('вид и сервис проверки не меняются', () async {
      final ids = await seed(phone);
      await expectLater(
        phone.repo.updateCheck(
          MonitorCheck(
            id: ids.check,
            serviceId: ids.service,
            kind: CheckKind.tcp,
            name: 'Главная',
            host: 'example.com',
            port: 80,
            intervalSeconds: 20,
            timeoutSeconds: 5,
          ),
        ),
        throwsA(
          isA<ValidationError>().having(
            (e) => e.message,
            'message',
            contains('Вид проверки не меняется'),
          ),
        ),
      );
      // На уровне хранилища неизменяемая колонка отвергается тоже.
      await expectLater(
        phone.device.store.update('monitor_checks', ids.check, {'kind': 'tcp'}),
        throwsArgumentError,
      );
      await expectLater(
        phone.device.store.update('monitor_services', ids.service, {
          'server_id': _uuid(5),
        }),
        throwsArgumentError,
      );
    });

    test('сервис без сервера и проверка без сервиса не создаются', () async {
      await expectLater(
        phone.repo.createService(
          MonitorService(id: _uuid(1), serverId: _uuid(2), name: 'x'),
        ),
        throwsA(isA<ValidationError>()),
      );
      await expectLater(
        phone.repo.createCheck(
          MonitorCheck(
            id: _uuid(3),
            serviceId: _uuid(4),
            kind: CheckKind.http,
            name: 'x',
            url: 'https://example.com',
            intervalSeconds: 20,
            timeoutSeconds: 5,
          ),
        ),
        throwsA(isA<ValidationError>()),
      );
      final ids = await seed(phone);
      await phone.repo.deleteServer(ids.server);
      await expectLater(
        phone.repo.createService(
          MonitorService(id: _uuid(6), serverId: ids.server, name: 'y'),
        ),
        throwsA(isA<ValidationError>()),
      );
      await expectLater(
        phone.repo.updateServer(
          MonitorServer(id: ids.server, name: 'z', host: 'example.com'),
        ),
        throwsStateError,
      );
    });
  });

  group('удаление, каскад и корзина', () {
    test('удаление сервера одной операцией скрывает сервисы и проверки на '
        'втором устройстве, восстановление возвращает', () async {
      final ids = await seed(phone);
      await syncBoth();
      clock.advance(const Duration(minutes: 1));
      final before = (await pc.device.store.outboxSummary()).pending;
      await pc.repo.deleteServer(ids.server);
      // Одна операция delete родителя, потомков клиент не трогает.
      expect((await pc.device.store.outboxSummary()).pending, before + 1);
      expect(await pc.device.store.visibleRows('monitor_services'), isEmpty);
      expect(await pc.device.store.visibleRows('monitor_checks'), isEmpty);
      await syncBoth();
      for (final d in [phone, pc]) {
        expect(await d.device.store.visibleRows('monitor_servers'), isEmpty);
        expect(await d.device.store.visibleRows('monitor_services'), isEmpty);
        expect(await d.device.store.visibleRows('monitor_checks'), isEmpty);
        expect(await d.repo.getCheck(ids.check), isNull);
      }
      // В корзине — один сервер (потомки показываются вместе с ним).
      final trash = await phone.device.store.trashItems();
      expect([for (final t in trash) t.title], contains('VPS'));

      clock.advance(const Duration(minutes: 1));
      await phone.repo.restoreServer(ids.server);
      await syncBoth();
      for (final d in [phone, pc]) {
        expect(
          await d.device.store.visibleRows('monitor_servers'),
          hasLength(1),
        );
        expect(
          await d.device.store.visibleRows('monitor_services'),
          hasLength(1),
        );
        expect(
          await d.device.store.visibleRows('monitor_checks'),
          hasLength(1),
        );
      }
    });

    test('удаление сервиса и проверки; повторное удаление безопасно', () async {
      final ids = await seed(phone);
      await syncBoth();
      await phone.repo.deleteCheck(ids.check);
      await phone.repo.deleteCheck(ids.check);
      expect(await phone.repo.getCheck(ids.check), isNull);
      await phone.repo.restoreCheck(ids.check);
      expect(await phone.repo.getCheck(ids.check), isNotNull);
      await phone.repo.deleteService(ids.service);
      expect(await phone.device.store.visibleRows('monitor_checks'), isEmpty);
      await syncBoth();
      expect(await pc.device.store.visibleRows('monitor_checks'), isEmpty);
      expect(await pc.repo.getService(ids.service), isNull);
      await phone.repo.restoreService(ids.service);
      await syncBoth();
      expect(await pc.device.store.visibleRows('monitor_checks'), hasLength(1));
    });

    test(
      'офлайн: правки копятся в очереди и уходят при синхронизации',
      () async {
        final ids = await seed(phone);
        final s = (await phone.repo.getService(ids.service))!;
        await phone.repo.updateService(
          s.copyWith(critical: false, note: 'тихо'),
        );
        // Правка ещё не отправленной строки сливается с её созданием.
        expect((await phone.device.store.outboxSummary()).pending, 3);
        expect(await pc.device.store.visibleRows('monitor_services'), isEmpty);
        await syncBoth();
        final got = (await pc.repo.getService(ids.service))!;
        expect(got.critical, isFalse);
        expect(got.note, 'тихо');
      },
    );
  });
}
