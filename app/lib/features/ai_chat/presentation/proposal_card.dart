import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/data/proposal_service.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/presentation/proposal_editor.dart';

/// Срок предложенной задачи словами: «Ср, 30 сент. · 15:00» или «Без срока».
String proposalDueText(Map<String, Object?> args) {
  final raw = args['due_date'];
  final date = raw is String ? parseDate(raw) : null;
  if (date == null) return 'Без срока';
  final time = args['due_time'];
  return time is String
      ? '${dayTitleShort(date)} · $time'
      : dayTitleShort(date);
}

/// Быстрые причины отказа (02, 5.2.5).
const List<String> rejectReasons = ['Не то время', 'Не нужна', 'Уже есть'];

/// Карточка «ИИ предлагает задачу» внутри ленты ответа (02, 5.2.5): синяя
/// обводка, поля предложения, «Изменить», «Отклонить», «Одобрить».
/// Решённое предложение сжимается в строку.
class ProposalCard extends ConsumerStatefulWidget {
  const ProposalCard({required this.proposal, this.onOpenTask, super.key});

  final ToolProposal proposal;

  /// Переход к созданной задаче; по умолчанию — список задач.
  final VoidCallback? onOpenTask;

  @override
  ConsumerState<ProposalCard> createState() => _ProposalCardState();
}

class _ProposalCardState extends ConsumerState<ProposalCard> {
  bool _busy = false;

  Future<void> _approve() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(proposalServiceProvider).approve(widget.proposal.id);
      messenger
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('Задача добавлена')));
    } on AiValidationError catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject() async {
    if (_busy) return;
    final reason = await showEditorSheet<String>(
      context,
      builder: (_) => const _RejectSheet(),
    );
    if (reason == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(proposalServiceProvider)
          .reject(widget.proposal.id, reason: reason);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.proposal;
    final c = context.colors;
    final t = context.text;
    if (p.status.isApproved) {
      return _DecidedRow(
        key: const Key('proposal-approved'),
        icon: LucideIcons.check,
        text: 'Задача создана · ${proposalDueText(p.arguments)}',
        action: TextButton(
          key: const Key('proposal-open'),
          onPressed: widget.onOpenTask ?? () => context.go('/calendar/tasks'),
          child: const Text('Открыть'),
        ),
      );
    }
    if (p.status == ProposalStatus.rejected) {
      final reason = p.rejectReason;
      return _DecidedRow(
        key: const Key('proposal-rejected'),
        icon: LucideIcons.x,
        text: reason == null || reason.isEmpty
            ? 'Отклонено'
            : 'Отклонено · $reason',
      );
    }
    final a = p.arguments;
    final duration = a['duration_minutes'];
    final priority = a['priority'];
    final tags = a['tags'];
    final notes = a['notes'];
    return Container(
      key: const Key('proposal-card'),
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: AppRadii.borderL,
        border: Border.all(color: c.accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.sparkles, size: 14, color: c.accent),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text(
                  'ИИ ПРЕДЛАГАЕТ ЗАДАЧУ',
                  style: t.overline.copyWith(color: c.textSecondary),
                ),
              ),
              if (p.isEdited)
                Row(
                  key: const Key('proposal-edited'),
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: c.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s1),
                    Text(
                      'изменено вами',
                      style: t.caption.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          Text(
            '${a['title'] ?? ''}',
            key: const Key('proposal-title-text'),
            style: t.h3,
          ),
          const SizedBox(height: AppSpacing.s3),
          Wrap(
            spacing: AppSpacing.s2,
            runSpacing: AppSpacing.s2,
            children: [
              _Chip(icon: LucideIcons.calendar, text: proposalDueText(a)),
              if (duration is int)
                _Chip(icon: LucideIcons.clock, text: durationText(duration)),
              if (priority is int)
                _Chip(icon: LucideIcons.flag, text: 'P$priority'),
              if (a['project'] is String)
                _Chip(icon: LucideIcons.folder, text: '${a['project']}'),
              if (tags is List)
                for (final tag in tags)
                  _Chip(icon: LucideIcons.hash, text: '$tag'),
            ],
          ),
          if (notes is String && notes.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s2),
            Text(
              notes,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: t.bodyS.copyWith(color: c.textSecondary),
            ),
          ],
          const SizedBox(height: AppSpacing.s4),
          Row(
            children: [
              OutlinedButton(
                key: const Key('proposal-reject'),
                onPressed: _busy ? null : _reject,
                child: const Text('Отклонить'),
              ),
              IconButton(
                key: const Key('proposal-edit'),
                tooltip: 'Изменить',
                onPressed: _busy ? null : () => showProposalEditor(context, p),
                icon: const Icon(LucideIcons.pencil, size: 20),
              ),
              const Spacer(),
              ElevatedButton(
                key: const Key('proposal-approve'),
                onPressed: _busy ? null : _approve,
                child: const Text('Одобрить'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s1,
      ),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: AppRadii.borderFull,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: c.textSecondary),
          const SizedBox(width: AppSpacing.s1),
          Text(text, style: context.text.bodyS),
        ],
      ),
    );
  }
}

class _DecidedRow extends StatelessWidget {
  const _DecidedRow({
    required this.icon,
    required this.text,
    this.action,
    super.key,
  });

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s2,
      ),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: AppRadii.borderL,
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: c.textPrimary),
          const SizedBox(width: AppSpacing.s2),
          Expanded(child: Text(text, style: context.text.bodyS)),
          ?action,
        ],
      ),
    );
  }
}

/// Причина отказа: быстрые чипы, своё слово или без причины.
class _RejectSheet extends StatefulWidget {
  const _RejectSheet();

  @override
  State<_RejectSheet> createState() => _RejectSheetState();
}

class _RejectSheetState extends State<_RejectSheet> {
  final TextEditingController _own = TextEditingController();

  @override
  void dispose() {
    _own.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.s6,
          0,
          AppSpacing.s6,
          AppSpacing.s4 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SheetHeader(title: 'Почему отклонить?'),
            Wrap(
              spacing: AppSpacing.s2,
              children: [
                for (final r in rejectReasons)
                  FilterPill(
                    key: Key('reject-reason-$r'),
                    label: r,
                    selected: false,
                    onTap: () => Navigator.of(context).pop(r),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.s3),
            FormTextField(
              key: const Key('reject-own'),
              controller: _own,
              decoration: const InputDecoration(hintText: 'Своя причина'),
            ),
            const SizedBox(height: AppSpacing.s3),
            Row(
              children: [
                TextButton(
                  key: const Key('reject-none'),
                  onPressed: () => Navigator.of(context).pop(''),
                  child: const Text('Без причины'),
                ),
                const Spacer(),
                ElevatedButton(
                  key: const Key('reject-confirm'),
                  onPressed: () => Navigator.of(context).pop(_own.text.trim()),
                  child: const Text('Отклонить'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
