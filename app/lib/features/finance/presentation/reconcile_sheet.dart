import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/calendar_time/civil_date.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/calendar/presentation/widgets/form_pickers.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/application/privacy_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/presentation/finance_forms.dart';
import 'package:my_tasker/features/work/presentation/work_forms.dart'
    show FormError;

/// Сверка баланса счёта с банком (spec 4.4): человек вводит фактический
/// баланс, видит расхождение с расчётным («корректировка»). Операций
/// сверка не создаёт — только точку, поэтому «доход/расход» не меняются.
Future<void> showReconcileSheet(BuildContext context, String accountId) =>
    showEditorSheet<void>(
      context,
      builder: (_) => ReconcileSheet(accountId: accountId),
    );

class ReconcileSheet extends ConsumerStatefulWidget {
  const ReconcileSheet({required this.accountId, super.key});

  final String accountId;

  @override
  ConsumerState<ReconcileSheet> createState() => _ReconcileSheetState();
}

class _ReconcileSheetState extends ConsumerState<ReconcileSheet> {
  final _actual = TextEditingController();
  final _note = TextEditingController();
  DateTime? _date;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _actual.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final money = parseSignedMoney(_actual.text, 'Фактический баланс');
    if (money.error != null || money.kopecks == null) {
      setState(() => _error = money.error ?? 'Укажите баланс из банка');
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final now = ref.read(clockProvider)().toUtc();
    if (formatDate(_date!).compareTo(moscowDay(now)) > 0) {
      setState(() {
        _error = 'Сверка на будущую дату невозможна: баланс замёрз бы';
        _saving = false;
      });
      return;
    }
    try {
      await ref
          .read(financeRepositoryProvider)
          .reconcile(
            accountId: widget.accountId,
            actualBalance: money.kopecks!,
            checkedAt: momentForDate(formatDate(_date!), now),
            note: _note.text,
          );
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

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final format = ref.watch(amountFormatProvider);
    final now = ref.watch(clockProvider)().toUtc();
    final today = parseDate(moscowDay(now))!;
    _date ??= today;
    final data = ref.watch(financeDataProvider).value;
    final account = data?.accountById[widget.accountId];
    final actual = tryParseSigned(_actual.text);
    int? expected;
    if (data != null && account != null) {
      expected = balanceAt(
        account,
        data.transactions,
        data.checkpoints,
        at: momentForDate(formatDate(_date!), now),
      );
    }
    final gap = actual == null || expected == null ? null : actual - expected;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: 'Сверка · ${account?.name ?? 'счёт'}'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Введите баланс так, как его показывает банк. Расхождение '
                    'станет корректировкой: доходом или расходом оно не '
                    'считается.',
                    style: t.bodyS.copyWith(color: c.textSecondary),
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  FormBlock(
                    label: 'Фактический баланс',
                    child: SignedMoneyField(
                      key: const Key('reconcile-actual'),
                      controller: _actual,
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  FormBlock(
                    label: 'На какой момент (по Москве)',
                    child: DateChoiceRow(
                      keyPrefix: 'reconcile-date',
                      allowFuture: false,
                      today: today,
                      value: _date,
                      onChanged: (d) => setState(() => _date = d),
                    ),
                  ),
                  FormBlock(
                    label: 'Заметка',
                    child: FormTextField(
                      key: const Key('reconcile-note'),
                      controller: _note,
                      decoration: const InputDecoration(
                        hintText: 'Необязательно',
                      ),
                    ),
                  ),
                  if (expected != null)
                    Text(
                      'По нашим данным: ${format.full(expected)}',
                      key: const Key('reconcile-expected'),
                      style: t.body,
                    ),
                  if (gap != null) ...[
                    const SizedBox(height: AppSpacing.s1),
                    Text(
                      gap == 0
                          ? 'Расхождения нет'
                          : 'Корректировка: ${format.signed(gap)} '
                                '(${gap > 0 ? 'в банке больше' : 'в банке меньше'})',
                      key: const Key('reconcile-gap'),
                      style: t.bodyStrong,
                    ),
                  ],
                  const SizedBox(height: AppSpacing.s3),
                  if (_error != null)
                    FormError(_error!, key: const Key('reconcile-error')),
                ],
              ),
            ),
          ),
          EditorActions(
            saveKey: const Key('reconcile-save'),
            onSave: _save,
            saving: _saving,
            saveLabel: 'Сверить',
          ),
        ],
      ),
    );
  }
}

/// Сумма из поля или `null` (пусто / мусор).
int? tryParseSigned(String text) => parseSignedMoney(text, '').kopecks;
