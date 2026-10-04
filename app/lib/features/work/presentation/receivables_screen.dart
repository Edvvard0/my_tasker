import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart';
import 'package:my_tasker/features/work/presentation/project_list.dart';
import 'package:my_tasker/features/work/presentation/work_widgets.dart';

/// «Мне должны» (02, 5.4.3): общий итог и долги по заказчикам — сумма
/// неоплаченных остатков по их проектам (spec 4.4). Лиды и отменённые
/// проекты ничего не должны; Рома — заказчик, как и остальные.
class ReceivablesScreen extends ConsumerWidget {
  const ReceivablesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(workDataProvider);
    return ScreenScaffold(
      key: const Key('receivables-screen'),
      title: 'Мне должны',
      parentLabel: 'Работа',
      onBack: () => workBack(context),
      child: data.when(
        loading: () => const ListSkeleton(),
        error: (error, _) => const WorkErrorCard(
          key: Key('receivables-error'),
          text: 'Не удалось прочитать данные на устройстве.',
        ),
        data: (d) => _Body(data: d),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.data});

  final WorkData data;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final r = data.receivablesAll;
    final clients = r.clients.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('ВСЕГО', style: t.overline.copyWith(color: c.textSecondary)),
              const SizedBox(height: AppSpacing.s1),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  formatAmount(r.total),
                  key: const Key('receivables-total'),
                  style: t.display,
                ),
              ),
              Text(
                clients == 0
                    ? 'Все проекты оплачены'
                    : '$clients ${pluralWord(clients, 'заказчик', 'заказчика', 'заказчиков')}',
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
            ],
          ),
        ),
        if (r.clients.isEmpty)
          const EmptyState(
            key: Key('receivables-empty'),
            icon: LucideIcons.wallet,
            title: 'Долгов нет',
            message:
                'Остатки появятся, когда у проектов «в работе», «пауза» или '
                '«завершён» будет неоплаченная сумма.',
          )
        else
          for (final g in r.clients) ...[
            _ClientCard(data: data, group: g),
            const SizedBox(height: AppSpacing.s2),
          ],
      ],
    );
  }
}

class _ClientCard extends StatelessWidget {
  const _ClientCard({required this.data, required this.group});

  final WorkData data;
  final DebtGroup group;

  String get _name {
    final id = group.clientId;
    if (id == null) return 'Заказчик не указан';
    return data.personById[id]?.name ?? 'Заказчик не указан';
  }

  Future<void> _copy(BuildContext context) async {
    final lines = [
      for (final p in group.projects)
        '${data.projectById[p.id]?.title ?? 'Проект'} — ${formatAmount(p.remaining)}',
    ];
    final text =
        'Привет! Напоминаю про оплату: ${formatAmount(group.remaining)}.\n'
        '${lines.join('\n')}';
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(content: Text('Текст напоминания скопирован')),
      );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final key = group.clientId ?? 'none';
    final count = group.projects.length;
    return AppCard(
      key: Key('receivable-$key'),
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s4,
              AppSpacing.s4,
              AppSpacing.s2,
              AppSpacing.s2,
            ),
            child: Row(
              children: [
                PersonAvatar(name: _name),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _name,
                        style: t.h3,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '$count ${pluralWord(count, 'проект', 'проекта', 'проектов')}',
                        style: t.bodyS.copyWith(color: c.textSecondary),
                      ),
                    ],
                  ),
                ),
                Text(
                  formatAmount(group.remaining),
                  key: Key('receivable-amount-$key'),
                  style: t.numL,
                ),
                IconButton(
                  key: Key('receivable-copy-$key'),
                  tooltip: 'Скопировать напоминание',
                  onPressed: () => _copy(context),
                  icon: const Icon(LucideIcons.copy, size: 18),
                ),
              ],
            ),
          ),
          for (final p in group.projects)
            InkWell(
              key: Key('receivable-project-${p.id}'),
              borderRadius: AppRadii.borderL,
              onTap: () => openProject(context, p.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s4,
                  vertical: AppSpacing.s2,
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 40 + AppSpacing.s3),
                    Expanded(
                      child: Text(
                        data.projectById[p.id]?.title ?? 'Проект',
                        style: t.bodyS.copyWith(color: c.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      formatAmount(p.remaining),
                      style: t.numM.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.s2),
        ],
      ),
    );
  }
}
