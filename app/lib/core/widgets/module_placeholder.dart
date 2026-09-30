import 'package:flutter/material.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';

/// Экран-заглушка раздела: заголовок + пустое состояние с указанием этапа
/// дорожной карты, на котором раздел будет реализован.
///
/// ЗАГЛУШКА: заменяется настоящим экраном на этапе [stage].
class ModulePlaceholder extends StatelessWidget {
  const ModulePlaceholder({
    required this.title,
    required this.icon,
    required this.description,
    required this.stage,
    this.color,
    this.parentLabel,
    this.onBack,
    this.actions = const [],
    this.header,
    this.extra,
    super.key,
  });

  final String title;
  final IconData icon;
  final String description;

  /// Номер этапа из `docs/04_DECISIONS_AND_ROADMAP.md`.
  final int stage;

  /// Цвет модуля для иконки.
  final Color? color;
  final String? parentLabel;
  final VoidCallback? onBack;
  final List<Widget> actions;

  /// Виджет над заглушкой (например, переключатель «Календарь / Задачи»).
  final Widget? header;

  /// Виджет под заглушкой (например, ссылки на вложенные экраны).
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      title: title,
      parentLabel: parentLabel,
      onBack: onBack,
      actions: actions,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?header,
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 320),
            child: EmptyState(
              icon: icon,
              iconColor: color,
              title: 'Здесь будет «$title»',
              message: '$description\nПоявится на этапе $stage.',
            ),
          ),
          ?extra,
        ],
      ),
    );
  }
}
