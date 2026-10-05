import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/registered_tables.dart';
import 'package:my_tasker/core/sync/sync_engine.dart';
import 'package:my_tasker/core/sync/sync_table.dart';
import 'package:my_tasker/features/banks/data/banks_repository.dart';
import 'package:my_tasker/features/banks/domain/bank_rules.dart';
import 'package:my_tasker/features/finance/domain/finance_presets.dart';

import '../../support/banks_env.dart';
import '../../support/calendar_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/manual_clock.dart';

String _uuid(int n) =>
    '01900000-0000-7000-8000-${n.toString().padLeft(12, '0')}';

/// Таблица правил категорий через общий стек синхронизации и фейковый
/// сервер: детерминированный id, неизменяемые поля, два устройства.
void main() {
  late ManualClock clock;
  late FakeSyncServer server;
  late BanksDevice phone;
  late BanksDevice pc;
  var counter = 0;

  setUp(() async {
    clock = ManualClock(DateTime.utc(2026, 10, 5, 9).millisecondsSinceEpoch);
    server = appServer(clock);
    counter = 0;
    String next() => _uuid(5000 + ++counter);
    phone = await BanksDevice.create(server, clock: clock, newId: next);
    pc = await BanksDevice.create(server, clock: clock, newId: next);
  });
  tearDown(() async {
    await phone.close();
    await pc.close();
    await server.dispose();
  });

  Future<void> syncBoth() async {
    for (var i = 0; i < 3; i++) {
      expect(await phone.fin.device.sync(), SyncOutcome.success);
      expect(await pc.fin.device.sync(), SyncOutcome.success);
    }
    expect((await phone.fin.device.store.outboxSummary()).rejected, 0);
    expect((await pc.fin.device.store.outboxSummary()).rejected, 0);
  }

  test('реестр: таблица правил зарегистрирована, без родителей', () {
    final names = [for (final s in registeredSyncTables) s.name];
    expect(names, contains('merchant_category_rules'));
    final spec = registeredSyncTables.firstWhere(
      (s) => s.name == 'merchant_category_rules',
    );
    expect(spec.parents, isEmpty);
    expect(spec.column('merchant_key')!.immutable, isTrue);
    expect(spec.column('match_type')!.immutable, isTrue);
    expect(spec.column('kind')!.immutable, isTrue);
    expect(spec.column('category_id')!.immutable, isFalse);
    expect(spec.titleOf({'merchant_key': 'магнит'}), contains('магнит'));
    SyncRegistry(registeredSyncTables);
  });

  test(
    'детерминированный id совпадает с сервером (uuid5 от kind|match|key)',
    () {
      // Значение посчитано эталоном `tasker.banks.tables.rule_id`.
      expect(
        BanksRepository.ruleId(
          kind: 'expense',
          matchType: 'exact',
          merchantKey: 'пятерочка',
        ),
        '8ae15567-7672-5e41-96b6-d9b54b0619e1',
      );
    },
  );

  test(
    'правило на телефоне доезжает до ПК; два устройства, запомнившие одно '
    'и то же, дают одну строку; смена категории не отклоняется сервером',
    () async {
      final groceries = categoryPresetId('expense.groceries');
      final gifts = categoryPresetId('expense.gifts');
      final id = await phone.banks.rememberMerchant(
        data: phone.data.normalization,
        merchant: 'ООО «Пятёрочка» №1234 Москва',
        kind: 'expense',
        categoryId: groceries,
      );
      // Тот же мерчант, запомненный офлайн на втором устройстве.
      final same = await pc.banks.rememberMerchant(
        data: pc.data.normalization,
        merchant: 'ПЯТЁРОЧКА',
        kind: 'expense',
        categoryId: gifts,
      );
      expect(same, id);
      await syncBoth();
      for (final dev in [phone, pc]) {
        final rules = await dev.banks.rules();
        expect(rules, hasLength(1));
        expect(rules.single.id, id);
        expect(rules.single.merchantKey, 'пятерочка');
      }
      // Победила одна категория, на обоих устройствах одна и та же.
      expect(
        (await phone.banks.rules()).single.categoryId,
        (await pc.banks.rules()).single.categoryId,
      );

      // Пользователь передумал: меняется только category_id.
      await phone.banks.rememberMerchant(
        data: phone.data.normalization,
        merchant: 'Пятёрочка',
        kind: 'expense',
        categoryId: groceries,
      );
      // Повтор с той же категорией ничего не пишет.
      final before = (await phone.fin.device.store.outboxSummary()).pending;
      await phone.banks.rememberMerchant(
        data: phone.data.normalization,
        merchant: 'Пятёрочка',
        kind: 'expense',
        categoryId: groceries,
      );
      expect((await phone.fin.device.store.outboxSummary()).pending, before);
      await syncBoth();
      expect((await pc.banks.rules()).single.categoryId, groceries);

      // Правила разных видов — разные строки.
      await phone.banks.rememberMerchant(
        data: phone.data.normalization,
        merchant: 'Пятёрочка',
        kind: 'income',
        categoryId: categoryPresetId('income.other'),
      );
      await syncBoth();
      expect(await pc.banks.rules(), hasLength(2));
    },
  );

  test(
    'удалённое правило восстанавливается, когда мерчанта запоминают снова',
    () async {
      final groceries = categoryPresetId('expense.groceries');
      final id = await phone.banks.rememberMerchant(
        data: phone.data.normalization,
        merchant: 'Магнит',
        kind: 'expense',
        categoryId: groceries,
      );
      await phone.banks.deleteRule(id);
      expect(await phone.banks.rules(), isEmpty);
      await phone.banks.rememberMerchant(
        data: phone.data.normalization,
        merchant: 'Магнит',
        kind: 'expense',
        categoryId: categoryPresetId('expense.gifts'),
      );
      final rules = await phone.banks.rules();
      expect(rules.single.id, id);
      expect(rules.single.categoryId, categoryPresetId('expense.gifts'));
      await syncBoth();
      expect(await pc.banks.rules(), hasLength(1));
    },
  );

  test('имя без слов и слишком длинное имя отвергаются до записи', () async {
    await expectLater(
      phone.banks.rememberMerchant(
        data: phone.data.normalization,
        merchant: '***',
        kind: 'expense',
        categoryId: categoryPresetId('expense.gifts'),
      ),
      throwsA(anything),
    );
    await expectLater(
      phone.banks.rememberMerchant(
        data: phone.data.normalization,
        merchant: 'а' * 201,
        kind: 'expense',
        categoryId: categoryPresetId('expense.gifts'),
      ),
      throwsA(anything),
    );
    expect(await phone.banks.rules(), isEmpty);
  });

  test(
    'правила пользователя применяются к категориям на втором устройстве',
    () async {
      await phone.banks.rememberMerchant(
        data: phone.data.normalization,
        merchant: 'Кофейня Бодрый день',
        kind: 'expense',
        categoryId: categoryPresetId('expense.gifts'),
      );
      await syncBoth();
      final rules = await pc.banks.rules();
      final result = suggestCategory(
        pc.data,
        merchant: 'КОФЕЙНЯ «БОДРЫЙ ДЕНЬ» 77',
        mcc: null,
        kind: 'expense',
        userRules: rules,
      );
      expect(result.source, 'user');
      expect(result.categoryId, categoryPresetId('expense.gifts'));
    },
  );
}
