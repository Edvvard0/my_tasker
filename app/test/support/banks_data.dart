import 'dart:io';

import 'package:my_tasker/features/banks/domain/bank_data.dart';

/// Данные Банков из встроенных копий `assets/banks/` (без `rootBundle`).
BankData loadBankDataSync() => BankData.fromJsonStrings(
  normalization: File(merchantNormalizationAsset).readAsStringSync(),
  dictionary: File(categoryDictionaryAsset).readAsStringSync(),
  notifications: File(notificationRulesAsset).readAsStringSync(),
);
