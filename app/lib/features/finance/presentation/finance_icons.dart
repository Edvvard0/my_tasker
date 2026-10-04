import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';

/// Иконки категорий: ключ колонки `categories.icon` (имена из таблицы
/// 3.2 spec Этапа 5) -> иконка Lucide. Неизвестное имя — нейтральный тег.
const Map<String, IconData> categoryIcons = {
  'shopping_basket': LucideIcons.shoppingBasket,
  'restaurant': LucideIcons.utensils,
  'directions_bus': LucideIcons.bus,
  'home': LucideIcons.house,
  'wifi': LucideIcons.wifi,
  'medical_services': LucideIcons.heartPulse,
  'checkroom': LucideIcons.shirt,
  'movie': LucideIcons.clapperboard,
  'school': LucideIcons.graduationCap,
  'card_giftcard': LucideIcons.gift,
  'chair': LucideIcons.armchair,
  'subscriptions': LucideIcons.repeat,
  'directions_car': LucideIcons.car,
  'flight': LucideIcons.plane,
  'more_horiz': LucideIcons.ellipsis,
  'local_taxi': LucideIcons.carTaxiFront,
  'train': LucideIcons.trainFront,
  'local_gas_station': LucideIcons.fuel,
  'build': LucideIcons.wrench,
  'key': LucideIcons.key,
  'bolt': LucideIcons.zap,
  'medication': LucideIcons.pill,
  'stethoscope': LucideIcons.stethoscope,
  'payments': LucideIcons.banknote,
  'work': LucideIcons.briefcase,
  'redeem': LucideIcons.gift,
  'savings': LucideIcons.piggyBank,
  'tag': LucideIcons.tag,
  'wallet': LucideIcons.wallet,
  'coins': LucideIcons.coins,
  'receipt': LucideIcons.receipt,
  'target': LucideIcons.target,
};

IconData categoryIcon(String? name) => categoryIcons[name] ?? LucideIcons.tag;

IconData accountIcon(AccountKind kind) => switch (kind) {
  AccountKind.cash => LucideIcons.banknote,
  AccountKind.debitCard => LucideIcons.creditCard,
  AccountKind.creditCard => LucideIcons.creditCard,
  AccountKind.savings => LucideIcons.piggyBank,
  AccountKind.deposit => LucideIcons.vault,
  AccountKind.other => LucideIcons.wallet,
};

IconData txKindIcon(TxKind kind) => switch (kind) {
  TxKind.expense => LucideIcons.arrowUpRight,
  TxKind.income => LucideIcons.arrowDownLeft,
  TxKind.transfer => LucideIcons.arrowLeftRight,
};
