import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/sleep/application/sleep_providers.dart';
import 'package:my_tasker/features/sleep/data/sleep_repository.dart';
import 'package:my_tasker/features/sleep/domain/sleep_calc.dart' show sleepDate;
import 'package:my_tasker/features/sleep/domain/sleep_format.dart';
import 'package:my_tasker/features/sleep/domain/sleep_habits.dart';
import 'package:my_tasker/features/sleep/domain/sleep_models.dart';
import 'package:my_tasker/features/work/presentation/work_forms.dart'
    show FormError;
import 'package:timezone/timezone.dart' as tz;

/// Открывает форму сна «лёг / встал»: [date] — правка записи этого дня,
/// [forDate] — новая запись за день пробуждения [forDate] (по умолчанию
/// сегодня). [source] — откуда вызвана форма (быстрый ввод из утреннего
/// уведомления помечает запись `morning_notification`). Возвращает дату
/// записи (`deleted` — запись удалена).
Future<String?> showSleepEntrySheet(
  BuildContext context, {
  String? date,
  String? forDate,
  SleepSource source = SleepSource.manual,
}) => showEditorSheet<String>(
  context,
  builder: (_) => SleepEntrySheet(date: date, forDate: forDate, source: source),
);

/// Длиннее этого сон считается подозрительным: форма предупреждает, но
/// сохранить даёт (контракт допускает до 24 часов).
const int suspiciousSleepMinutes = 16 * 60;

/// Форма сна: день пробуждения, «лёг» и «встал» (текстом `ЧЧ:ММ`),
/// самочувствие 1–5, заметка. Предзаполнена привычным режимом — запись
/// «как обычно» занимает два касания («Записать сон» → «Сохранить»).
///
/// «Лёг» — ближайшее перед пробуждением вхождение этого времени на часах
/// зоны отбоя: 23:40 при подъёме в 07:10 — вечер прошлого дня, 01:15 — ночь
/// того же. Длительность — разность моментов, поэтому через полночь, смену
/// пояса и перевод часов она верна сама.
class SleepEntrySheet extends ConsumerStatefulWidget {
  const SleepEntrySheet({
    this.date,
    this.forDate,
    this.source = SleepSource.manual,
    super.key,
  });

  final String? date;
  final String? forDate;
  final SleepSource source;

  @override
  ConsumerState<SleepEntrySheet> createState() => _SleepEntrySheetState();
}

class _SleepEntrySheetState extends ConsumerState<SleepEntrySheet> {
  final _bed = TextEditingController();
  final _wake = TextEditingController();
  final _note = TextEditingController();
  bool _loading = true;
  bool _missing = false;
  bool _saving = false;
  SleepEntry? _original;
  // Время записи при открытии формы (минуты суток): если текст не менялся,
  // исходные моменты сохраняются как есть (иначе неоднозначный час при
  // переводе часов назад сдвинулся бы на час).
  int? _originalBedMin;
  int? _originalWakeMin;
  DateTime _wakeDate = DateTime.utc(1970);
  int? _quality;
  String? _error;
  late tz.Location _wakeZone;
  late tz.Location _bedZone;

  bool get _isEdit => widget.date != null;

  @override
  void initState() {
    super.initState();
    final device = ref.read(deviceTimeZoneProvider);
    _wakeZone = isIanaLocation(device) ? device : requireLocation('UTC');
    _bedZone = _wakeZone;
    _wakeDate = widget.forDate != null
        ? (parseDate(widget.forDate!) ?? ref.read(todayProvider))
        : ref.read(todayProvider);
    if (_isEdit) {
      unawaited(_load());
    } else {
      final usual =
          ref.read(sleepDataProvider).value?.usual ?? defaultUsualTimes;
      _bed.text = clockOfMinutes(usual.bed);
      _wake.text = clockOfMinutes(usual.wake);
      _loading = false;
    }
  }

