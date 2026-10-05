import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

import '../support/banks_env.dart';

/// Golden-тесты Этапа 6 (только ключевые экраны, 04, 2.4): «Черновики» и
/// мастер импорта выписки. Эталоны — `files/banks_*.png`; обновление:
/// `flutter test --update-goldens test/goldens`.
Future<void> _shot(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('files/$name.png'));

Future<void> _drafts(ProviderContainer c, FinanceDemo demo) async {
  final repo = c.read(financeRepositoryProvider);
  Future<void> add({
    required int amount,
    required String merchant,
    required DateTime at,
    TxKind kind = TxKind.expense,
    TxStatus status = TxStatus.draft,
    TxSource source = TxSource.notification,
    String? account,
    String? category,
    String? comment,
  }) => repo.createTransaction(
    FinTransaction(
      id: repo.newId(),
      kind: kind,
      accountId: account ?? demo.bank,
      amount: amount,
      occurredAt: at,
      merchant: merchant,
      status: status,
      source: source,
      categoryId: category,
      comment: comment,
    ),
  );
  await add(
    amount: 123456,
    merchant: 'Пятёрочка',
    at: DateTime.utc(2026, 9, 30, 7, 30),
    category: groceriesId(),
  );
  await add(
    amount: 34900,
    merchant: 'Яндекс Go',
    at: DateTime.utc(2026, 9, 30, 6, 10),
    category: taxiId(),
  );
  await add(
    amount: 1250,
    merchant: 'AMAZON.COM',
    at: DateTime.utc(2026, 9, 29, 15, 20),
    status: TxStatus.needsReview,
    comment: 'Сумма в USD: 12,50. Укажите сумму в рублях.',
  );
  // Перевод между своими счетами: расход и доход с той же суммой.
  await add(
    amount: 500000,
    merchant: 'Перевод себе',
    at: DateTime.utc(2026, 9, 29, 9),
  );
  await add(
    amount: 500000,
    merchant: 'Поступление',
    at: DateTime.utc(2026, 9, 29, 9, 0, 40),
    kind: TxKind.income,
    account: demo.savings,
    source: TxSource.statement,
  );
}

void main() {
  group('Банки: черновики и импорт выписки', () {
    testWidgets('«Черновики» (телефон)', (tester) async {
      late FinanceDemo demo;
      await pumpBanks(
        tester,
        location: '/finance/banks/drafts',
        seedWith: (c) async {
          demo = await seedFinanceDemo(c);
          await _drafts(c, demo);
        },
      );
      expect(find.byKey(const Key('drafts-screen')), findsOneWidget);
      await _shot(tester, 'banks_drafts_phone');
    });

    testWidgets('мастер импорта: категории и дубликаты (телефон)', (
      tester,
    ) async {
      final parsed = statementOf(
        [
          serverLine(
            index: 0,
            occurredAt: '2026-09-10T09:00:00Z',
            kind: 'expense',
            amount: 50000,
            merchant: 'Кофе Дом',
            card: '1234',
            dateOnly: true,
          ),
          serverLine(
            index: 1,
            occurredAt: '2026-09-12T08:15:00Z',
            kind: 'income',
            amount: 1500000,
            merchant: 'Работодатель',
            card: '1234',
          ),
          serverLine(
            index: 2,
            occurredAt: '2026-09-14T10:00:00Z',
            kind: 'expense',
            amount: 99900,
            merchant: 'Лента',
            card: '1234',
          ),
          serverLine(
            index: 3,
            occurredAt: '2026-09-02T16:00:00Z',
            kind: 'expense',
            amount: 424990,
            merchant: 'Пятёрочка',
            card: '1234',
          ),
        ],
        cards: ['1234'],
      );
      await pumpBanks(
        tester,
        location: '/finance/banks/import',
        api: FakeStatementsApi(parsed),
        files: FakeStatementFileSource(pickedFile('tbank_sep.csv')),
        seedWith: (c) async {
          await seedFinanceDemo(c);
        },
      );
      await tapKey(tester, 'import-pick');
      await tapKey(tester, 'import-next-accounts');
      // «Пятёрочка» 4 249,90 ₽ 2 сентября уже есть в демо-данных (по сумме,
      // времени и мерчанту): отмечена как дубликат.
      expect(find.text('УЖЕ ЕСТЬ'), findsOneWidget);
      await _shot(tester, 'banks_import_review_phone');
    });
  });
}
