import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/features/banks/data/banks_repository.dart';
import 'package:my_tasker/features/banks/data/statement_importer.dart';
import 'package:my_tasker/features/banks/data/statements_api.dart';
import 'package:my_tasker/features/banks/domain/bank_data.dart';
import 'package:my_tasker/features/banks/domain/statement_models.dart';
import 'package:my_tasker/features/banks/domain/statement_plan.dart';
import 'package:my_tasker/features/banks/platform/statement_file_source.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';

/// Шаги мастера импорта выписки.
enum ImportStep { file, accounts, review, confirm, done }

const Object _unset = Object();

/// Состояние мастера.
@immutable
class ImportState {
  const ImportState({
    this.step = ImportStep.file,
    this.busy = false,
    this.error,
    this.fileName,
    this.statement,
    this.accountOfCard = const {},
    this.items = const [],
    this.result,
  });

  final ImportStep step;
  final bool busy;
  final String? error;
  final String? fileName;
  final ParsedStatement? statement;

  /// `card_last4` -> счёт; ключ `null` — строки без номера карты.
  final Map<String?, String?> accountOfCard;
  final List<ImportItem> items;
  final ImportResult? result;

  /// Группы выбора счёта: найденные карты и (если есть строки без карты)
  /// «без номера карты».
  List<String?> get groups {
    final s = statement;
    if (s == null) return const [];
    final out = <String?>[...s.cards];
    if (s.cards.isEmpty || s.lines.any((l) => l.cardLast4 == null)) {
      out.add(null);
    }
    return out;
  }

  /// Для каждой группы выбран счёт.
  bool get allAccountsChosen =>
      groups.isNotEmpty && groups.every((g) => accountOfCard[g] != null);

  ImportState copyWith({
    ImportStep? step,
    bool? busy,
    Object? error = _unset,
    Object? fileName = _unset,
    Object? statement = _unset,
    Map<String?, String?>? accountOfCard,
    List<ImportItem>? items,
    Object? result = _unset,
  }) => ImportState(
    step: step ?? this.step,
    busy: busy ?? this.busy,
    error: identical(error, _unset) ? this.error : error as String?,
    fileName: identical(fileName, _unset) ? this.fileName : fileName as String?,
    statement: identical(statement, _unset)
        ? this.statement
        : statement as ParsedStatement?,
    accountOfCard: accountOfCard ?? this.accountOfCard,
    items: items ?? this.items,
    result: identical(result, _unset) ? this.result : result as ImportResult?,
  );
}

/// Мастер импорта выписки: файл → счёт → категории и дубликаты →
/// подтверждение. Файл уходит на сервер только для разбора и там не
/// хранится; создание операций — на устройстве.
class StatementImportController extends Notifier<ImportState> {
  @override
  ImportState build() => const ImportState();

  /// Шаг 1: выбор файла и разбор на сервере.
  Future<void> pickAndParse() async {
    if (state.busy) return;
    state = state.copyWith(busy: true, error: null);
    try {
      final file = await ref.read(statementFileSourceProvider).pick();
      if (file == null) {
        state = state.copyWith(busy: false);
        return;
      }
      if (file.bytes.length > maxStatementBytes) {
        state = state.copyWith(busy: false, error: statementTooBigText);
        return;
      }
      final statement = await ref.read(statementsApiProvider).parse(file.bytes);
      final accounts =
          ref.read(financeDataProvider).value?.activeAccounts ?? [];
      final mapping = <String?, String?>{};
      for (final card in statement.cards) {
        final matches = [
          for (final a in accounts)
            if (a.cardLast4 == card) a,
        ];
        mapping[card] = matches.length == 1 ? matches.single.id : null;
      }
      if (statement.cards.isEmpty && accounts.length == 1) {
        mapping[null] = accounts.single.id;
      }
      state = ImportState(
        step: ImportStep.accounts,
        fileName: file.name,
        statement: statement,
        accountOfCard: mapping,
      );
    } on Object catch (e) {
      state = state.copyWith(busy: false, error: statementErrorText(e));
    }
  }

  void setAccount(String? card, String? accountId) => state = state.copyWith(
    accountOfCard: {...state.accountOfCard, card: accountId},
  );

  /// Шаг 2 → 3: сопоставляет строки с существующими операциями.
  Future<void> toReview() async {
    final statement = state.statement;
    final finance = ref.read(financeDataProvider).value;
    if (statement == null || finance == null || !state.allAccountsChosen) {
      return;
    }
    state = state.copyWith(busy: true, error: null);
    try {
      final data = await ref.read(bankDataProvider.future);
      final rules = ref.read(userCategoryRulesProvider).value ?? const [];
      final items = planImport(
        data: data,
        lines: statement.lines,
        accountOfCard: state.accountOfCard,
        transactions: finance.transactions,
        rules: rules,
      );
      state = state.copyWith(
        busy: false,
        step: ImportStep.review,
        items: items,
      );
    } on Object catch (e) {
      state = state.copyWith(busy: false, error: statementErrorText(e));
    }
  }

  void toggle(int index) {
    final items = [...state.items];
    items[index] = items[index].copyWith(selected: !items[index].selected);
    state = state.copyWith(items: items);
  }

  void setCategory(int index, String? categoryId) {
    final items = [...state.items];
    items[index] = items[index].copyWith(categoryId: categoryId);
    state = state.copyWith(items: items);
  }

  /// Отметить всё, что не дубликат (или снять всё).
  void setAllSelected({required bool selected}) => state = state.copyWith(
    items: [
      for (final i in state.items)
        i.copyWith(selected: selected && i.accountId != null && !i.isDuplicate),
    ],
  );

  void toConfirm() => state = state.copyWith(step: ImportStep.confirm);

  /// Шаг назад (на «Файл» вернуться нельзя: выписка уже разобрана).
  void back() {
    final previous = switch (state.step) {
      ImportStep.confirm => ImportStep.review,
      ImportStep.review => ImportStep.accounts,
      ImportStep.accounts => ImportStep.file,
      _ => state.step,
    };
    state = previous == ImportStep.file
        ? const ImportState()
        : state.copyWith(step: previous, error: null);
  }

  /// Шаг 4: создаёт операции, уточняет черновики, пишет точку сверки.
  Future<void> commit() async {
    final statement = state.statement;
    if (statement == null || state.busy) return;
    state = state.copyWith(busy: true, error: null);
    try {
      final result = await ref
          .read(statementImporterProvider)
          .commit(statement: statement, items: state.items);
      state = state.copyWith(
        busy: false,
        step: ImportStep.done,
        result: result,
      );
    } on Object {
      state = state.copyWith(
        busy: false,
        error: 'Не удалось сохранить операции. Повторите попытку.',
      );
    }
  }

  void reset() => state = const ImportState();
}

final NotifierProvider<StatementImportController, ImportState>
statementImportProvider =
    NotifierProvider<StatementImportController, ImportState>(
      StatementImportController.new,
    );