  @override
  void dispose() {
    _bed.dispose();
    _wake.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final e = await ref.read(sleepRepositoryProvider).getEntry(widget.date!);
    if (!mounted) return;
    final view = e?.view;
    if (e == null || view == null) {
      setState(() {
        _missing = true;
        _loading = false;
      });
      return;
    }
    setState(() {
      _original = e;
      _wakeZone = findLocation(e.wakeTz) ?? _wakeZone;
      _bedZone = findLocation(e.bedTz ?? e.wakeTz) ?? _wakeZone;
      _wakeDate = parseDate(e.date) ?? _wakeDate;
      _bed.text = view.bedLocal;
      _wake.text = view.wakeLocal;
      _originalBedMin = parseClockInput(view.bedLocal);
      _originalWakeMin = parseClockInput(view.wakeLocal);
      _note.text = e.note ?? '';
      _quality = e.quality;
      _loading = false;
    });
  }

  /// Моменты отбоя и подъёма по полям формы; `null` — время не разобрано.
  ({DateTime bed, DateTime wake})? _moments() {
    final bedMin = parseClockInput(_bed.text);
    final wakeMin = parseClockInput(_wake.text);
    if (bedMin == null || wakeMin == null) return null;
    var wake = wallToUtc(
      _wakeZone,
      _wakeDate.year,
      _wakeDate.month,
      _wakeDate.day,
      wakeMin ~/ 60,
      wakeMin % 60,
    );
    final original = _original;
    if (original != null &&
        _wakeDate == parseDate(original.date) &&
        wakeMin == _originalWakeMin &&
        _wakeZone.name == original.wakeTz) {
      wake = original.wakeAt;
    }
    final day = dateOnly(utcToWall(_bedZone, wake));
    DateTime at(DateTime d) =>
        wallToUtc(_bedZone, d.year, d.month, d.day, bedMin ~/ 60, bedMin % 60);
    var bed = at(day);
    if (!bed.isBefore(wake)) bed = at(addDays(day, -1));
    if (original != null &&
        wake == original.wakeAt &&
        bedMin == _originalBedMin &&
        _bedZone.name == (original.bedTz ?? original.wakeTz)) {
      bed = original.bedAt;
    }
    return (bed: bed, wake: wake);
  }

