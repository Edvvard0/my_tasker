import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/data/work_repository.dart';
import 'package:my_tasker/features/work/domain/work_calc.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';
import 'package:my_tasker/features/work/presentation/work_forms.dart';

/// Открывает форму платежа: [paymentId] — правка; иначе новый платёж, в
/// который по умолчанию добавлена строка распределения на [projectId].
Future<void> showPaymentEditor(
  BuildContext context, {
  String? paymentId,
  String? projectId,
  String? changeRequestId,
}) => showEditorSheet<void>(
  context,
  builder: (_) => PaymentEditor(
    paymentId: paymentId,
    projectId: projectId,
    changeRequestId: changeRequestId,
  ),
);

class _Row {
  _Row({this.projectId, this.changeRequestId, String amount = ''})
    : amount = TextEditingController(text: amount);

  String? projectId;
  String? changeRequestId;
  final TextEditingController amount;

  /// Пользователь правил сумму сам: автоподстановка суммы платежа выключена.
  bool touched = false;
}

/// Ввод платежа с распределением (spec 1.4–1.5): сумма, дата, от кого и
/// строки «куда»: проект (база) или доработка. Сумма распределений не
/// больше суммы платежа; неразнесённый остаток показан и допустим.
class PaymentEditor extends ConsumerStatefulWidget {
  const PaymentEditor({
    this.paymentId,
    this.projectId,
    this.changeRequestId,
    super.key,
  });

  final String? paymentId;
  final String? projectId;
  final String? changeRequestId;

  @override
  ConsumerState<PaymentEditor> createState() => _PaymentEditorState();
}

class _PaymentEditorState extends ConsumerState<PaymentEditor> {
  final _amount = TextEditingController();
  final _comment = TextEditingController();
  final List<_Row> _rows = [];

  bool _loading = true;
  bool _missing = false;
  Payment? _original;
  late DateTime _date;
  String? _payerId;
  String? _error;
  bool _saving = false;

  bool get _isNew => widget.paymentId == null;

