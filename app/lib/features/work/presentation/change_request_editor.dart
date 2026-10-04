import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';
import 'package:my_tasker/features/work/presentation/work_forms.dart';

/// Открывает редактор доработки: [changeRequestId] — правка, иначе
/// создание доработки проекта [projectId].
Future<void> showChangeRequestEditor(
  BuildContext context, {
  required String projectId,
  String? changeRequestId,
}) => showEditorSheet<void>(
  context,
  builder: (_) => ChangeRequestEditor(
    projectId: projectId,
    changeRequestId: changeRequestId,
  ),
);

/// Редактор доработки: название, сумма, статус, дата закрытия, оценка в
/// часах и заметка.
class ChangeRequestEditor extends ConsumerStatefulWidget {
  const ChangeRequestEditor({
    required this.projectId,
    this.changeRequestId,
    super.key,
  });

  final String projectId;
  final String? changeRequestId;

  @override
  ConsumerState<ChangeRequestEditor> createState() =>
      _ChangeRequestEditorState();
}

class _ChangeRequestEditorState extends ConsumerState<ChangeRequestEditor> {
  final _title = TextEditingController();
  final _amount = TextEditingController();
  final _estimate = TextEditingController();
  final _note = TextEditingController();

  bool _loading = true;
  bool _missing = false;
  ChangeRequest? _original;
  ChangeRequestStatus _status = ChangeRequestStatus.inProgress;
  DateTime? _closed;
  String? _error;
  bool _saving = false;

  bool get _isNew => widget.changeRequestId == null;

  @override
  void initState() {
    super.initState();
    if (_isNew) {
      _loading = false;
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _amount.dispose();
    _estimate.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cr = await ref
        .read(workRepositoryProvider)
        .getChangeRequest(widget.changeRequestId!);
    if (!mounted) return;
    if (cr == null) {
      setState(() {
        _missing = true;
        _loading = false;
      });
      return;
    }
    setState(() {
      _original = cr;
      _title.text = cr.title;
      _amount.text = moneyFieldText(cr.amount);
      _status = cr.status;
      _closed = dateFromText(cr.closedDate);
      _estimate.text = cr.estimateMinutes == null
          ? ''
          : _hoursText(cr.estimateMinutes!);
      _note.text = cr.note ?? '';
      _loading = false;
    });
  }

  /// Верхняя граница оценки: 600 000 минут (как в `changeRequestProblem`).
  static const int _maxEstimateHours = 10000;

  static String _hoursText(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '$h' : '$h,${(m * 10 ~/ 6).toString().padLeft(2, '0')}';
  }

  /// Оценка в часах (`1,5`) -> минуты; `null` у пустого, ошибка у мусора.
  (int?, String?) _minutes() {
    final text = _estimate.text.trim().replaceAll(',', '.');
    if (text.isEmpty) return (null, null);
    final hours = double.tryParse(text);
    if (hours == null || !hours.isFinite || hours < 0) {
      return (null, 'Оценка: число часов, например 1,5');
    }
    if (hours > _maxEstimateHours) {
      return (null, 'Оценка — не больше 10 000 часов');
    }
    return ((hours * 60).round(), null);
  }

  Future<void> _save() async {
    if (_saving) return;
    final amount = parseMoneyField(_amount.text, 'Сумма');
    final (minutes, minutesError) = _minutes();
    final problem =
        amount.error ??
        (amount.kopecks == null ? 'Укажите сумму доработки' : null) ??
        minutesError;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    var closedEditor = false;
    final repo = ref.read(workRepositoryProvider);
    try {
      final today = ref.read(todayProvider);
      final closed = _status == ChangeRequestStatus.closed
          ? (_closed ?? today)
          : _closed;
      final draft =
          (_original ??
                  ChangeRequest(
                    id: repo.newId(),
                    projectId: widget.projectId,
                    title: '',
                    amount: 0,
                    status: _status,
                  ))
              .copyWith(
                title: _title.text,
                amount: amount.kopecks,
                status: _status,
                closedDate: dateToText(closed),
                estimateMinutes: minutes,
                note: _note.text.trim().isEmpty ? null : _note.text.trim(),
              );
      if (_isNew) {
        await repo.createChangeRequest(draft);
      } else {
        await repo.updateChangeRequest(draft);
      }
      if (!mounted) return;
      closedEditor = true;
      Navigator.of(context).pop();
    } on ValidationError catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      // Любой исход, кроме закрытия формы, возвращает кнопку к жизни.
      if (!closedEditor && mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Удалить доработку?',
      message:
          'Деньги, уже полученные по ней, останутся в проекте как оплата '
          'основной суммы. Доработку можно вернуть из корзины.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok || !mounted) return;
    await ref
        .read(workRepositoryProvider)
        .deleteChangeRequest(widget.changeRequestId!);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
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
          const SheetHeader(title: 'Доработка'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Доработка не найдена: возможно, её удалили на другом устройстве.',
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final today = ref.watch(todayProvider);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: _isNew ? 'Новая доработка' : 'Доработка'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'Название',
                    child: FormTextField(
                      key: const Key('cr-title'),
                      controller: _title,
                      autofocus: _isNew,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'Что нужно доработать',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Сумма',
                    child: MoneyTextField(
                      key: const Key('cr-amount'),
                      controller: _amount,
                    ),
                  ),
                  FormBlock(
                    label: 'Статус',
                    child: ChipRow(
                      children: [
                        for (final s in ChangeRequestStatus.values)
                          FilterPill(
                            key: Key('cr-status-${s.wire}'),
                            label: s.label,
                            selected: _status == s,
                            onTap: () => setState(() => _status = s),
                          ),
                      ],
                    ),
                  ),
                  if (_status == ChangeRequestStatus.closed)
                    FormBlock(
                      label: 'Дата закрытия',
                      child: DateChoiceRow(
                        keyPrefix: 'cr-closed',
                        today: today,
                        value: _closed ?? today,
                        onChanged: (d) => setState(() => _closed = d),
                      ),
                    ),
                  FormBlock(
                    label: 'Оценка, часов',
                    child: FormTextField(
                      key: const Key('cr-estimate'),
                      controller: _estimate,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp('[0-9.,]')),
                      ],
                      decoration: const InputDecoration(
                        hintText: 'Например, 4',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Заметка',
                    child: FormTextField(
                      key: const Key('cr-note'),
                      controller: _note,
                      minLines: 2,
                      maxLines: 4,
                      keyboardType: TextInputType.multiline,
                    ),
                  ),
                  if (_error != null)
                    FormError(_error!, key: const Key('cr-error')),
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
                if (!_isNew)
                  OutlinedButton.icon(
                    key: const Key('cr-delete'),
                    onPressed: _delete,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.danger,
                      side: BorderSide(color: c.danger),
                    ),
                    icon: const Icon(LucideIcons.trash2, size: 18),
                    label: const Text('Удалить'),
                  ),
                const Spacer(),
                FilledButton(
                  key: const Key('cr-save'),
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
