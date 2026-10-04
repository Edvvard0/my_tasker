import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

/// Выбор проекта (например, чтобы запустить таймер по задаче без проекта).
/// Возвращает id проекта или `null`, если закрыли.
Future<String?> showProjectPicker(
  BuildContext context, {
  String title = 'Выберите проект',
}) => showEditorSheet<String>(
  context,
  builder: (_) => ProjectPickerSheet(title: title),
);

class ProjectPickerSheet extends ConsumerWidget {
  const ProjectPickerSheet({required this.title, super.key});

  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final projects = [
      for (final p
          in ref.watch(workProjectsProvider).value ?? const <WorkProject>[])
        if (!p.archived && p.effectiveStatus != ProjectStatus.cancelled) p,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(title: title),
        Flexible(
          child: projects.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(AppSpacing.s6),
                  child: Text(
                    'Проектов пока нет. Создайте проект в разделе «Работа».',
                    key: const Key('project-picker-empty'),
                    style: context.text.body.copyWith(color: c.textSecondary),
                  ),
                )
              : ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: AppSpacing.s4),
                  children: [
                    for (final p in projects)
                      ListTile(
                        key: Key('project-picker-${p.id}'),
                        leading: Icon(
                          LucideIcons.folder,
                          size: 20,
                          color: c.textSecondary,
                        ),
                        title: Text(p.title, style: context.text.body),
                        subtitle: Text(
                          p.effectiveStatus.label,
                          style: context.text.caption.copyWith(
                            color: c.textSecondary,
                          ),
                        ),
                        onTap: () => Navigator.of(context).pop(p.id),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
