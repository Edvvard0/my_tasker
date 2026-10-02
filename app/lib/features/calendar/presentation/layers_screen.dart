import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/data/calendar_repository.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';

/// Что сделать с событиями удаляемого слоя.
enum _DeleteChoice { move, deleteAll }

/// «Календари и слои» (Календарь › слои): видимость, порядок, создание,
/// переименование и удаление пользовательских слоёв. Системные слои
/// (Личное, Работа, Учёба, Задачи, Праздники России) удалять нельзя.
class LayersScreen extends ConsumerStatefulWidget {
  const LayersScreen({super.key});

  @override
  ConsumerState<LayersScreen> createState() => _LayersScreenState();
}

class _LayersScreenState extends ConsumerState<LayersScreen> {
  final _name = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    try {
      await ref.read(calendarRepositoryProvider).createLayer(name: _name.text);
      if (!mounted) return;
      setState(() {
        _name.clear();
        _error = null;
      });
    } on ValidationError catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _rename(CalendarLayer layer) async {
    final controller = TextEditingController(text: layer.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Переименовать', style: context.text.h3),
        content: FormTextField(
          key: const Key('layer-rename-field'),
          controller: controller,
          autofocus: true,
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const Key('layer-rename-ok'),
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null) return;
    try {
      await ref
          .read(calendarRepositoryProvider)
          .updateLayer(layer.id, name: name);
    } on ValidationError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _delete(CalendarLayer layer, List<CalendarLayer> all) async {
    final repo = ref.read(calendarRepositoryProvider);
    final count = await repo.eventCount(layer.id);
    if (!mounted) return;
    final target = all.firstWhere(
      (l) => !l.isVirtual && l.id != layer.id,
      orElse: () => layer,
    );
    final choice = await showDialog<_DeleteChoice>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('layer-delete-dialog'),
        title: Text('Удалить «${layer.name}»?', style: context.text.h3),
        content: Text(
          count == 0
              ? 'Слой пуст. Он попадёт в корзину на 30 дней.'
              : 'В слое $count ${_events(count)}. Перенести их в '
                    '«${target.name}» или удалить вместе со слоем '
                    '(корзина, 30 дней)?',
          style: context.text.body.copyWith(
            color: context.colors.textSecondary,
          ),
        ),
        actions: [
          ElevatedButton(
            key: const Key('layer-delete-cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
          if (count > 0 && target.id != layer.id)
            ElevatedButton(
              key: const Key('layer-delete-move'),
              onPressed: () => Navigator.of(context).pop(_DeleteChoice.move),
              child: Text('Перенести в «${target.name}»'),
            ),
          FilledButton(
            key: const Key('layer-delete-all'),
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.danger,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.of(context).pop(_DeleteChoice.deleteAll),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    if (choice == _DeleteChoice.move) {
      await repo.moveEvents(layer.id, target.id);
    }
    await repo.deleteLayer(layer.id);
  }

  String _events(int n) {
    final mod100 = n % 100;
    final mod10 = n % 10;
    if (mod100 >= 11 && mod100 <= 14) return 'событий';
    if (mod10 == 1) return 'событие';
    if (mod10 >= 2 && mod10 <= 4) return 'события';
    return 'событий';
  }

  Future<void> _move(List<CalendarLayer> layers, int index, int step) async {
    final ids = [for (final l in layers) l.id];
    final target = index + step;
    if (target < 0 || target >= ids.length) return;
    final id = ids.removeAt(index);
    ids.insert(target, id);
    await ref.read(calendarRepositoryProvider).reorderLayers(ids);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(calendarBootstrapProvider);
    final layers = ref.watch(calendarLayersProvider);
    final c = context.colors;
    final t = context.text;
    final Widget body;
    if (layers.isLoading && !layers.hasValue) {
      body = const ListSkeleton();
    } else if (layers.hasError && !layers.hasValue) {
      body = NoticeCard(
        key: const Key('layers-error'),
        label: 'Не загрузилось',
        tone: StatusTone.danger,
        text: 'Не удалось прочитать календари на устройстве.',
        actions: [
          FilledButton(
            onPressed: () => ref.invalidate(calendarLayersProvider),
            child: const Text('Повторить'),
          ),
        ],
      );
    } else if (layers.requireValue.isEmpty) {
      body = const EmptyState(
        key: Key('layers-empty'),
        icon: LucideIcons.calendar,
        title: 'Календарей пока нет',
        message: 'Системные календари появятся при первом открытии.',
      );
    } else {
      final list = layers.requireValue;
      body = Column(
        key: const Key('layers-list'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < list.length; i++) ...[
                  if (i > 0) Divider(color: c.borderDefault, height: 1),
                  _LayerTile(
                    layer: list[i],
                    first: i == 0,
                    last: i == list.length - 1,
                    onToggle: (v) => ref
                        .read(calendarRepositoryProvider)
                        .updateLayer(list[i].id, visible: v),
                    onUp: () => _move(list, i, -1),
                    onDown: () => _move(list, i, 1),
                    onRename: list[i].isSystem ? null : () => _rename(list[i]),
                    onDelete: list[i].isSystem
                        ? null
                        : () => _delete(list[i], list),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Text(
            'Новый календарь',
            style: t.bodyS.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s2),
          Row(
            children: [
              Expanded(
                child: FormTextField(
                  key: const Key('layer-new-field'),
                  controller: _name,
                  onSubmitted: (_) => _create(),
                  decoration: InputDecoration(
                    hintText: 'Например, «Спорт»',
                    errorText: _error,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              IconButton.filled(
                key: const Key('layer-new-add'),
                tooltip: 'Добавить календарь',
                onPressed: _create,
                icon: const Icon(LucideIcons.plus, size: 20),
              ),
            ],
          ),
        ],
      );
    }
    return ScreenScaffold(
      title: 'Календари',
      parentLabel: 'Календарь',
      onBack: () => context.go('/calendar'),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: body,
        ),
      ),
    );
  }
}

class _LayerTile extends StatelessWidget {
  const _LayerTile({
    required this.layer,
    required this.first,
    required this.last,
    required this.onToggle,
    required this.onUp,
    required this.onDown,
    required this.onRename,
    required this.onDelete,
  });

  final CalendarLayer layer;
  final bool first;
  final bool last;
  final ValueChanged<bool> onToggle;
  final VoidCallback onUp;
  final VoidCallback onDown;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final note = switch (layer.systemKey) {
      'tasks' => 'Показывает задачи со сроком',
      'holidays_ru' => 'Праздники и выходные РФ',
      _ => layer.isSystem ? 'Системный' : 'Мой календарь',
    };
    return Padding(
      key: Key('layer-${layer.id}'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s1,
      ),
      child: Row(
        children: [
          Switch(
            key: Key('layer-visible-${layer.id}'),
            value: layer.visible,
            onChanged: onToggle,
          ),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(layer.name, style: t.body),
                Text(note, style: t.bodyS.copyWith(color: c.textSecondary)),
              ],
            ),
          ),
          if (layer.isSystem)
            Icon(LucideIcons.lock, size: 16, color: c.textTertiary),
          IconButton(
            key: Key('layer-up-${layer.id}'),
            tooltip: 'Выше',
            onPressed: first ? null : onUp,
            icon: const Icon(LucideIcons.chevronUp, size: 18),
          ),
          IconButton(
            key: Key('layer-down-${layer.id}'),
            tooltip: 'Ниже',
            onPressed: last ? null : onDown,
            icon: const Icon(LucideIcons.chevronDown, size: 18),
          ),
          if (onRename != null)
            IconButton(
              key: Key('layer-rename-${layer.id}'),
              tooltip: 'Переименовать',
              onPressed: onRename,
              icon: const Icon(LucideIcons.pencil, size: 18),
            ),
          if (onDelete != null)
            IconButton(
              key: Key('layer-delete-${layer.id}'),
              tooltip: 'Удалить',
              onPressed: onDelete,
              icon: Icon(LucideIcons.trash2, size: 18, color: c.danger),
            ),
        ],
      ),
    );
  }
}

/// Лист «Слои» (кнопка в верхней панели календаря): быстрые галочки
/// видимости и переход к управлению.
class LayersSheet extends ConsumerWidget {
  const LayersSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layers = ref.watch(calendarLayersProvider).value ?? const [];
    final t = context.text;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Слои', style: t.h3),
            ),
          ),
          for (final l in layers)
            CheckboxListTile(
              key: Key('layer-check-${l.id}'),
              value: l.visible,
              title: Text(l.name, style: t.body),
              onChanged: (v) => ref
                  .read(calendarRepositoryProvider)
                  .updateLayer(l.id, visible: v ?? true),
            ),
          ListTile(
            key: const Key('layers-manage'),
            leading: const Icon(LucideIcons.settings2, size: 20),
            title: Text('Управление календарями', style: t.body),
            onTap: () {
              Navigator.of(context).pop();
              context.go('/calendar/layers');
            },
          ),
        ],
      ),
    );
  }
}
