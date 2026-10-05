import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Данные Банков (spec `stage6_banks.md`, раздел 1): файлы `shared-data/banks`,
/// встроенные в приложение байт-в-байт (`app/assets/banks/`, их сверяет
/// `test/features/banks/banks_data_test.dart`). Правила — данные, не код:
/// новый формат уведомления = новая запись в файле.

/// Пути встроенных копий.
const String notificationRulesAsset = 'assets/banks/notification_rules.json';
const String merchantNormalizationAsset =
    'assets/banks/merchant_normalization.json';
const String categoryDictionaryAsset = 'assets/banks/category_dictionary.json';

/// Данные нормализации мерчанта (раздел 3).
@immutable
class MerchantNormalizationData {
  const MerchantNormalizationData({
    required this.legalForms,
    required this.cities,
    required this.countryCodes,
  });

  factory MerchantNormalizationData.fromJson(Map<String, Object?> json) =>
      MerchantNormalizationData(
        legalForms: {
          for (final w in json['legal_forms']! as List<Object?>) w! as String,
        },
        cities: [
          for (final city in json['cities']! as List<Object?>)
            [for (final w in city! as List<Object?>) w! as String],
        ],
        countryCodes: {
          for (final w in json['country_codes']! as List<Object?>) w! as String,
        },
      );

  final Set<String> legalForms;

  /// Города — последовательности слов (`санкт петербург`).
  final List<List<String>> cities;
  final Set<String> countryCodes;
}

/// Запись словаря категорий: ключ предустановленной категории и слова.
@immutable
class CategoryKeyword {
  const CategoryKeyword({required this.key, required this.words});

  final String key;
  final List<String> words;
}

/// Стартовый словарь автокатегорий (раздел 8).
@immutable
class CategoryDictionary {
  const CategoryDictionary({required this.keywords, required this.mcc});

  factory CategoryDictionary.fromJson(Map<String, Object?> json) =>
      CategoryDictionary(
        keywords: [
          for (final e in json['keywords']! as List<Object?>)
            CategoryKeyword(
              key: (e! as Map)['key']! as String,
              words: [
                for (final w in (e as Map)['words']! as List<Object?>)
                  w! as String,
              ],
            ),
        ],
        mcc: {
          for (final e in (json['mcc']! as Map).entries)
            e.key as String: e.value as String,
        },
      );

  /// Порядок записей — приоритет.
  final List<CategoryKeyword> keywords;
  final Map<String, String> mcc;
}

/// Образец правила уведомления (`expected` — подмножество результата).
@immutable
class NotificationSample {
  const NotificationSample({
    required this.title,
    required this.text,
    required this.expected,
  });

  final String title;
  final String text;
  final Map<String, Object?> expected;
}

/// Правило разбора уведомления (раздел 2.1).
@immutable
class NotificationRule {
  NotificationRule({
    required this.id,
    required this.kind,
    required this.pattern,
    required this.groups,
    required this.samples,
    this.titles,
    this.currencyFixed,
    this.merchantFixed,
    this.refund = false,
    this.ignoreCase = false,
  }) : regex = RegExp(pattern, caseSensitive: !ignoreCase);

  factory NotificationRule.fromJson(Map<String, Object?> json) =>
      NotificationRule(
        id: json['id']! as String,
        kind: json['kind']! as String,
        pattern: json['pattern']! as String,
        groups: {
          for (final e in ((json['groups'] as Map?) ?? const {}).entries)
            e.key as String: e.value as int,
        },
        titles: json['title'] == null
            ? null
            : [for (final t in json['title']! as List<Object?>) t! as String],
        currencyFixed: json['currency_fixed'] as String?,
        merchantFixed: json['merchant_fixed'] as String?,
        refund: json['refund'] == true,
        ignoreCase: json['ignore_case'] == true,
        samples: [
          for (final s in (json['samples'] as List<Object?>?) ?? const [])
            NotificationSample(
              title: (s! as Map)['title'] as String? ?? '',
              text: (s as Map)['text']! as String,
              expected: ((s['expected'] as Map?) ?? const {})
                  .cast<String, Object?>(),
            ),
        ],
      );

  final String id;

  /// `expense`, `income` или `ignore`.
  final String kind;
  final String pattern;

  /// Имя поля -> номер группы.
  final Map<String, int> groups;

  /// `null` — любой заголовок.
  final List<String>? titles;
  final String? currencyFixed;
  final String? merchantFixed;
  final bool refund;
  final bool ignoreCase;
  final List<NotificationSample> samples;

  /// Скомпилированное выражение; без `unicode`-режима: правила написаны в
  /// переносимом подмножестве (раздел 2.2).
  final RegExp regex;
}

/// Банк: пакеты Android-приложений и правила.
@immutable
class BankRules {
  const BankRules({
    required this.id,
    required this.name,
    required this.packages,
    required this.rules,
  });

  final String id;
  final String name;
  final List<String> packages;
  final List<NotificationRule> rules;
}

/// Файл `notification_rules.json`.
@immutable
class NotificationRules {
  const NotificationRules({required this.currencies, required this.banks});

  factory NotificationRules.fromJson(Map<String, Object?> json) =>
      NotificationRules(
        currencies: {
          for (final e in (json['currencies']! as Map).entries)
            e.key as String: e.value as String,
        },
        banks: [
          for (final b in json['banks']! as List<Object?>)
            BankRules(
              id: (b! as Map)['id']! as String,
              name: (b as Map)['name']! as String,
              packages: [
                for (final p in b['packages']! as List<Object?>) p! as String,
              ],
              rules: [
                for (final r in b['rules']! as List<Object?>)
                  NotificationRule.fromJson(
                    (r! as Map).cast<String, Object?>(),
                  ),
              ],
            ),
        ],
      );

  /// Символ или код валюты -> ISO-код.
  final Map<String, String> currencies;
  final List<BankRules> banks;

  /// Белый список пакетов: слушатель обрабатывает только их.
  List<String> get packages => [for (final b in banks) ...b.packages];

  BankRules? bankOfPackage(String? package) {
    for (final b in banks) {
      if (b.packages.contains(package)) return b;
    }
    return null;
  }
}

/// Все данные Банков.
@immutable
class BankData {
  const BankData({
    required this.normalization,
    required this.dictionary,
    required this.notifications,
  });

  /// Из текстов трёх файлов.
  factory BankData.fromJsonStrings({
    required String normalization,
    required String dictionary,
    required String notifications,
  }) => BankData(
    normalization: MerchantNormalizationData.fromJson(_object(normalization)),
    dictionary: CategoryDictionary.fromJson(_object(dictionary)),
    notifications: NotificationRules.fromJson(_object(notifications)),
  );

  /// Из встроенных ассетов.
  static Future<BankData> load([AssetBundle? bundle]) async {
    final b = bundle ?? rootBundle;
    return BankData.fromJsonStrings(
      normalization: await b.loadString(merchantNormalizationAsset),
      dictionary: await b.loadString(categoryDictionaryAsset),
      notifications: await b.loadString(notificationRulesAsset),
    );
  }

  final MerchantNormalizationData normalization;
  final CategoryDictionary dictionary;
  final NotificationRules notifications;
}

Map<String, Object?> _object(String source) =>
    (jsonDecode(source) as Map).cast<String, Object?>();

/// Данные Банков из встроенных ассетов (тесты подменяют).
final FutureProvider<BankData> bankDataProvider = FutureProvider<BankData>(
  (ref) => BankData.load(),
);