  void _useUsual() {
    final usual = ref.read(sleepDataProvider).value?.usual ?? defaultUsualTimes;
    setState(() {
      _bed.text = clockOfMinutes(usual.bed);
      _wake.text = clockOfMinutes(usual.wake);
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final m = _moments();
    if (m == null) {
      setState(() => _error = 'Время — в формате ЧЧ:ММ, например 23:40');
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final repo = ref.read(sleepRepositoryProvider);
    try {
      // Запись на другой день, где уже есть сон, молча не затираем.
      final target = sleepDate(formatInstant(m.wake), _wakeZone.name);
      if (target != null &&
          target != widget.date &&
          await repo.getEntry(target) != null) {
        if (!mounted) return;
        final replace = await showConfirmDialog(
          context,
          title: 'Заменить запись сна?',
          message: 'Запись на эту дату уже есть — заменить?',
          confirmLabel: 'Заменить',
          danger: true,
        );
        if (!replace || !mounted) {
          if (mounted) setState(() => _saving = false);
          return;
        }
      }
      final date = await repo.saveSleep(
        bedAt: m.bed,
        wakeAt: m.wake,
        wakeTz: _wakeZone.name,
        bedTz: _bedZone.name,
        source: _original?.source ?? widget.source,
        quality: _quality,
        note: _note.text,
        replacesDate: widget.date,
      );
      if (!mounted) return;
      Navigator.of(context).pop(date);
    } on ValidationError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  Future<void> _delete() async {
    final e = _original;
    if (e == null) return;
    final ok = await showConfirmDialog(
      context,
      title: 'Удалить запись сна?',
      message: 'Запись уйдёт в корзину на 30 дней.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok) return;
    await ref.read(sleepRepositoryProvider).deleteSleep(e.date);
    if (mounted) Navigator.of(context).pop('deleted');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final title = widget.source == SleepSource.morningNotification && !_isEdit
        ? 'Как спал?'
        : (_isEdit ? 'Сон' : 'Записать сон');
    if (_loading) {
      return const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_missing) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHeader(title: 'Сон'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Запись не найдена: возможно, её удалили на другом устройстве.',
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final moments = _moments();
    final minutes = moments?.wake.difference(moments.bed).inMinutes;
    final today = ref.watch(todayProvider);
    final usual =
        ref.watch(sleepDataProvider).value?.usual ?? defaultUsualTimes;
    final zoneNote = _wakeZone.name != ref.read(deviceTimeZoneProvider).name
        ? 'Время указано по часам пояса ${_wakeZone.name}.'
        : null;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: title),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'День пробуждения',
                    child: DateChoiceRow(
                      keyPrefix: 'sleep-date',
                      today: today,
                      value: _wakeDate,
                      allowFuture: false,
                      onChanged: (d) => setState(() {
                        if (d != null) _wakeDate = d;
                      }),
                    ),
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: FormBlock(
                          label: 'Лёг',
                          child: _TimeField(
                            fieldKey: const Key('sleep-bed'),
                            controller: _bed,
                            onChanged: (_) => setState(() => _error = null),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.s3),
                      Expanded(
                        child: FormBlock(
                          label: 'Встал',
                          child: _TimeField(
                            fieldKey: const Key('sleep-wake'),
                            controller: _wake,
                            onChanged: (_) => setState(() => _error = null),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.s3),
                    child: Text(
                      minutes == null
                          ? 'Введите время, например 23:40'
                          : 'Сон: ${durationText(minutes)}',
                      key: const Key('sleep-preview'),
                      style: t.numM.copyWith(
                        color: minutes == null ? c.textTertiary : c.textPrimary,
                      ),
                    ),
                  ),
                  if (minutes != null && minutes > suspiciousSleepMinutes)
                    const Padding(
                      padding: EdgeInsets.only(bottom: AppSpacing.s3),
                      child: Text(
                        'Проверьте время: такой сон — больше 16 часов.',
                        key: Key('sleep-long-hint'),
                      ),
                    ),
                  if (zoneNote != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
                      child: Text(
                        zoneNote,
                        style: t.bodyS.copyWith(color: c.textSecondary),
                      ),
                    ),
                  ChipRow(
                    children: [
                      FilterPill(
                        key: const Key('sleep-usual'),
                        label:
                            'Как обычно · ${clockOfMinutes(usual.bed)} → '
                            '${clockOfMinutes(usual.wake)}',
                        selected: false,
                        onTap: _useUsual,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  FormBlock(
                    label: 'Самочувствие утром (необязательно)',
                    child: ChipRow(
                      children: [
                        for (var q = 1; q <= 5; q++)
                          FilterPill(
                            key: Key('sleep-quality-$q'),
                            label: '$q',
                            selected: _quality == q,
                            onTap: () => setState(
                              () => _quality = _quality == q ? null : q,
                            ),
                          ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: 'Заметка',
                    child: FormTextField(
                      key: const Key('sleep-note'),
                      controller: _note,
                      minLines: 1,
                      maxLines: 4,
                      keyboardType: TextInputType.multiline,
                      decoration: const InputDecoration(
                        hintText: 'Например, просыпался ночью',
                      ),
                    ),
                  ),
                  if (_error != null)
                    FormError(_error!, key: const Key('sleep-error-text')),
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
            child: Row(
              children: [
                if (_isEdit)
                  TextButton(
                    key: const Key('sleep-delete'),
                    onPressed: _delete,
                    child: Text('Удалить', style: TextStyle(color: c.danger)),
                  ),
                const Spacer(),
                FilledButton(
                  key: const Key('sleep-save'),
                  onPressed: _saving ? null : _save,
                  child: const Text('Сохранить'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TimeField extends StatelessWidget {
  const _TimeField({
    required this.fieldKey,
    required this.controller,
    required this.onChanged,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => FormTextField(
    key: fieldKey,
    controller: controller,
    onChanged: onChanged,
    keyboardType: TextInputType.datetime,
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9:. ]'))],
    style: context.text.numL,
    decoration: const InputDecoration(hintText: '23:40'),
  );
}
