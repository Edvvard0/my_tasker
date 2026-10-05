import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/sleep/data/sleep_settings.dart';
import 'package:my_tasker/features/sleep/domain/sleep_format.dart';
import 'package:my_tasker/features/work/presentation/work_forms.dart'
    show FormError;

/// Открывает настройки напоминаний «Сна»: утреннее «Как спал?» и вечерний
/// чек-ин (включить и время).
Future<void> showSleepSettingsSheet(BuildContext context) =>
    showEditorSheet<void>(context, builder: (_) => const SleepSettingsSheet());

/// Настройки напоминаний «Сна». По умолчанию: «Как спал?» в 09:00 и вечерний
/// чек-ин в 21:30, оба включены; настройки общие для устройств
/// (`user_settings`: `sleep.morning_reminder`, `sleep.evening_reminder`).
class SleepSettingsSheet extends ConsumerStatefulWidget {
  const SleepSettingsSheet({super.key});

  @override
  ConsumerState<SleepSettingsSheet> createState() => _SleepSettingsSheetState();
}

class _SleepSettingsSheetState extends ConsumerState<SleepSettingsSheet> {
  final _morning = TextEditingController();
  final _evening = TextEditingController();
  bool _loading = true;
  bool _morningOn = true;
  bool _eveningOn = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _morning.dispose();
    _evening.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(sleepSettingsRepositoryProvider);
    final m = await repo.readMorning();
    final e = await repo.readEvening();
    if (!mounted) return;
    setState(() {
      _morningOn = m.enabled;
      _eveningOn = e.enabled;
      _morning.text = m.time;
      _evening.text = e.time;
      _loading = false;
    });
  }

  Future<void> _save() async {
    final m = parseClockInput(_morning.text);
    final e = parseClockInput(_evening.text);
    if (m == null || e == null) {
      setState(() => _error = 'Время — в формате ЧЧ:ММ, например 21:30');
      return;
    }
    final repo = ref.read(sleepSettingsRepositoryProvider);
    await repo.writeMorning(
      SleepReminderSetting(enabled: _morningOn, time: clockOfMinutes(m)),
    );
    await repo.writeEvening(
      SleepReminderSetting(enabled: _eveningOn, time: clockOfMinutes(e)),
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    if (_loading) {
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader(title: 'Напоминания'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ReminderRow(
                    title: 'Как спал?',
                    caption: 'Быстрый ввод сна по утрам',
                    switchKey: const Key('sleep-morning-switch'),
                    fieldKey: const Key('sleep-morning-time'),
                    controller: _morning,
                    enabled: _morningOn,
                    onChanged: (v) => setState(() => _morningOn = v),
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  _ReminderRow(
                    title: 'Вечерний чек-ин',
                    caption: 'Что сделано, что перенести, оценка дня',
                    switchKey: const Key('sleep-evening-switch'),
                    fieldKey: const Key('sleep-evening-time'),
                    controller: _evening,
                    enabled: _eveningOn,
                    onChanged: (v) => setState(() => _eveningOn = v),
                  ),
                  const SizedBox(height: AppSpacing.s3),
                  Text(
                    'Напоминание не приходит, если сон или чек-ин за этот '
                    'день уже записаны.',
                    style: t.bodyS.copyWith(color: c.textSecondary),
                  ),
                  const SizedBox(height: AppSpacing.s3),
                  if (_error != null)
                    FormError(_error!, key: const Key('sleep-settings-error')),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s6,
              AppSpacing.s2,
              AppSpacing.s6,
              AppSpacing.s4,
            ),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const Key('sleep-settings-save'),
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

class _ReminderRow extends StatelessWidget {
  const _ReminderRow({
    required this.title,
    required this.caption,
    required this.switchKey,
    required this.fieldKey,
    required this.controller,
    required this.enabled,
    required this.onChanged,
  });

  final String title;
  final String caption;
  final Key switchKey;
  final Key fieldKey;
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: t.bodyStrong),
              Text(caption, style: t.bodyS.copyWith(color: c.textSecondary)),
            ],
          ),
        ),
        SizedBox(
          width: 96,
          child: FormTextField(
            key: fieldKey,
            controller: controller,
            keyboardType: TextInputType.datetime,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp('[0-9:. ]')),
            ],
            style: t.numM,
            decoration: const InputDecoration(hintText: '09:00'),
          ),
        ),
        Switch(key: switchKey, value: enabled, onChanged: onChanged),
      ],
    );
  }
}
