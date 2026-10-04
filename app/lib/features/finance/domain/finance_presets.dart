import 'package:flutter/foundation.dart';
import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/sync/ids.dart' show uuid5;
import 'package:my_tasker/core/sync/outbox_logic.dart' show Json;
import 'package:my_tasker/features/finance/domain/finance_models.dart';

/// Предустановленная категория (spec Этапа 5, 3.2): клиент создаёт её
/// сам с детерминированным `id = uuid5(ns("categories"), system_key)`, так
/// что два устройства, засевшие независимо, создают одну и ту же строку.
@immutable
class CategoryPreset {
  const CategoryPreset(
    this.key,
    this.name,
    this.kind,
    this.icon, {
    this.parentKey,
  });

  final String key;
  final String name;
  final CategoryKind kind;

  /// Имя иконки из набора клиента (`finance_icons.dart`).
  final String icon;
  final String? parentKey;

  String get id => categoryPresetId(key);
  String? get parentId =>
      parentKey == null ? null : categoryPresetId(parentKey!);

  /// Колонки строки `categories` (с неизменяемым `system_key`).
  Json toFields() => {
    'name': name,
    'kind': kind.wire,
    'parent_id': parentId,
    'icon': icon,
    'color': null,
    'system_key': key,
  };
}

/// Идентификатор предустановленной категории по `system_key`.
String categoryPresetId(String systemKey) =>
    uuid5(tableNamespace('categories'), systemKey);

/// Таблица 3.2: 15 расходов с подкатегориями и 5 доходов; родители
/// идут раньше детей.
const List<CategoryPreset> categoryPresets = [
  CategoryPreset(
    'expense.groceries',
    'Продукты',
    CategoryKind.expense,
    'shopping_basket',
  ),
  CategoryPreset(
    'expense.eating_out',
    'Кафе и рестораны',
    CategoryKind.expense,
    'restaurant',
  ),
  CategoryPreset(
    'expense.transport',
    'Транспорт',
    CategoryKind.expense,
    'directions_bus',
  ),
  CategoryPreset(
    'expense.housing',
    'Жильё и коммунальные',
    CategoryKind.expense,
    'home',
  ),
  CategoryPreset(
    'expense.communication',
    'Связь и интернет',
    CategoryKind.expense,
    'wifi',
  ),
  CategoryPreset(
    'expense.health',
    'Здоровье',
    CategoryKind.expense,
    'medical_services',
  ),
  CategoryPreset(
    'expense.clothes',
    'Одежда и обувь',
    CategoryKind.expense,
    'checkroom',
  ),
  CategoryPreset(
    'expense.entertainment',
    'Развлечения',
    CategoryKind.expense,
    'movie',
  ),
  CategoryPreset(
    'expense.education',
    'Образование',
    CategoryKind.expense,
    'school',
  ),
  CategoryPreset(
    'expense.gifts',
    'Подарки',
    CategoryKind.expense,
    'card_giftcard',
  ),
  CategoryPreset(
    'expense.home_goods',
    'Дом и быт',
    CategoryKind.expense,
    'chair',
  ),
  CategoryPreset(
    'expense.subscriptions',
    'Подписки',
    CategoryKind.expense,
    'subscriptions',
  ),
  CategoryPreset('expense.car', 'Авто', CategoryKind.expense, 'directions_car'),
  CategoryPreset(
    'expense.travel',
    'Путешествия',
    CategoryKind.expense,
    'flight',
  ),
  CategoryPreset('expense.other', 'Прочее', CategoryKind.expense, 'more_horiz'),
  CategoryPreset(
    'expense.transport.taxi',
    'Такси',
    CategoryKind.expense,
    'local_taxi',
    parentKey: 'expense.transport',
  ),
  CategoryPreset(
    'expense.transport.public',
    'Общественный транспорт',
    CategoryKind.expense,
    'train',
    parentKey: 'expense.transport',
  ),
  CategoryPreset(
    'expense.car.fuel',
    'Топливо',
    CategoryKind.expense,
    'local_gas_station',
    parentKey: 'expense.car',
  ),
  CategoryPreset(
    'expense.car.service',
    'Обслуживание авто',
    CategoryKind.expense,
    'build',
    parentKey: 'expense.car',
  ),
  CategoryPreset(
    'expense.housing.rent',
    'Аренда и ипотека',
    CategoryKind.expense,
    'key',
    parentKey: 'expense.housing',
  ),
  CategoryPreset(
    'expense.housing.utilities',
    'Коммунальные услуги',
    CategoryKind.expense,
    'bolt',
    parentKey: 'expense.housing',
  ),
  CategoryPreset(
    'expense.health.pharmacy',
    'Аптека',
    CategoryKind.expense,
    'medication',
    parentKey: 'expense.health',
  ),
  CategoryPreset(
    'expense.health.doctors',
    'Врачи и анализы',
    CategoryKind.expense,
    'stethoscope',
    parentKey: 'expense.health',
  ),
  CategoryPreset('income.salary', 'Зарплата', CategoryKind.income, 'payments'),
  CategoryPreset(
    'income.projects',
    'Доход с проектов',
    CategoryKind.income,
    'work',
  ),
  CategoryPreset('income.gifts', 'Подарки', CategoryKind.income, 'redeem'),
  CategoryPreset(
    'income.interest',
    'Проценты и кэшбэк',
    CategoryKind.income,
    'savings',
  ),
  CategoryPreset('income.other', 'Прочее', CategoryKind.income, 'more_horiz'),
];
