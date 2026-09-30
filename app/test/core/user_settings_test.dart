import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/settings/data/user_settings_repository.dart';

import '../support/fake_server/fake_sync_server.dart';
import '../support/manual_clock.dart';
import '../support/sync_env.dart';

void main() {
  late FakeSyncServer server;
  late ManualClock clock;
  late TestDevice a;
  late TestDevice b;
  late UserSettingsRepository repoA;
  late UserSettingsRepository repoB;
  late SyncStore storeA;

  setUp(() async {
    clock = ManualClock();
    server = FakeSyncServer(registry: testRegistry(), nowMs: clock.call);
    a = await TestDevice.create(server, clock: clock);
    b = await TestDevice.create(server, clock: clock);
    storeA = a.store;
    repoA = UserSettingsRepository(a.store);
    repoB = UserSettingsRepository(b.store);
  });
  tearDown(() async {
    await a.close();
    await b.close();
    await server.dispose();
  });

  test('ключи: правила spec 4.1', () {
    for (final ok in ['a', 'ui.theme', '0.a-b_c', 'a' * 100]) {
      expect(UserSettingsRepository.isValidKey(ok), isTrue, reason: ok);
    }
    for (final bad in ['', 'A', '.a', '-a', '_a', 'a b', 'a' * 101, 'ключ']) {
      expect(UserSettingsRepository.isValidKey(bad), isFalse, reason: bad);
    }
    expect(() => repoA.read('Bad Key'), throwsArgumentError);
    expect(() => repoA.set('', 1), throwsArgumentError);
    expect(() => repoA.remove('X'), throwsArgumentError);
    expect(() => repoA.contains('X'), throwsArgumentError);
    expect(() => repoA.watch('X'), throwsArgumentError);
  });

  test('чтение, запись, изменение, удаление, возврат', () async {
    expect(await repoA.read('ui.theme'), isNull);
    expect(await repoA.contains('ui.theme'), isFalse);
    await repoA.set('ui.theme', 'dark');
    expect(await repoA.read('ui.theme'), 'dark');
    expect(await repoA.contains('ui.theme'), isTrue);
    await repoA.set('ui.theme', {
      'mode': 'dark',
      'n': [1, 2],
    });
    expect(await repoA.read('ui.theme'), {
      'mode': 'dark',
      'n': [1, 2],
    });
    await repoA.set('other', null);
    expect(await repoA.contains('other'), isTrue);
    expect(await repoA.readAll(), {
      'other': null,
      'ui.theme': {
        'mode': 'dark',
        'n': [1, 2],
      },
    });
    await repoA.remove('ui.theme');
    expect(await repoA.read('ui.theme'), isNull);
    expect(await repoA.contains('ui.theme'), isFalse);
    await repoA.remove('ui.theme'); // повторное удаление — ничего
    await repoA.remove('never.existed');
    // запись в удалённый ключ возвращает его из корзины
    await repoA.set('ui.theme', 'light');
    expect(await repoA.read('ui.theme'), 'light');
    expect(await storeA.trashItems(), isEmpty);
  });

  test('одинаковое значение не создаёт операций', () async {
    await repoA.set('k', 1);
    await a.sync();
    await repoA.set('k', 1);
    expect(await storeA.outbox(), isEmpty);
  });

  test('слишком большое значение отклоняется', () async {
    await expectLater(repoA.set('big', 'x' * 20000), throwsArgumentError);
    await repoA.set('ok', 'x' * 1000);
  });

  test('id строки = uuid5(key), два устройства создают одну строку', () async {
    await repoA.set('ui.theme', 'from a');
    clock.advance(const Duration(seconds: 1));
    await repoB.set('ui.theme', 'from b');
    expect(
      (await storeA.getRow('user_settings', userSettingsId('ui.theme')))!['id'],
      '826e9351-d34d-5a3d-99d0-d20367415629',
    );
    expect(await a.sync(), SyncOutcome.success);
    expect(await b.sync(), SyncOutcome.success);
    expect(await a.sync(), SyncOutcome.success);
    final rows = server.snapshot('user_settings');
    expect(rows, hasLength(1));
    expect(rows.values.single['value'], 'from b');
    expect(await repoA.read('ui.theme'), 'from b');
    expect(await repoB.read('ui.theme'), 'from b');
    // проигравшее значение не пропало: оно в журнале конфликтов
    expect(server.conflicts.single.losingValue, 'from a');
  });

  test('watch следит за значением', () async {
    final seen = <Object?>[];
    final sub = repoA.watch('ui.theme').listen(seen.add);
    await pumpEventQueue();
    await repoA.set('ui.theme', 'dark');
    await pumpEventQueue();
    await repoA.remove('ui.theme');
    await pumpEventQueue();
    await sub.cancel();
    expect(seen.first, isNull);
    expect(seen, contains('dark'));
    expect(seen.last, isNull);
  });

  test(
    'настройка, изменённая на другом устройстве, доезжает и удаляется',
    () async {
      await repoA.set('sync.interval_minutes', 15);
      await a.sync();
      await b.sync();
      expect(await repoB.read('sync.interval_minutes'), 15);
      await repoB.remove('sync.interval_minutes');
      await b.sync();
      await a.sync();
      expect(await repoA.read('sync.interval_minutes'), isNull);
      expect((await storeA.trashItems()).single.title, 'sync.interval_minutes');
    },
  );
}
