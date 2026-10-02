import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/quick_input/quick_input_parser.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';

/// Поле быстрого добавления задачи (02, 4.4; spec 8): одна строка, под
/// ней — распознанные дата, время, приоритет, проект, человек и теги
/// чипами с крестиком. Убранный чип возвращает свои слова в название.
class QuickAddBar extends ConsumerStatefulWidget {
  const QuickAddBar({
    this.onCreated,
    this.autofocus = false,
    this.hint = 'Новая задача: завтра 15:00 !2 #проект',
    super.key,
  });

  /// Задача создана (в результате — созданные по ходу проекты и люди).
  final void Function(QuickTaskResult result)? onCreated;
  final bool autofocus;
  final String hint;

  @override
  ConsumerState<QuickAddBar> createState() => _QuickAddBarState();
}

class _QuickAddBarState extends ConsumerState<QuickAddBar> {
  final _controller = TextEditingController();
  final Set<QuickToken> _removed = {};
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  QuickInputAnalysis _analysis() =>
      analyzeQuickInput(_controller.text, ref.read(nowWallProvider));

  Future<void> _submit() async {
    if (_busy) return;
    final analysis = _analysis();
    final input = analysis.without(_removed);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(taskRepositoryProvider)
          .createFromQuickInput(input, zone: ref.read(deviceTimeZoneProvider));
      if (!mounted) return;
      _controller.clear();
      setState(() {
        _removed.clear();
        _busy = false;
      });
      widget.onCreated?.call(result);
    } on ValidationError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = input.title.trim().isEmpty
            ? 'Введите название задачи'
            : e.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final analysis = _analysis();
    final input = analysis.without(_removed);
    final chips = _chips(analysis, input);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: FormTextField(
                key: const Key('quick-add-field'),
                controller: _controller,
                autofocus: widget.autofocus,
                decoration: InputDecoration(
                  hintText: widget.hint,
                  prefixIcon: Icon(
                    LucideIcons.plus,
                    size: 20,
                    color: c.textTertiary,
                  ),
                  errorText: _error,
                ),
                onChanged: (_) => setState(() {
                  _error = null;
                  _removed.removeWhere((k) => !analysis.present.contains(k));
                }),
                onSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(width: AppSpacing.s2),
            IconButton.filled(
              key: const Key('quick-add-submit'),
              tooltip: 'Добавить задачу',
              onPressed: _busy ? null : _submit,
              icon: const Icon(LucideIcons.arrowUp, size: 20),
            ),
          ],
        ),
        if (chips.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s2),
            child: Wrap(
              key: const Key('quick-add-chips'),
              spacing: AppSpacing.s2,
              runSpacing: AppSpacing.s2,
              children: chips,
            ),
          ),
      ],
    );
  }

  List<Widget> _chips(QuickInputAnalysis analysis, QuickInput input) {
    final today = dateOnly(analysis.now);
    Widget chip(QuickToken kind, String label, IconData icon) => InputPill(
      key: Key('quick-chip-${kind.name}'),
      label: label,
      icon: icon,
      onRemove: () => setState(() => _removed.add(kind)),
    );
    final date = input.date == null ? null : parseDate(input.date!);
    return [
      if (date != null)
        chip(
          QuickToken.date,
          daysBetween(today, date).abs() <= 1
              ? relativeDay(date, today)
              : dayTitleShort(date),
          LucideIcons.calendar,
        ),
      if (input.time != null)
        chip(QuickToken.time, input.time!, LucideIcons.clock),
      if (input.durationMinutes != null)
        chip(
          QuickToken.duration,
          durationText(input.durationMinutes!),
          LucideIcons.timer,
        ),
      if (input.priority != null)
        chip(QuickToken.priority, 'P${input.priority}', LucideIcons.flag),
      if (input.project != null)
        chip(QuickToken.project, '#${input.project}', LucideIcons.folder),
      for (final _ in input.people.take(1))
        chip(QuickToken.person, '@${input.people.first}', LucideIcons.user),
      if (input.tags.isNotEmpty)
        chip(
          QuickToken.tag,
          input.tags.map((t) => '+$t').join(' '),
          LucideIcons.tag,
        ),
    ];
  }
}
