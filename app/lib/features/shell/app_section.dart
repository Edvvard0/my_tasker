import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Разделы верхнего уровня (02, раздел 3.1). Порядок = порядок веток роутера.
///
/// Первые [tabCount] — слоты плавающего таб-бара на телефоне; остальные
/// открываются через «Разделы» (сетка) и всегда есть в левой панели десктопа.
/// «Задачи» — вкладка внутри «Календаря», «Серверы» — внутри «Работы»,
/// поэтому отдельных разделов у них нет.
enum AppSection {
  today('Сегодня', LucideIcons.sun, '/today'),
  calendar('Календарь', LucideIcons.calendar, '/calendar'),
  work('Работа', LucideIcons.briefcase, '/work'),
  finance('Финансы', LucideIcons.wallet, '/finance'),
  ai('ИИ', LucideIcons.sparkles, '/ai'),
  study('Учёба', LucideIcons.graduationCap, '/study'),
  sleep('Сон', LucideIcons.moon, '/sleep'),
  settings('Настройки', LucideIcons.settings, '/settings');

  const AppSection(this.label, this.icon, this.path);

  /// Число слотов таб-бара на телефоне.
  static const int tabCount = 5;

  final String label;
  final IconData icon;
  final String path;

  /// Раздел есть в таб-баре телефона.
  bool get isTab => index < tabCount;

  /// Разделы таб-бара.
  static List<AppSection> get tabs => values.sublist(0, tabCount);

  /// Разделы левой панели: все, кроме «Настроек» (они внизу панели).
  static List<AppSection> get sidePanelMain =>
      values.where((s) => s != settings).toList();
}
