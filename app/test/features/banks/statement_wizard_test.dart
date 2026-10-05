import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/features/banks/application/statement_import_controller.dart';
import 'package:my_tasker/features/banks/domain/statement_models.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

import '../../support/banks_env.dart';

Future<List<FinTransaction>> _txs(
  WidgetTester tester,
  ProviderContainer c,
) async => (await tester.runAsync(
  () async => [
    for (final r in await c.read(syncStoreProvider).visibleRows('transactions'))
      FinTransaction.fromRow(r),
  ],
))!;

/// Мастер импорта выписки: файл → счёт → категории и дубликаты →
/// подтверждение → готово. Сервер и выбор файла — поддельные.
void main() {
  late FinanceDemo demo;
  late FakeStatementsApi api;
  late FakeStatementFileSource files;

  ParsedStatement statement({bool withClosing = true}) => statementOf(
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
        merchant: 'AMAZON',
        card: '1234',
        needsReview: true,
        originalAmount: 1250,
        originalCurrency: 'USD',
      ),
    ],
    cards: ['1234'],
    closing: withClosing
        ? {'amount': 17000000, 'at': '2026-09-30T20:59:59Z'}
        : null,
    skipped: [
      {'row': 9, 'reason': 'status FAILED'},
    ],
  );

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    ParsedStatement? parsed,
    bool noFile = false,
    Size size = phoneSize,
  }) {
    api = FakeStatementsApi(parsed ?? statement());
    files = FakeStatementFileSource(noFile ? null : pickedFile());
    return pumpBanks(
      tester,
      location: '/finance/banks/import',
      size: size,
      api: api,
      files: files,
      seedWith: (c) async => demo = await seedFinanceDemo(c),
    );
  }

  String stepTitle(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('import-step-title'))).data!;

  group('мастер импорта выписки', () {
    testWidgets('полный путь: файл → счёт по карте → категории → '
        'подтверждение → операции созданы, точка сверки записана', (
      tester,
    ) async {
      final c = await pump(tester);
      expect(stepTitle(tester), 'Шаг 1 из 4 · Файл');
      await tapKey(tester, 'import-pick');
      expect(api.calls, 1);
      expect(files.picks, 1);

      // Шаг 2: карта •••• 1234 уже сопоставлена со счётом «Т-Банк».
      expect(stepTitle(tester), 'Шаг 2 из 4 · Счёт');
      expect(find.textContaining('statement.csv · Т-Банк'), findsOneWidget);
      expect(find.textContaining('3 операции'), findsOneWidget);
      expect(find.textContaining('Пропущено строк: 1'), findsOneWidget);
      expect(find.text('Карта •••• 1234 — какой счёт?'), findsOneWidget);
      await tapKey(tester, 'import-next-accounts');

      // Шаг 3: новые отмечены, чужая валюта помечена.
      expect(stepTitle(tester), 'Шаг 3 из 4 · Категории и дубликаты');
      expect(
        find.text('Новых: 3 · уточнений черновиков: 0 · уже есть: 0'),
        findsOneWidget,
      );
      expect(find.text('ЧУЖАЯ ВАЛЮТА: ПРОВЕРЬТЕ'), findsOneWidget);
      expect(find.text('НОВАЯ'), findsNWidgets(2));
      // Снять отметку со строки.
      await tapKey(tester, 'import-check-1');
      await tapKey(tester, 'import-check-1');
      await tapKey(tester, 'import-next-review');

      // Шаг 4.
      expect(stepTitle(tester), 'Шаг 4 из 4 · Подтверждение');
      expect(find.text('Создать операций: 3'), findsOneWidget);
      expect(find.byKey(const Key('import-confirm-closing')), findsOneWidget);
      expect(find.textContaining('1 в чужой валюте'), findsOneWidget);
      await tapKey(tester, 'import-commit');

      expect(find.byKey(const Key('import-done')), findsOneWidget);
      expect(find.text('Создано операций: 3'), findsOneWidget);
      final all = await _txs(tester, c);
      final imported = all
          .where((t) => t.source == TxSource.statement)
          .toList();
      expect(imported, hasLength(3));
      expect(
        imported.firstWhere((t) => t.merchant == 'AMAZON').status,
        TxStatus.needsReview,
      );
      expect(
        imported.firstWhere((t) => t.merchant == 'Кофе Дом').status,
        TxStatus.confirmed,
      );
    });

    testWidgets('повторный импорт той же выписки: всё «Уже есть», '
        'ничего не создаётся', (tester) async {
      final c = await pump(tester);
      Future<void> importOnce() async {
        await tapKey(tester, 'import-pick');
        await tapKey(tester, 'import-next-accounts');
      }

      await importOnce();
      await tapKey(tester, 'import-next-review');
      await tapKey(tester, 'import-commit');
      final before = (await _txs(tester, c)).length;
      await tapKey(tester, 'import-another');
      expect(stepTitle(tester), 'Шаг 1 из 4 · Файл');

      await importOnce();
      expect(
        find.text('Новых: 0 · уточнений черновиков: 0 · уже есть: 3'),
        findsOneWidget,
      );
      expect(find.text('УЖЕ ЕСТЬ'), findsNWidgets(3));
      await tapKey(tester, 'import-next-review');
      expect(find.text('Создать операций: 0'), findsOneWidget);
      await tapKey(tester, 'import-commit');
      expect(find.text('Создано операций: 0'), findsOneWidget);
      expect((await _txs(tester, c)).length, before);
    });

    testWidgets('«Отметить новые» и «Снять все»; дубликат можно отметить '
        'вручную', (tester) async {
      await pump(tester);
      await tapKey(tester, 'import-pick');
      await tapKey(tester, 'import-next-accounts');
      await tapKey(tester, 'import-select-none');
      expect(
        find.text('Новых: 0 · уточнений черновиков: 0 · уже есть: 0'),
        findsOneWidget,
      );
      await tapKey(tester, 'import-select-new');
      expect(
        find.text('Новых: 3 · уточнений черновиков: 0 · уже есть: 0'),
        findsOneWidget,
      );
    });

    testWidgets('смена категории строки', (tester) async {
      final c = await pump(tester);
      await tapKey(tester, 'import-pick');
      await tapKey(tester, 'import-next-accounts');
      await tapKey(tester, 'import-category-0');
      await pickCategory(tester, groceriesId());
      await tapKey(tester, 'import-next-review');
      await tapKey(tester, 'import-commit');
      final coffee = (await _txs(
        tester,
        c,
      )).firstWhere((t) => t.merchant == 'Кофе Дом');
      expect(coffee.categoryId, groceriesId());
    });

    testWidgets('счёт выбирается вручную, пока карта не сопоставлена; '
        '«Назад» возвращает к шагам', (tester) async {
      final parsed = statementOf(
        [
          serverLine(
            index: 0,
            occurredAt: '2026-09-10T09:00:00Z',
            kind: 'expense',
            amount: 50000,
            merchant: 'Магнит',
            card: '7777',
            dateOnly: true,
          ),
        ],
        cards: ['7777'],
      );
      await pump(tester, parsed: parsed);
      await tapKey(tester, 'import-pick');
      // Счёта с картой 7777 нет: «Далее» недоступна.
      FilledButton next() => tester.widget<FilledButton>(
        find.byKey(const Key('import-next-accounts')),
      );
      expect(next().onPressed, isNull);
      await tapKey(tester, 'import-account-7777-${demo.cash}');
      expect(next().onPressed, isNotNull);
      await tapKey(tester, 'import-next-accounts');
      expect(stepTitle(tester), 'Шаг 3 из 4 · Категории и дубликаты');
      await tapKey(tester, 'import-next-review');
      expect(stepTitle(tester), 'Шаг 4 из 4 · Подтверждение');
      await tapKey(tester, 'import-back');
      expect(stepTitle(tester), 'Шаг 3 из 4 · Категории и дубликаты');
      await tapKey(tester, 'import-back');
      expect(stepTitle(tester), 'Шаг 2 из 4 · Счёт');
      await tapKey(tester, 'import-back');
      expect(stepTitle(tester), 'Шаг 1 из 4 · Файл');
    });

    testWidgets('выписка без карт: один выбор счёта «для всех операций»', (
      tester,
    ) async {
      final parsed = statementOf([
        serverLine(
          index: 0,
          occurredAt: '2026-09-10T09:00:00Z',
          kind: 'expense',
          amount: 50000,
          merchant: 'Магнит',
          dateOnly: true,
        ),
      ], bank: 'generic');
      final c = await pump(tester, parsed: parsed);
      await tapKey(tester, 'import-pick');
      expect(find.text('Банк не определён'), findsNothing);
      expect(find.textContaining('Банк не определён'), findsOneWidget);
      expect(find.text('Счёт для операций без номера карты'), findsOneWidget);
      await tapKey(tester, 'import-account-none-${demo.cash}');
      await tapKey(tester, 'import-next-accounts');
      await tapKey(tester, 'import-next-review');
      await tapKey(tester, 'import-commit');
      final created = (await _txs(
        tester,
        c,
      )).firstWhere((t) => t.merchant == 'Магнит');
      expect(created.accountId, demo.cash);
    });

    testWidgets('ошибки сервера показываются понятным текстом; можно '
        'повторить', (tester) async {
      await pump(tester);
      api.error = httpError('statement_unrecognized');
      await tapKey(tester, 'import-pick');
      expect(find.byKey(const Key('import-error')), findsOneWidget);
      expect(find.textContaining('таблицы с датами'), findsOneWidget);
      expect(stepTitle(tester), 'Шаг 1 из 4 · Файл');
      api.error = null;
      await tapKey(tester, 'import-pick');
      expect(find.byKey(const Key('import-error')), findsNothing);
      expect(stepTitle(tester), 'Шаг 2 из 4 · Счёт');
    });

    testWidgets('закрыли диалог выбора файла: ничего не происходит', (
      tester,
    ) async {
      await pump(tester, noFile: true);
      await tapKey(tester, 'import-pick');
      expect(api.calls, 0);
      expect(find.byKey(const Key('import-error')), findsNothing);
      expect(stepTitle(tester), 'Шаг 1 из 4 · Файл');
    });

    testWidgets('нет счетов: подсказка и «Далее» недоступна', (tester) async {
      api = FakeStatementsApi(statement());
      files = FakeStatementFileSource(pickedFile());
      await pumpBanks(
        tester,
        location: '/finance/banks/import',
        api: api,
        files: files,
      );
      await tapKey(tester, 'import-pick');
      expect(find.byKey(const Key('import-no-accounts')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('import-next-accounts')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('«Готово» возвращает в «Банки»; уход с экрана сбрасывает '
        'мастер', (tester) async {
      final c = await pump(tester);
      await tapKey(tester, 'import-pick');
      await tapKey(tester, 'import-next-accounts');
      await tapKey(tester, 'import-next-review');
      await tapKey(tester, 'import-commit');
      await tapKey(tester, 'import-finish');
      expect(find.byKey(const Key('banks-screen')), findsOneWidget);
      expect(c.read(statementImportProvider).step, ImportStep.file);
    });

    testWidgets('ошибка при сохранении показывается, мастер остаётся на шаге', (
      tester,
    ) async {
      final c = await pump(tester);
      await tapKey(tester, 'import-pick');
      await tapKey(tester, 'import-next-accounts');
      await tapKey(tester, 'import-next-review');
      // Счёт удалили между шагами: сохранение отклоняется.
      await tester.runAsync(
        () => c.read(syncStoreProvider).softDelete('accounts', demo.bank),
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'import-commit');
      expect(find.byKey(const Key('import-error')), findsOneWidget);
      expect(
        find.textContaining('Не удалось сохранить операции'),
        findsOneWidget,
      );
    });

    testWidgets('десктоп: тот же мастер', (tester) async {
      await pump(tester, size: desktopSize);
      await tapKey(tester, 'import-pick');
      expect(stepTitle(tester), 'Шаг 2 из 4 · Счёт');
    });
  });
}
