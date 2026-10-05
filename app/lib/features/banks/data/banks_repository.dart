import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart'
    show tableNamespace;
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/banks/domain/bank_data.dart';
import 'package:my_tasker/features/banks/domain/bank_rules.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart'
    show ValidationError;

/// Правила «мерчант → категория» (spec `stage6_banks.md`, раздел 7):
/// локальные записи через `SyncStore` (строка + HLC + outbox в одной
/// транзакции). Правило создаётся галочкой «запомнить для этого мерчанта»
/// при подтверждении операции.
class BanksRepository {
  BanksRepository(this._store);

  final SyncStore _store;

  static const String rulesTable = 'merchant_category_rules';

  /// Детерминированный `id` правила: два устройства, запомнившие одного
  /// мерчанта, создают одну строку (`uuid5(ns, kind|match_type|key)`).
  static String ruleId({
    required String kind,
    required String matchType,
    required String merchantKey,
  }) => uuid5(tableNamespace(rulesTable), '$kind|$matchType|$merchantKey');

  /// Запоминает категорию для мерчанта: нормализует имя, создаёт правило
  /// или меняет категорию существующего (в том числе из корзины).
  /// Бросает [ValidationError], если у имени нет ни одного слова.
  Future<String> rememberMerchant({
    required MerchantNormalizationData data,
    required String merchant,
    required String kind,
    required String categoryId,
    String matchType = 'exact',
  }) async {
    final key = normalizeMerchant(data, merchant);
    if (key.isEmpty) {
      throw const ValidationError('У операции нет названия для правила');
    }
    if (key.length > 200) {
      throw const ValidationError('Название мерчанта длиннее 200 символов');
    }
    final id = ruleId(kind: kind, matchType: matchType, merchantKey: key);
    await _store.transaction(() async {
      final row = await _store.getRow(rulesTable, id);
      if (row == null) {
        await _store.create(rulesTable, id, {
          'merchant_key': key,
          'match_type': matchType,
          'kind': kind,
          'category_id': categoryId,
        });
        return;
      }
      if (row['deleted_at'] != null) await _store.restore(rulesTable, id);
      if (row['category_id'] != categoryId) {
        await _store.update(rulesTable, id, {'category_id': categoryId});
      }
    });
    return id;
  }

  Future<void> deleteRule(String id) => _store.softDelete(rulesTable, id);

  Future<List<UserCategoryRule>> rules() async => [
    for (final r in await _store.visibleRows(rulesTable)) ruleOf(r),
  ];

  static UserCategoryRule ruleOf(Map<String, Object?> row) => UserCategoryRule(
    id: (row['id'] as String?) ?? '',
    merchantKey: (row['merchant_key'] as String?) ?? '',
    matchType: (row['match_type'] as String?) ?? 'exact',
    kind: (row['kind'] as String?) ?? 'expense',
    categoryId: (row['category_id'] as String?) ?? '',
  );
}

final Provider<BanksRepository> banksRepositoryProvider =
    Provider<BanksRepository>(
      (ref) => BanksRepository(ref.watch(syncStoreProvider)),
    );

/// Правила пользователя (живые строки), по порядку создания.
final StreamProvider<List<UserCategoryRule>> userCategoryRulesProvider =
    StreamProvider<List<UserCategoryRule>>(
      (ref) => ref
          .watch(syncStoreProvider)
          .watchVisibleRows(
            BanksRepository.rulesTable,
            orderBy: 't.created_at, t.id',
          )
          .map((rows) => [for (final r in rows) BanksRepository.ruleOf(r)]),
    );

/// Данные Банков в виде, удобном репозиториям (без `AsyncValue`).
typedef BankDataLoader = Future<BankData> Function();