  @override
  void initState() {
    super.initState();
    final now = ref.read(clockProvider)().toUtc();
    _date = parseDate(moscowDate(now))!;
    if (_isNew) {
      _rows.add(
        _Row(
          projectId: widget.projectId,
          changeRequestId: widget.changeRequestId,
        ),
      );
      _loading = false;
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _comment.dispose();
    for (final r in _rows) {
      r.amount.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(workRepositoryProvider);
    final payment = await repo.getPayment(widget.paymentId!);
    final allocations = payment == null
        ? const <Allocation>[]
        : await repo.allocationsOfPayment(payment.id);
    if (!mounted) return;
    if (payment == null) {
      setState(() {
        _missing = true;
        _loading = false;
      });
      return;
    }
    setState(() {
      _original = payment;
      _amount.text = moneyFieldText(payment.amount);
      _comment.text = payment.comment ?? '';
      _payerId = payment.payerId;
      _date = parseDate(moscowDate(payment.paidAt))!;
      for (final a in allocations) {
        _rows.add(
          _Row(
            projectId: a.projectId,
            changeRequestId: a.changeRequestId,
            amount: moneyFieldText(a.amount),
          )..touched = true,
        );
      }
      _loading = false;
    });
  }

  int get _paymentKopecks => tryParseAmount(_amount.text) ?? 0;

  int get _allocated {
    var sum = 0;
    for (final r in _rows) {
      sum += tryParseAmount(r.amount.text) ?? 0;
    }
    return sum;
  }

  void _onAmountChanged(String _) {
    // Единственная нетронутая строка повторяет сумму платежа.
    if (_rows.length == 1 && !_rows.first.touched) {
      _rows.first.amount.text = moneyFieldText(
        _paymentKopecks == 0 ? null : _paymentKopecks,
      );
    }
    setState(() {});
  }

  void _fillRest() {
    final rest = _paymentKopecks - _allocated;
    if (rest <= 0 || _rows.isEmpty) return;
    final row = _rows.last;
    final current = tryParseAmount(row.amount.text) ?? 0;
    setState(() {
      row.amount.text = moneyFieldText(current + rest);
      row.touched = true;
    });
  }

  DateTime _paidAt(DateTime now) {
    final original = _original;
    final chosen = formatDate(_date);
    if (original != null && moscowDate(original.paidAt) == chosen) {
      return original.paidAt;
    }
    if (moscowDate(now) == chosen) {
      return DateTime.fromMillisecondsSinceEpoch(
        now.millisecondsSinceEpoch - now.millisecondsSinceEpoch % 1000,
        isUtc: true,
      );
    }
    // Другой день — полдень по Москве (09:00 UTC): дата и месяц те же.
    return DateTime.utc(_date.year, _date.month, _date.day, 9);
  }

  Future<void> _save() async {
    if (_saving) return;
    final amount = parseMoneyField(_amount.text, 'Сумма платежа');
    if (amount.error != null || amount.kopecks == null) {
      setState(() => _error = amount.error ?? 'Укажите сумму платежа');
      return;
    }
    final drafts = <AllocationDraft>[];
    for (final r in _rows) {
      final text = r.amount.text.trim();
      if (r.projectId == null && text.isEmpty) continue;
      final money = parseMoneyField(text, 'Сумма распределения');
      if (r.projectId == null) {
        setState(() => _error = 'Выберите проект для строки распределения');
        return;
      }
      if (money.error != null || money.kopecks == null || money.kopecks == 0) {
        setState(() => _error = money.error ?? 'Укажите сумму распределения');
        return;
      }
      drafts.add(
        AllocationDraft(
          projectId: r.projectId!,
          changeRequestId: r.changeRequestId,
          amount: money.kopecks!,
        ),
      );
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final repo = ref.read(workRepositoryProvider);
    try {
      final payment = Payment(
        id: _original?.id ?? repo.newId(),
        paidAt: _paidAt(ref.read(clockProvider)().toUtc()),
        amount: amount.kopecks!,
        payerId: _payerId,
        comment: _comment.text.trim().isEmpty ? null : _comment.text.trim(),
      );
      if (_isNew) {
        await repo.createPayment(payment, drafts);
      } else {
        await repo.updatePayment(payment, drafts);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } on ValidationError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  Future<void> _delete() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Удалить платёж?',
      message:
          'Платёж и его распределения уйдут в корзину, остатки по проектам '
          'пересчитаются. Вернуть можно в течение 30 дней.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok || !mounted) return;
    await ref.read(workRepositoryProvider).deletePayment(widget.paymentId!);
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
          const SheetHeader(title: 'Платёж'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Платёж не найден: возможно, его удалили на другом устройстве.',
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final data = ref.watch(workDataProvider).value;
    final today = parseDate(moscowDate(ref.watch(clockProvider)().toUtc()))!;
    final people = ref.watch(workPeopleProvider).value ?? const <WorkPerson>[];
    final payers = [
      for (final p in people)
        if (!p.archived || p.id == _payerId) p,
    ];
    final rest = _paymentKopecks - _allocated;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: _isNew ? 'Новый платёж' : 'Платёж'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'Сумма',
                    child: FormTextField(
                      key: const Key('payment-amount'),
                      controller: _amount,
                      autofocus: _isNew,
                      onChanged: _onAmountChanged,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: moneyInputFormatters,
                      decoration: const InputDecoration(
                        hintText: '0',
                        suffixText: '₽',
                      ),
                    ),
                  ),
                  FormBlock(
                    label: 'Дата (по Москве)',
                    child: DateChoiceRow(
                      keyPrefix: 'payment-date',
                      today: today,
                      value: _date,
                      onChanged: (d) => setState(() => _date = d!),
                    ),
                  ),
                  if (payers.isNotEmpty)
                    FormBlock(
                      label: 'От кого',
                      child: ChipRow(
                        children: [
                          FilterPill(
                            key: const Key('payment-payer-none'),
                            label: 'Не указан',
                            selected: _payerId == null,
                            onTap: () => setState(() => _payerId = null),
                          ),
                          for (final p in payers)
                            FilterPill(
                              key: Key('payment-payer-${p.id}'),
                              label: p.name,
                              selected: _payerId == p.id,
                              icon: LucideIcons.user,
                              onTap: () => setState(() => _payerId = p.id),
                            ),
                        ],
                      ),
                    ),
                  FormBlock(
                    label: 'Комментарий',
                    child: FormTextField(
                      key: const Key('payment-comment'),
                      controller: _comment,
                      decoration: const InputDecoration(
                        hintText: 'Необязательно',
                      ),
                    ),
                  ),
                  const FieldLabel('Распределение по проектам'),
                  for (var i = 0; i < _rows.length; i++)
                    _allocationRow(context, data, i),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('alloc-add'),
                      onPressed: () => setState(() => _rows.add(_Row())),
                      icon: const Icon(LucideIcons.plus, size: 18),
                      label: const Text('Ещё строка'),
                    ),
                  ),
                  _restLine(context, rest),
                  const SizedBox(height: AppSpacing.s3),
                  if (_error != null)
                    FormError(_error!, key: const Key('payment-error')),
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
                    key: const Key('payment-delete'),
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
                  key: const Key('payment-save'),
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

  Widget _restLine(BuildContext context, int rest) {
    final c = context.colors;
    final t = context.text;
    if (_paymentKopecks == 0 && _allocated == 0) return const SizedBox.shrink();
    final over = rest < 0;
    return Row(
      children: [
        Expanded(
          child: Text(
            over
                ? 'Распределено больше, чем пришло: на ${formatAmount(-rest)}'
                : rest == 0
                ? 'Всё распределено'
                : 'Не распределено: ${formatAmount(rest)}',
            key: const Key('alloc-rest-text'),
            style: t.bodyS.copyWith(
              color: over ? c.danger : c.textSecondary,
              fontWeight: over ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
        if (rest > 0 && _rows.isNotEmpty)
          TextButton(
            key: const Key('alloc-rest'),
            onPressed: _fillRest,
            child: const Text('Распределить остаток'),
          ),
      ],
    );
  }

  Widget _allocationRow(BuildContext context, WorkData? data, int i) {
    final c = context.colors;
    final t = context.text;
    final row = _rows[i];
    final projects = [
      for (final p in data?.projects ?? const <WorkProject>[])
        if ((!p.archived && p.effectiveStatus != ProjectStatus.cancelled) ||
            p.id == row.projectId)
          p,
    ];
    final project = data?.projectById[row.projectId];
    final crs = row.projectId == null || data == null
        ? const <ChangeRequest>[]
        : [
            for (final cr in data.changeRequestsOf(row.projectId!))
              if (cr.status != ChangeRequestStatus.cancelled ||
                  cr.id == row.changeRequestId)
                cr,
          ];
    final target = row.changeRequestId == null
        ? null
        : data?.changeRequestById[row.changeRequestId];
    return Container(
      key: Key('alloc-row-$i'),
      margin: const EdgeInsets.only(bottom: AppSpacing.s2),
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: AppRadii.borderM,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: PopupMenuButton<String>(
                  key: Key('alloc-project-$i'),
                  tooltip: 'Проект',
                  onSelected: (id) => setState(() {
                    if (row.projectId != id) row.changeRequestId = null;
                    row.projectId = id;
                  }),
                  itemBuilder: (_) => [
                    for (final p in projects)
                      PopupMenuItem<String>(
                        key: Key('alloc-project-$i-${p.id}'),
                        value: p.id,
                        child: Text(p.title),
                      ),
                  ],
                  child: _pickerLabel(
                    context,
                    project?.title ?? 'Выберите проект',
                    placeholder: project == null,
                  ),
                ),
              ),
              IconButton(
                key: Key('alloc-remove-$i'),
                tooltip: 'Убрать строку',
                onPressed: () => setState(() {
                  _rows.removeAt(i).amount.dispose();
                }),
                icon: const Icon(LucideIcons.x, size: 18),
              ),
            ],
          ),
          if (project != null) ...[
            const SizedBox(height: AppSpacing.s2),
            PopupMenuButton<String>(
              key: Key('alloc-target-$i'),
              tooltip: 'Куда зачесть',
              onSelected: (id) =>
                  setState(() => row.changeRequestId = id.isEmpty ? null : id),
              itemBuilder: (_) => [
                PopupMenuItem<String>(
                  key: Key('alloc-target-$i-base'),
                  value: '',
                  child: Text(
                    'Основная сумма · ост. '
                    '${formatAmount(data!.summaryOf(project.id).baseRemaining)}',
                  ),
                ),
                for (final cr in crs)
                  PopupMenuItem<String>(
                    key: Key('alloc-target-$i-${cr.id}'),
                    value: cr.id,
                    child: Text(
                      '${cr.title} · ост. ${formatAmount(_crRemaining(data, project.id, cr.id))}',
                    ),
                  ),
              ],
              child: _pickerLabel(context, target?.title ?? 'Основная сумма'),
            ),
          ],
          const SizedBox(height: AppSpacing.s2),
          FormTextField(
            key: Key('alloc-amount-$i'),
            controller: row.amount,
            onChanged: (_) => setState(() => row.touched = true),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: moneyInputFormatters,
            decoration: InputDecoration(
              hintText: 'Сумма',
              suffixText: '₽',
              helperText: project == null
                  ? null
                  : 'Остаток по проекту: '
                        '${formatAmount(data!.summaryOf(project.id).remaining)}',
              helperStyle: t.caption.copyWith(color: c.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  int _crRemaining(WorkData data, String projectId, String crId) {
    for (final s in data.summaryOf(projectId).changeRequests) {
      if (s.id == crId) return s.remaining;
    }
    return 0;
  }

  Widget _pickerLabel(
    BuildContext context,
    String text, {
    bool placeholder = false,
  }) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s3,
      ),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: AppRadii.borderS,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.body.copyWith(
                color: placeholder ? c.textTertiary : c.textPrimary,
              ),
            ),
          ),
          Icon(LucideIcons.chevronRight, size: 16, color: c.textTertiary),
        ],
      ),
    );
  }
}
