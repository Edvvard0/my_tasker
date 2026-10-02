import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/data/proposal_service.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';

/// Правка предложения задачи: открывает форму и сохраняет `arguments`
/// (локальная правка строки, spec Этапа 3, 2, п. 2).
Future<void> showProposalEditor(BuildContext context, ToolProposal proposal) =>
    showEditorSheet<void>(
      context,
      builder: (_) => ProposalEditor(proposal: proposal),
    );

/// Форма полей предложенной задачи: название, заметки, дата, время,
/// длительность, приоритет, проект, теги.
class ProposalEditor extends ConsumerStatefulWidget {
  const ProposalEditor({required this.proposal, super.key});

  final ToolProposal proposal;

  @override
  ConsumerState<ProposalEditor> createState() => _ProposalEditorState();
}

class _ProposalEditorState extends ConsumerState<ProposalEditor> {
  late final TextEditingController _title;
  late final TextEditingController _notes;
  late final TextEditingController _duration;
  late final TextEditingController _project;
  late final TextEditingController _tags;
  String? _date;
  String? _time;
  int? _priority;
  String? _error;

  @override
  void initState() {
    super.initState();
    final a = widget.proposal.arguments;
    _title = TextEditingController(text: '${a['title'] ?? ''}');
    _notes = TextEditingController(text: '${a['notes'] ?? ''}');
    _duration = TextEditingController(
      text: a['duration_minutes'] is int ? '${a['duration_minutes']}' : '',
    );
    _project = TextEditingController(text: '${a['project'] ?? ''}');
    _tags = TextEditingController(
      text: a['tags'] is List ? (a['tags']! as List).join(' ') : '',
    );
    _date = a['due_date'] as String?;
    _time = a['due_time'] as String?;
    _priority = a['priority'] as int?;
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _duration.dispose();
    _project.dispose();
    _tags.dispose();
    super.dispose();
  }

  Map<String, Object?> _collect() {
    final duration = int.tryParse(_duration.text.trim());
    final tags = _tags.text
        .split(RegExp(r'[\s,]+'))
        .where((t) => t.isNotEmpty)
        .toList();
    return {
      'title': _title.text.trim(),
      if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
      'priority': ?_priority,
      'due_date': ?_date,
      if (_date != null && _time != null) 'due_time': _time,
      'duration_minutes': ?duration,
      if (_project.text.trim().isNotEmpty) 'project': _project.text.trim(),
      if (tags.isNotEmpty) 'tags': tags,
    };
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final initial = _date == null ? null : parseDate(_date!);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) {
      setState(
        () => _date = formatDate(
          DateTime.utc(picked.year, picked.month, picked.day),
        ),
      );
    }
  }

  Future<void> _pickTime() async {
    final parts = _time?.split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: parts == null
          ? const TimeOfDay(hour: 12, minute: 0)
          : TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])),
    );
    if (picked != null) {
      setState(() {
        _time =
            '${picked.hour.toString().padLeft(2, '0')}:'
            '${picked.minute.toString().padLeft(2, '0')}';
      });
    }
  }

  Future<void> _save() async {
    try {
      await ref
          .read(proposalServiceProvider)
          .updateArguments(widget.proposal.id, _collect());
      if (mounted) Navigator.of(context).pop();
    } on AiValidationError catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHeader(title: 'Изменить задачу'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FormBlock(
                    label: 'Название',
                    child: FormTextField(
                      controller: _title,
                      decoration: const InputDecoration(),
                      key: const Key('proposal-title'),
                    ),
                  ),
                  FormBlock(
                    label: 'Срок',
                    child: Wrap(
                      spacing: AppSpacing.s2,
                      runSpacing: AppSpacing.s2,
                      children: [
                        FilterPill(
                          key: const Key('proposal-date'),
                          label: _date ?? 'Без даты',
                          selected: _date != null,
                          onTap: _pickDate,
                        ),
                        if (_date != null)
                          FilterPill(
                            key: const Key('proposal-time'),
                            label: _time ?? 'Без времени',
                            selected: _time != null,
                            onTap: _pickTime,
                          ),
                        if (_date != null)
                          FilterPill(
                            key: const Key('proposal-date-clear'),
                            label: 'Убрать срок',
                            selected: false,
                            onTap: () => setState(() {
                              _date = null;
                              _time = null;
                            }),
                          ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: 'Приоритет',
                    child: Wrap(
                      spacing: AppSpacing.s2,
                      children: [
                        for (var p = 1; p <= 5; p++)
                          FilterPill(
                            key: Key('proposal-priority-$p'),
                            label: 'P$p',
                            selected: _priority == p,
                            onTap: () => setState(
                              () => _priority = _priority == p ? null : p,
                            ),
                          ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: 'Длительность, минут',
                    child: FormTextField(
                      controller: _duration,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(),
                      key: const Key('proposal-duration'),
                    ),
                  ),
                  FormBlock(
                    label: 'Проект',
                    child: FormTextField(
                      controller: _project,
                      decoration: const InputDecoration(),
                      key: const Key('proposal-project'),
                    ),
                  ),
                  FormBlock(
                    label: 'Теги (через пробел)',
                    child: FormTextField(
                      controller: _tags,
                      decoration: const InputDecoration(),
                      key: const Key('proposal-tags'),
                    ),
                  ),
                  FormBlock(
                    label: 'Заметки',
                    child: FormTextField(
                      controller: _notes,
                      minLines: 2,
                      maxLines: 5,
                      decoration: const InputDecoration(),
                      key: const Key('proposal-notes'),
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
                      child: Text(
                        _error!,
                        key: const Key('proposal-error'),
                        style: context.text.bodyS.copyWith(color: c.danger),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s4),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                key: const Key('proposal-save'),
                onPressed: _save,
                child: const Text('Сохранить'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
