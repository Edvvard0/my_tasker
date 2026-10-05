import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/banks/data/bank_pipeline.dart';
import 'package:my_tasker/features/banks/data/notification_store.dart';
import 'package:my_tasker/features/banks/domain/bank_models.dart';
import 'package:my_tasker/features/banks/domain/bank_operations.dart';
import 'package:my_tasker/features/banks/domain/bank_rules.dart';
import 'package:my_tasker/features/banks/domain/notification_engine.dart';
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
      // Точка сверки не создаётся, пока черновик не подтверждён (он может
      // оказаться дублем): без самой операции она давала бы ложную
      // корректировку.
      expect(await checkpoints(), isEmpty);
      // Результат разбора (остаток) хранится локально; исходный текст
      // стёрт — он больше не нужен.
      final stored = (await d.notifications.byState(
        NotificationState.processed,
      )).single;
      expect(stored.body, isEmpty);
      expect(stored.parsed!.balance, 1000050);
      expect(stored.txId, tx.id);

      // Подтверждение создаёт точку сверки на момент операции.
      await d.drafts.confirm(tx.id);
      final cp = (await checkpoints()).single;
      expect(cp.source, CheckpointSource.notification);
      expect(cp.accountId, tbankCard);
      expect(cp.actualBalance, 1000050);
      expect(cp.checkedAt, tx.occurredAt);
      expect((await d.notifications.get(stored.id))!.parsed, isNull);
    },
  );

  test('отклонённый черновик не оставляет точки сверки', () async {
    await d.pipeline.process(raw(tbankPackage, 'Покупка', purchase, at(8, 30)));
    final tx = (await txs()).single;
    await d.drafts.reject(tx.id);
    expect(await txs(), isEmpty);
    expect(await checkpoints(), isEmpty);
    expect(
      await d.notifications.byState(NotificationState.processed),
      hasLength(1),
    );
    expect(
      (await d.notifications.byState(NotificationState.processed))
          .single
          .parsed,
      isNull,
    );
  });

  test('точка сверки из уведомления не уходит в будущее', () async {
    // Часы банка опережают устройство: «11:38» при публикации в 8:40 МСК-дня
    // — не позже момента публикации.
    await d.pipeline.process(
      raw(
        vtbPackage,
        'ВТБ',
        'Оплата 100 ₽, 11:44, карта *5678, Магнит. Остаток 900 ₽',
        at(8, 40),
      ),
    );
    final tx = (await txs()).single;
    expect(tx.occurredAt, at(8, 40));
    // Устройство отстаёт от банка ещё сильнее: точка — не позже «сейчас».
    clock.ms = DateTime.utc(2026, 10, 3, 8, 30).millisecondsSinceEpoch;
    await d.drafts.confirm(tx.id);
    expect(
      (await checkpoints()).single.checkedAt,
      DateTime.utc(2026, 10, 3, 8, 30),
    );
  });

  test('черновик не попадает в суммы; подтверждение — попадает, баланс '
      'совпадает с банком', () async {
    await d.pipeline.process(raw(tbankPackage, 'Покупка', purchase, at(8, 30)));
    final account = (await d.fin.finance.getAccount(tbankCard))!;
    var all = await txs();
    final draft = all.single;
    expect(effect(draft, tbankCard), 0);
    expect(countsInAnalytics(draft), isFalse);
    expect(balanceAt(account, all, await checkpoints()), 0);

    await d.drafts.confirm(draft.id);
    all = await txs();
    expect(all.single.status, TxStatus.confirmed);
    expect(countsInAnalytics(all.single), isTrue);
    expect(effect(all.single, tbankCard), -123456);
    // Подтверждение создало точку сверки по остатку из уведомления на момент
    // операции: баланс равен банковскому.
    expect(balanceAt(account, all, await checkpoints()), 1000050);
  });

  test('повтор того же уведомления — одна операция', () async {
    final first = raw(tbankPackage, 'Покупка', purchase, at(8, 30, 5));
    expect(await d.pipeline.process(first), ProcessOutcome.draftCreated);
    expect(await d.pipeline.process(first), ProcessOutcome.alreadySeen);
    expect(await txs(), hasLength(1));
  });

  test('повторная публикация в другую минуту: тот же ключ и when — повтор, '
      'без ключа — повтор в пределах 2 минут', () async {
    final first = raw(
      tbankPackage,
      'Покупка',
      purchase,
      at(8, 30, 5),
      key: '0|bank|1|null|10',
      whenMs: 1000,
    );
    expect(await d.pipeline.process(first), ProcessOutcome.draftCreated);
    // Банк обновил то же уведомление через 7 минут: postTime другой.
    final repost = raw(
      tbankPackage,
      'Покупка',
      purchase,
      at(8, 37, 5),
      key: '0|bank|1|null|10',
      whenMs: 1000,
    );
    expect(await d.pipeline.process(repost), ProcessOutcome.alreadySeen);
    expect(await txs(), hasLength(1));

    // Без ключа: другая минута, но в пределах двух минут — повтор.
    const second = 'Покупка на 77 ₽, Кофейня. Карта *1234. Доступно 9 000 ₽';
    expect(
      await d.pipeline.process(
        raw(tbankPackage, 'Покупка', second, at(9, 0, 50)),
      ),
      ProcessOutcome.draftCreated,
    );
    expect(
      await d.pipeline.process(
        raw(tbankPackage, 'Покупка', second, at(9, 2, 40)),
      ),
      ProcessOutcome.alreadySeen,
    );
    expect(await txs(), hasLength(2));
    // Через три минуты — уже новая покупка.
    expect(
      await d.pipeline.process(raw(tbankPackage, 'Покупка', second, at(9, 4))),
      ProcessOutcome.draftCreated,
    );
    expect(await txs(), hasLength(3));
    // Другой ключ и другой when в разное время — новое уведомление.
    final other = raw(
      tbankPackage,
      'Покупка',
      purchase,
      at(10, 0),
      key: '0|bank|2|null|10',
      whenMs: 2000,
    );
    expect(await d.pipeline.process(other), ProcessOutcome.draftCreated);
  });

  test('в отпечатке нет исходного текста', () {
    final fp = NotificationStore.fingerprint(
      raw(tbankPackage, 'Покупка', purchase, at(8, 30), key: 'k', whenMs: 5),
    );
    expect(fp, isNot(contains('Пятёрочка')));
    expect(fp, matches(RegExp(r'^[0-9a-f]{32}:[0-9a-f]{16}$')));
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
    'точное совпадение (тот же хеш или id) — черновик не создаётся',
    () async {
      final hash = dedupHash(
        d.data.normalization,
        accountId: tbankCard,
        kind: 'expense',
        amount: 123456,
        occurredAt: at(8, 30),
        merchant: 'Пятёрочка',
      );
      final existing = d.fin.finance.newId();
      await d.fin.finance.createTransaction(
        FinTransaction(
          id: existing,
          kind: TxKind.expense,
          accountId: tbankCard,
          amount: 123456,
          occurredAt: at(8, 30),
          merchant: 'Пятёрочка',
          source: TxSource.statement,
          dedupHash: hash,
        ),
      );
      expect(
        await d.pipeline.process(
          raw(tbankPackage, 'Покупка', purchase, at(8, 30, 40)),
        ),
        ProcessOutcome.duplicate,
      );
      expect(await txs(), hasLength(1));
      final stored = (await d.notifications.byState(
        NotificationState.processed,
      )).single;
      expect(stored.txId, existing);
    },
  );

  test('нечёткое совпадение с ручной операцией или строкой выписки — не '
      'отбрасывается: черновик «возможный дубль»', () async {
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
      ProcessOutcome.possibleDuplicate,
    );
    final all = await txs();
    expect(all, hasLength(2));
    final draft = all.firstWhere((t) => t.id != manual);
    expect(draft.status, TxStatus.draft);
    final flagged = (await d.notifications.byState(
      NotificationState.possibleDuplicate,
    )).single;
    expect(flagged.txId, draft.id);
    expect(flagged.reason, 'possible_duplicate');
    expect(flagged.body, isEmpty);
    // Пока нет решения — точки сверки нет.
    expect(await checkpoints(), isEmpty);

    // «Это отдельная покупка» → подтвердить: остаток из уведомления
    // становится точкой сверки, пометка снимается.
    await d.drafts.confirm(draft.id);
    expect(
      await d.notifications.byState(NotificationState.possibleDuplicate),
      isEmpty,
    );
    expect((await checkpoints()).single.actualBalance, 1000050);

    // Строка выписки: тоже черновик с пометкой; «Это дубль» → отклонить.
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
      ProcessOutcome.possibleDuplicate,
    );
    final second = (await d.notifications.byState(
      NotificationState.possibleDuplicate,
    )).single;
    await d.drafts.reject(second.txId!);
    expect(
      await d.notifications.byState(NotificationState.possibleDuplicate),
      isEmpty,
    );
    expect(await checkpoints(), hasLength(1));
    expect((await txs()).any((t) => t.id == second.txId), isFalse);
  });

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
      expect(await checkpoints(), isEmpty);
      await d.drafts.confirm(tx.id);
      expect((await checkpoints()).single.actualBalance, 50000);
      expect(
        await d.notifications.byState(NotificationState.needsAccount),
        isEmpty,
      );
      expect((await d.notifications.get(pending.id))!.txId, tx.id);
    },
  );

  test('assignAccount: счёт в архиве — ошибка', () async {
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
    await d.fin.finance.setAccountArchived(vtbCard, archived: true);
    await expectLater(
      d.pipeline.assignAccount(pending, vtbCard),
      throwsStateError,
    );
    expect(await txs(), isEmpty);
  });

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

  test('склейка перевода, когда доход пришёл раньше расхода: перевод не '
      'считается второй раз на получателе', () async {
    await d.pipeline.process(
      raw(
        vtbPackage,
        'ВТБ',
        'Поступление 5 000 ₽. Карта *5678. Перевод себе. Баланс 5 000 RUB',
        at(9, 0),
      ),
    );
    await d.pipeline.process(
      raw(
        tbankPackage,
        'Перевод',
        'Перевод 5 000 ₽ Себе. Карта *1234. Доступно 20 000 ₽',
        at(9, 0, 40),
      ),
    );
    final all = await txs();
    final income = all.firstWhere((t) => t.kind == TxKind.income);
    final expense = all.firstWhere((t) => t.kind == TxKind.expense);
    expect(income.occurredAt.isBefore(expense.occurredAt), isTrue);
    await d.drafts.confirm(income.id);
    await d.drafts.confirm(expense.id);
    final cps = await checkpoints();
    expect(cps, hasLength(2));

    final id = await d.drafts.mergeTransfer(
      expenseId: expense.id,
      incomeId: income.id,
    );
    final after = await txs();
    final transfer = after.single;
    expect(transfer.id, id);
    // Перевод стоит в более раннем из двух моментов.
    expect(transfer.occurredAt, income.occurredAt);
    final vtb = (await d.fin.finance.getAccount(vtbCard))!;
    final tbank = (await d.fin.finance.getAccount(tbankCard))!;
    // Получатель: остаток 5 000 из банка — перевод уже в нём, второй раз
    // он не прибавляется (раньше было 10 000).
    expect(balanceAt(vtb, after, cps), 500000);
    expect(balanceAt(tbank, after, cps), 2000000);
  });

  test('очистка: закрытые уведомления старше 30 дней удаляются, нерешённые '
      'и свежие остаются', () async {
    await d.pipeline.process(raw(tbankPackage, 'Покупка', purchase, at(9, 0)));
    await d.pipeline.process(
      raw(tbankPackage, 'Покупка', 'Что-то странное 1', at(9, 1)),
    );
    clock.advance(const Duration(days: 29));
    await d.pipeline.process(
      raw(tbankPackage, 'Покупка', 'Что-то странное 2', at(9, 2)),
    );
    expect(await d.notifications.count(), 3);
    expect(await d.notifications.purgeExpired(), 0);

    // Первому исполнилось 31 сутки: обработанное удаляется, а не
    // распознанное остаётся — иначе настоящая операция молча пропала бы.
    clock.advance(const Duration(days: 2));
    expect(await d.notifications.purgeExpired(), 1);
    final left = await d.notifications.byState(NotificationState.unrecognized);
    expect(left.map((n) => n.body), contains('Что-то странное 1'));
    expect(left, hasLength(2));

    // Убранное пользователем теряет текст сразу и чистится по сроку.
    await d.notifications.markDismissed(left.first.id);
    expect((await d.notifications.get(left.first.id))!.body, isEmpty);
    clock.advance(const Duration(days: 40));
    final outcomes = await d.pipeline.ingest(const []);
    expect(outcomes, isEmpty);
    expect(await d.notifications.count(), 1);
    expect(
      await d.notifications.byState(NotificationState.unrecognized),
      hasLength(1),
    );
  });

  test('уведомление с нулевой суммой — не операция: «Не распознано»', () async {
    expect(
      await d.pipeline.process(
        raw(
          tbankPackage,
          'Покупка',
          'Покупка на 0 ₽, Магнит. Карта *1234',
          at(9, 0),
        ),
      ),
      ProcessOutcome.unrecognized,
    );
    expect(await txs(), isEmpty);
    final n = (await d.notifications.byState(NotificationState.unrecognized))
        .single;
    expect(n.reason, 'bad_amount');
    expect(n.body, contains('0 ₽'));
  });

  test(
    'сбой при обработке одного уведомления не теряет остаток пачки',
    () async {
      // Подменяем загрузку данных: первое уведомление роняет конвейер.
      var calls = 0;
      final failing = BankPipeline(
        loadData: () async {
          calls++;
          if (calls == 1) throw StateError('сбой');
          return d.data;
        },
        store: d.fin.device.store,
        finance: d.fin.finance,
        banks: d.banks,
        notifications: d.notifications,
      );
      final outcomes = await failing.ingest([
        raw(tbankPackage, 'Покупка', purchase, at(8, 30)),
        raw(
          tbankPackage,
          'Покупка',
          'Покупка на 200 ₽, Магнит. Карта *1234. Доступно 8 000 ₽',
          at(11, 0),
        ),
      ]);
      expect(outcomes, [ProcessOutcome.failed, ProcessOutcome.draftCreated]);
      expect(await txs(), hasLength(1));
      // Упавшее — в «Требует проверки» с исходным текстом.
      final saved = (await d.notifications.byState(
        NotificationState.unrecognized,
      )).single;
      expect(saved.reason, 'error');
      expect(saved.body, purchase);
    },
  );

  test('сбой, который нельзя сохранить: пачка не считается принятой', () async {
    final failing = BankPipeline(
      loadData: () async => throw StateError('сбой'),
      store: d.fin.device.store,
      finance: d.fin.finance,
      banks: d.banks,
      // Хранилище, в котором не получается записать ничего.
      notifications: _BrokenStore(d),
    );
    await expectLater(
      failing.ingest([raw(tbankPackage, 'Покупка', purchase, at(8, 30))]),
      throwsStateError,
    );
  });

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

/// Хранилище уведомлений, которое всегда «видит» новое и не может писать.
class _BrokenStore extends NotificationStore {
  _BrokenStore(BanksDevice d) : super(d.fin.device.db);

  @override
  Future<bool> seen(RawNotification raw) async => false;

  @override
  Future<BankNotification?> insert(
    RawNotification raw, {
    required NotificationState state,
    String? reason,
    NotificationParse? parsed,
    String? txId,
  }) async => throw StateError('диск недоступен');

  @override
  Future<int> purgeExpired() async => 0;
}
