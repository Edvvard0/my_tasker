import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/banks/data/bank_pipeline.dart';
import 'package:my_tasker/features/banks/domain/bank_models.dart';
import 'package:my_tasker/features/banks/domain/bank_operations.dart';
import 'package:my_tasker/features/banks/domain/bank_rules.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_presets.dart';

import '../../support/banks_env.dart';
import '../../support/calendar_env.dart';
import '../../support/manual_clock.dart';

/// Конвейер уведомлений: уведомление → разбор → черновик → дедупликация →
/// остаток в точку сверки. Настоящая БД в памяти, без интерфейса.
void main() {
  late ManualClock clock;
  late BanksDevice d;
  late String tbankCard; // карта •••• 1234
  late String vtbCard; // карта •••• 5678

  DateTime at(int h, int m, [int s = 0]) => DateTime.utc(2026, 10, 3, h, m, s);

  setUp(() async {
    clock = ManualClock(DateTime.utc(2026, 10, 3, 12).millisecondsSinceEpoch);
    d = await BanksDevice.create(appServer(clock), clock: clock);
    await d.fin.finance.seedPresetCategories();
    Future<String> account(String name, String last4) async {
      final id = d.fin.finance.newId();
      await d.fin.finance.createAccount(
        Account(
          id: id,
          name: name,
          kind: AccountKind.debitCard,
          cardLast4: last4,
          openingBalance: 0,
          openingDate: '2026-01-01',
        ),
      );
      return id;
    }

    tbankCard = await account('Т-Банк', '1234');
    vtbCard = await account('ВТБ', '5678');
  });
  tearDown(() => d.close());

  Future<List<FinTransaction>> txs() async => [
    for (final r in await d.fin.device.store.visibleRows('transactions'))
      FinTransaction.fromRow(r),
  ];

  Future<List<BalanceCheckpoint>> checkpoints() async => [
    for (final r in await d.fin.device.store.visibleRows('balance_checkpoints'))
      BalanceCheckpoint.fromRow(r),
  ];

  const purchase =
      'Покупка на 1 234,56 ₽, Пятёрочка. Карта *1234. Доступно 10 000,50 ₽';

  test('чужой пакет и служебное уведомление: ничего не создаётся', () async {
    expect(
      await d.pipeline.process(raw('x.y', 'Покупка', purchase, at(8, 30))),
      ProcessOutcome.ignored,
    );
    expect(
      await d.pipeline.process(
        raw(tbankPackage, 'Акция', 'Скидки до 30%', at(8, 31)),
      ),
      ProcessOutcome.ignored,
    );
    expect(await txs(), isEmpty);
    expect(await d.notifications.count(), 0);
  });

  test(
    'покупка → черновик на счёте по card_last4, остаток → точка сверки',
    () async {
      final out = await d.pipeline.process(
        raw(tbankPackage, 'Покупка', purchase, at(8, 30, 15)),
      );
      expect(out, ProcessOutcome.draftCreated);
      final tx = (await txs()).single;
      expect(tx.status, TxStatus.draft);
      expect(tx.source, TxSource.notification);
      expect(tx.kind, TxKind.expense);
      expect(tx.accountId, tbankCard);
      expect(tx.amount, 123456);
      expect(tx.merchant, 'Пятёрочка');
      expect(tx.occurredAt, at(8, 30, 15));
      // Автокатегория по словарю.
      expect(tx.categoryId, categoryPresetId('expense.groceries'));
      expect(
        tx.dedupHash,
        dedupHash(
          d.data.normalization,
          accountId: tbankCard,
          kind: 'expense',
          amount: 123456,
          occurredAt: at(8, 30, 15),
          merchant: 'Пятёрочка',
        ),
      );
      final cp = (await checkpoints()).single;
      expect(cp.source, CheckpointSource.notification);
      expect(cp.accountId, tbankCard);
      expect(cp.actualBalance, 1000050);
      expect(cp.checkedAt, tx.occurredAt);
      // Исходный текст — только в локальной таблице.
      final stored = (await d.notifications.byState(
        NotificationState.processed,
      )).single;
      expect(stored.body, purchase);
      expect(stored.txId, tx.id);
    },
  );

  test('черновик не попадает в суммы; подтверждение — попадает, баланс '
      'совпадает с банком', () async {
    await d.pipeline.process(raw(tbankPackage, 'Покупка', purchase, at(8, 30)));
    final account = (await d.fin.finance.getAccount(tbankCard))!;
    var all = await txs();
    final draft = all.single;
    expect(effect(draft, tbankCard), 0);
    expect(countsInAnalytics(draft), isFalse);
    // Остаток из уведомления — точка сверки: баланс равен банковскому.
    expect(balanceAt(account, all, await checkpoints()), 1000050);

    await d.drafts.confirm(draft.id);
    all = await txs();
    expect(all.single.status, TxStatus.confirmed);
    expect(countsInAnalytics(all.single), isTrue);
    expect(effect(all.single, tbankCard), -123456);
    // Операция в момент точки сверки: баланс остаётся банковским.
    expect(balanceAt(account, all, await checkpoints()), 1000050);
  });

  test('повтор того же уведомления и повторная публикация в ту же минуту — '
      'одна операция', () async {
    final first = raw(tbankPackage, 'Покупка', purchase, at(8, 30, 5));
    expect(await d.pipeline.process(first), ProcessOutcome.draftCreated);
    expect(await d.pipeline.process(first), ProcessOutcome.alreadySeen);
    // Android переопубликовал уведомление: другое время публикации, та же минута.
    final repost = raw(tbankPackage, 'Покупка', purchase, at(8, 30, 5));
    expect(await d.pipeline.process(repost), ProcessOutcome.alreadySeen);
    expect(
      await d.pipeline.process(
        raw(tbankPackage, 'Покупка', purchase, at(8, 30, 40)),
      ),
      ProcessOutcome.duplicate,
    );
    expect(await txs(), hasLength(1));
    expect(await checkpoints(), hasLength(1));
  });

  test('две одинаковые покупки подряд — две операции', () async {
    await d.pipeline.process(raw(tbankPackage, 'Покупка', purchase, at(8, 30)));
    expect(
      await d.pipeline.process(
        raw(tbankPackage, 'Покупка', purchase, at(8, 36)),
      ),
      ProcessOutcome.draftCreated,
    );
    expect(await txs(), hasLength(2));
  });

  test(
    'уже есть ручная операция или строка выписки — черновик не создаётся',
    () async {
      final manual = d.fin.finance.newId();
      await d.fin.finance.createTransaction(
        FinTransaction(
          id: manual,
          kind: TxKind.expense,
          accountId: tbankCard,
          amount: 123456,
          occurredAt: at(8, 0),
          merchant: 'Пятерочка',
        ),
      );
      expect(
        await d.pipeline.process(
          raw(tbankPackage, 'Покупка', purchase, at(8, 30)),
        ),
        ProcessOutcome.duplicate,
      );
      expect(await txs(), hasLength(1));
      final stored = (await d.notifications.byState(
        NotificationState.processed,
      )).single;
      expect(stored.txId, manual);

      final statementTx = d.fin.finance.newId();
      await d.fin.finance.createTransaction(
        FinTransaction(
          id: statementTx,
          kind: TxKind.expense,
          accountId: tbankCard,
          amount: 5000,
          occurredAt: at(9, 0),
          merchant: 'Кофейня',
          source: TxSource.statement,
        ),
      );
      expect(
        await d.pipeline.process(
          raw(
            tbankPackage,
            'Покупка',
            'Покупка на 50 ₽, Кофейня. Карта *1234. Доступно 1 ₽',
            at(9, 5),
          ),
        ),
        ProcessOutcome.duplicate,
      );
    },
  );

  test(
    'карта не найдена: «нужен счёт», потом выбор счёта создаёт черновик',
    () async {
      const other = 'Покупка на 100 ₽, Магнит. Карта *9999. Доступно 500 ₽';
      expect(
        await d.pipeline.process(raw(tbankPackage, 'Покупка', other, at(9, 0))),
        ProcessOutcome.needsAccount,
      );
      expect(await txs(), isEmpty);
      expect(await checkpoints(), isEmpty);
      final pending = (await d.notifications.byState(
        NotificationState.needsAccount,
      )).single;
      expect(pending.reason, 'no_account');
      expect(pending.parsed!.amount, 10000);

      expect(
        await d.pipeline.assignAccount(pending, vtbCard),
        ProcessOutcome.draftCreated,
      );
      final tx = (await txs()).single;
      expect(tx.accountId, vtbCard);
      expect(tx.status, TxStatus.draft);
      expect((await checkpoints()).single.actualBalance, 50000);
      expect(
        await d.notifications.byState(NotificationState.needsAccount),
        isEmpty,
      );
      expect((await d.notifications.get(pending.id))!.txId, tx.id);
    },
  );

  test('assignAccount: не разобранное и удалённый счёт — ошибка', () async {
    await d.pipeline.process(
      raw(tbankPackage, 'Покупка', 'Что-то странное', at(9, 0)),
    );
    final unrecognized = (await d.notifications.byState(
      NotificationState.unrecognized,
    )).single;
    await expectLater(
      d.pipeline.assignAccount(unrecognized, tbankCard),
      throwsStateError,
    );
    await d.pipeline.process(
      raw(
        tbankPackage,
        'Покупка',
        'Покупка на 100 ₽, Магнит. Карта *9999. Доступно 500 ₽',
        at(9, 1),
      ),
    );
    final pending = (await d.notifications.byState(
      NotificationState.needsAccount,
    )).single;
    await expectLater(
      d.pipeline.assignAccount(pending, 'нет-такого-счёта'),
      throwsStateError,
    );
  });

  test('две карты с одинаковыми цифрами: «нужен счёт»', () async {
    final id = d.fin.finance.newId();
    await d.fin.finance.createAccount(
      Account(
        id: id,
        name: 'Копия',
        kind: AccountKind.creditCard,
        cardLast4: '1234',
        openingBalance: 0,
        openingDate: '2026-01-01',
      ),
    );
    expect(
      await d.pipeline.process(
        raw(tbankPackage, 'Покупка', purchase, at(9, 0)),
      ),
      ProcessOutcome.needsAccount,
    );
    expect(
      (await d.notifications.byState(NotificationState.needsAccount))
          .single
          .reason,
      'ambiguous_account',
    );
  });

  test('нераспознанное уведомление банка: в «Требует проверки» с исходным '
      'текстом, операции нет', () async {
    expect(
      await d.pipeline.process(
        raw(vtbPackage, 'ВТБ', 'Новый формат: 100 руб.', at(9, 0)),
      ),
      ProcessOutcome.unrecognized,
    );
    final n = (await d.notifications.byState(NotificationState.unrecognized))
        .single;
    expect(n.body, 'Новый формат: 100 руб.');
    expect(n.reason, 'no_rule');
    expect(await txs(), isEmpty);
  });

  test('чужая валюта: needs_review без точки сверки и с пояснением', () async {
    await d.pipeline.process(
      raw(
        tbankPackage,
        'Покупка',
        r'Покупка на 12,50 $, AMAZON.COM. Карта *1234. Доступно 9 000 ₽',
        at(10, 0),
      ),
    );
    final tx = (await txs()).single;
    expect(tx.status, TxStatus.needsReview);
    expect(tx.comment, contains('USD'));
    expect(tx.amount, 1250);
    expect(await checkpoints(), isEmpty);
  });

  test('возврат: доход с категорией расхода того же мерчанта', () async {
    await d.pipeline.process(
      raw(
        tbankPackage,
        'Возврат',
        'Возврат на 300 ₽, Магнит. Карта *1234. Доступно 5 000 ₽',
        at(10, 0),
      ),
    );
    final tx = (await txs()).single;
    expect(tx.kind, TxKind.income);
    expect(tx.categoryId, categoryPresetId('expense.groceries'));
  });

  test('время из текста (ВТБ) — в тот же московский день', () async {
    await d.pipeline.process(
      raw(
        vtbPackage,
        'ВТБ',
        'Оплата 100 ₽, 11:38, карта *5678, Магнит. Остаток 900 ₽',
        at(8, 40),
      ),
    );
    final tx = (await txs()).single;
    expect(tx.occurredAt, at(8, 38));
    expect(tx.accountId, vtbCard);
  });

  test('правило пользователя перекрывает словарь; «запомнить» создаёт '
      'правило, которое применяется к следующей операции', () async {
    await d.pipeline.process(raw(tbankPackage, 'Покупка', purchase, at(8, 30)));
    final first = (await txs()).single;
    expect(first.categoryId, categoryPresetId('expense.groceries'));
    // Пользователь выбрал другую категорию и запомнил мерчанта.
    await d.fin.finance.updateTransaction(
      first.copyWith(categoryId: categoryPresetId('expense.gifts')),
    );
    await d.drafts.confirm(first.id, remember: true);
    final rule = (await d.banks.rules()).single;
    expect(rule.merchantKey, 'пятерочка');
    expect(rule.kind, 'expense');
    expect(rule.matchType, 'exact');
    expect(rule.categoryId, categoryPresetId('expense.gifts'));

    await d.pipeline.process(raw(tbankPackage, 'Покупка', purchase, at(10, 0)));
    final second = (await txs()).firstWhere((t) => t.id != first.id);
    expect(second.categoryId, categoryPresetId('expense.gifts'));
  });

  test('«запомнить» без мерчанта или категории не создаёт правила', () async {
    final id = d.fin.finance.newId();
    await d.fin.finance.createTransaction(
      FinTransaction(
        id: id,
        kind: TxKind.expense,
        accountId: tbankCard,
        amount: 100,
        occurredAt: at(9, 0),
        status: TxStatus.draft,
        source: TxSource.notification,
      ),
    );
    await d.drafts.confirm(id, remember: true);
    expect(await d.banks.rules(), isEmpty);
    await expectLater(d.drafts.confirm('нет'), throwsStateError);
    // Мерчант из одних знаков: правило невозможно, подтверждение проходит.
    final digits = d.fin.finance.newId();
    await d.fin.finance.createTransaction(
      FinTransaction(
        id: digits,
        kind: TxKind.expense,
        accountId: tbankCard,
        amount: 100,
        occurredAt: at(9, 1),
        merchant: '***',
        categoryId: categoryPresetId('expense.gifts'),
        status: TxStatus.draft,
        source: TxSource.notification,
      ),
    );
    await d.drafts.confirm(digits, remember: true);
    expect(await d.banks.rules(), isEmpty);
    expect(
      (await d.fin.finance.getTransaction(digits))!.status,
      TxStatus.confirmed,
    );
  });

  test(
    'массовое подтверждение: только черновики; отклонение — в корзину',
    () async {
      await d.pipeline.process(
        raw(tbankPackage, 'Покупка', purchase, at(8, 30)),
      );
      await d.pipeline.process(
        raw(
          tbankPackage,
          'Покупка',
          r'Покупка на 12,50 $, AMAZON.COM. Карта *1234. Доступно 9 000 ₽',
          at(10, 0),
        ),
      );
      await d.pipeline.process(
        raw(
          tbankPackage,
          'Покупка',
          'Покупка на 200 ₽, Магнит. Карта *1234. Доступно 8 000 ₽',
          at(11, 0),
        ),
      );
      final all = await txs();
      expect(all, hasLength(3));
      final confirmed = await d.drafts.confirmAll([
        for (final t in all) t.id,
        'нет-такой',
      ]);
      // needs_review и неизвестный id пропущены.
      expect(confirmed, 2);
      expect(
        (await txs()).where((t) => t.status == TxStatus.needsReview),
        hasLength(1),
      );
      final review = (await txs()).firstWhere(
        (t) => t.status == TxStatus.needsReview,
      );
      await d.drafts.reject(review.id);
      expect((await txs()).any((t) => t.id == review.id), isFalse);
    },
  );

  test('перевод между своими счетами: расход на одной карте и доход на '
      'другой склеиваются в один перевод', () async {
    await d.pipeline.process(
      raw(
        tbankPackage,
        'Перевод',
        'Перевод 5 000 ₽ Себе. Карта *1234. Доступно 20 000 ₽',
        at(9, 0),
      ),
    );
    await d.pipeline.process(
      raw(
        vtbPackage,
        'ВТБ',
        'Поступление 5 000 ₽. Карта *5678. Перевод себе. Баланс 5 000 RUB',
        at(9, 0, 40),
      ),
    );
    final all = await txs();
    expect(all, hasLength(2));
    final pairs = transferSuggestions(all);
    expect(pairs, hasLength(1));
    // «Не склеивать»: пара пропадает из предложений.
    expect(
      transferSuggestions(all, dismissed: {transferPairKey(pairs.single)}),
      isEmpty,
    );

    final id = await d.drafts.mergeTransfer(
      expenseId: pairs.single.expenseId,
      incomeId: pairs.single.incomeId,
    );
    final after = await txs();
    expect(after, hasLength(1));
    final transfer = after.single;
    expect(transfer.id, id);
    expect(transfer.kind, TxKind.transfer);
    expect(transfer.accountId, tbankCard);
    expect(transfer.toAccountId, vtbCard);
    expect(transfer.amount, 500000);
    expect(transfer.status, TxStatus.confirmed);
    // Перевод — не доход и не расход.
    expect(countsInAnalytics(transfer), isFalse);
    // Нельзя склеить то, что уже не расход+доход.
    await expectLater(
      d.drafts.mergeTransfer(expenseId: id, incomeId: id),
      throwsA(anything),
    );
  });

  test(
    'очистка: сырые уведомления старше 30 дней удаляются, свежие остаются',
    () async {
      await d.pipeline.process(
        raw(tbankPackage, 'Покупка', 'Что-то странное 1', at(9, 0)),
      );
      clock.advance(const Duration(days: 29));
      await d.pipeline.process(
        raw(tbankPackage, 'Покупка', 'Что-то странное 2', at(9, 1)),
      );
      expect(await d.notifications.count(), 2);
      expect(await d.notifications.purgeExpired(), 0);

      // Первому исполнилось 31 сутки, второму — 2.
      clock.advance(const Duration(days: 2));
      expect(await d.notifications.purgeExpired(), 1);
      final left = await d.notifications.byState(
        NotificationState.unrecognized,
      );
      expect(left.single.body, 'Что-то странное 2');

      // ingest чистит сам.
      clock.advance(const Duration(days: 40));
      final outcomes = await d.pipeline.ingest(const []);
      expect(outcomes, isEmpty);
      expect(await d.notifications.count(), 0);
    },
  );

  test('ingest: пачка обрабатывается по очереди; markDismissed убирает из '
      'списка', () async {
    final outcomes = await d.pipeline.ingest([
      raw(tbankPackage, 'Покупка', purchase, at(8, 30)),
      raw(tbankPackage, 'Покупка', 'Что-то странное', at(8, 31)),
      raw('x', 'a', 'b', at(8, 32)),
    ]);
    expect(outcomes, [
      ProcessOutcome.draftCreated,
      ProcessOutcome.unrecognized,
      ProcessOutcome.ignored,
    ]);
    final n = (await d.notifications.byState(NotificationState.unrecognized))
        .single;
    await d.notifications.markDismissed(n.id);
    expect(
      await d.notifications.byState(NotificationState.unrecognized),
      isEmpty,
    );
    expect(
      (await d.notifications.get(n.id))!.state,
      NotificationState.dismissed,
    );
    expect(await d.notifications.get('нет'), isNull);
  });
}
