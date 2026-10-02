import 'package:my_tasker/core/calendar_time/calendar_ids.dart';
import 'package:my_tasker/core/sync/ids.dart';

/// Предустановленные категории (spec Этапа 5, 3.2). Клиент создаёт их сам
/// с `id = uuid5(ns("categories"), system_key)`; названия и иконки —
/// стартовые значения, пользователь может их менять и удалять.
class PresetCategory {
  const PresetCategory(
    this.key,
    this.name,
    this.kind,
    this.icon, [
    this.parentKey,
  ]);

  /// `system_key` (неизменяем).
  final String key;
  final String name;

  /// `expense` | `income`.
  final String kind;

  /// Имя иконки из набора клиента.
  final String icon;

  /// `system_key` родителя (подкатегория) или `null`.
  final String? parentKey;

  /// Детерминированный id строки.
  String get id => presetCategoryId(key);

  /// `id` родительской предустановленной категории или `null`.
  String? get parentId =>
      parentKey == null ? null : presetCategoryId(parentKey!);
}

/// `uuid5(uuid5(NAMESPACE_URL, "urn:my-tasker:categories"), system_key)`.
String presetCategoryId(String systemKey) =>
    uuid5(tableNamespace('categories'), systemKey);

/// Таблица spec 3.2: родители вперёд, затем подкатегории.
const List<PresetCategory> presetCategories = [
  PresetCategory('expense.groceries', 'Продукты', 'expense', 'shopping_basket'),
  PresetCategory(
    'expense.eating_out',
    'Кафе и рестораны',
    'expense',
    'restaurant',
  ),
  PresetCategory('expense.transport', 'Транспорт', 'expense', 'directions_bus'),
  PresetCategory('expense.housing', 'Жильё и коммунальные', 'expense', 'home'),
  PresetCategory(
    'expense.communication',
    'Связь и интернет',
    'expense',
    'wifi',
  ),
  PresetCategory('expense.health', 'Здоровье', 'expense', 'medical_services'),
  PresetCategory('expense.clothes', 'Одежда и обувь', 'expense', 'checkroom'),
  PresetCategory('expense.entertainment', 'Развлечения', 'expense', 'movie'),
  PresetCategory('expense.education', 'Образование', 'expense', 'school'),
  PresetCategory('expense.gifts', 'Подарки', 'expense', 'card_giftcard'),
  PresetCategory('expense.home_goods', 'Дом и быт', 'expense', 'chair'),
  PresetCategory(
    'expense.subscriptions',
    'Подписки',
    'expense',
    'subscriptions',
  ),
  PresetCategory('expense.car', 'Авто', 'expense', 'directions_car'),
  PresetCategory('expense.travel', 'Путешествия', 'expense', 'flight'),
  PresetCategory('expense.other', 'Прочее', 'expense', 'more_horiz'),
  PresetCategory(
    'expense.transport.taxi',
    'Такси',
    'expense',
    'local_taxi',
    'expense.transport',
  ),
  PresetCategory(
    'expense.transport.public',
    'Общественный транспорт',
    'expense',
    'train',
    'expense.transport',
  ),
  PresetCategory(
    'expense.car.fuel',
    'Топливо',
    'expense',
    'local_gas_station',
    'expense.car',
  ),
  PresetCategory(
    'expense.car.service',
    'Обслуживание авто',
    'expense',
    'build',
    'expense.car',
  ),
  PresetCategory(
    'expense.housing.rent',
    'Аренда и ипотека',
    'expense',
    'key',
    'expense.housing',
  ),
  PresetCategory(
    'expense.housing.utilities',
    'Коммунальные услуги',
    'expense',
    'bolt',
    'expense.housing',
  ),
  PresetCategory(
    'expense.health.pharmacy',
    'Аптека',
    'expense',
    'medication',
    'expense.health',
  ),
  PresetCategory(
    'expense.health.doctors',
    'Врачи и анализы',
    'expense',
    'stethoscope',
    'expense.health',
  ),
  PresetCategory('income.salary', 'Зарплата', 'income', 'payments'),
  PresetCategory('income.projects', 'Доход с проектов', 'income', 'work'),
  PresetCategory('income.gifts', 'Подарки', 'income', 'redeem'),
  PresetCategory('income.interest', 'Проценты и кэшбэк', 'income', 'savings'),
  PresetCategory('income.other', 'Прочее', 'income', 'more_horiz'),
];
