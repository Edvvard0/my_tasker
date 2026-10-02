import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/finance_lookups.dart';
import 'package:my_tasker/features/finance/presentation/widgets/amount_field.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_states.dart';

/// Подпись корректировки сверки (spec 4.4): «В банке больше на 800 ₽».
String adjustmentText(int adjustment) {
  if (adjustment == 0) return 'Сходится: в банке столько же, сколько в учёте';
  final amount = moneyText(adjustment.abs());
  return adjustment > 0
      ? 'В банке больше на $amount'
      : 'В банке меньше на $amount';
}

/// Сверка баланса (spec 4.4): вводишь фактический остаток из банка, экран
/// создаёт точку сверки `manual` и показывает корректировку; ниже — история
/// сверок счёта с их корректировками.
class ReconcileScreen extends ConsumerStatefulWidget {
  const ReconcileScreen({required this.accountId, super.key});

  final String accountId;

  @override
  ConsumerState<ReconcileScreen> createState() => _ReconcileScreenState();
}

class _ReconcileScreenState extends ConsumerState<ReconcileScreen> {
  final _actual = TextEditingController();
  final _note = TextEditingController();
  BalanceAdjustment? _result;
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
    final value = parseAmountField(_actual.text);
    if (value == null) {
      setState(() => _error = 'Введи баланс из банка');
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      final result = await ref
          .read(financeRepositoryProvider)
          .reconcile(
            accountId: widget.accountId,
            actualBalance: value,
            note: _note.text,
          );
      if (!mounted) return;
      setState(() {
        _result = result;
        _saving = false;
        _note.clear();
      });
    } on ValidationError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  Future<void> _deleteCheckpoint(String id) async {
    final repo = ref.read(financeRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    await repo.deleteCheckpoint(id);
    if (_result?.checkpointId == id) setState(() => _result = null);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: const Text('Сверка удалена'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Отменить',
            onPressed: () => repo.restoreCheckpoint(id),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.accountId;
    final lookups = ref.watch(financeLookupsProvider);
    final balance = ref.watch(accountBalanceProvider(id));
    final account = lookups.value?.account(id);
    final Widget body;
    if (lookups.hasError && !lookups.hasValue) {
      body = const FinanceErrorNotice();
    } else if (!lookups.hasValue) {
      body = const ListSkeleton(rows: 2);
    } else if (account == null) {
      body = EmptyState(
        key: const Key('reconcile-missing'),
        icon: LucideIcons.wallet,
        title: 'Счёт не найден',
        message: 'Возможно, его удалили на другом устройстве.',
        action: ElevatedButton(
          onPressed: () => context.go('/finance'),
          child: const Text('К финансам'),
        ),
      );
    } else {
      body = _form(context, account, balance.value ?? 0);
    }
    return ScreenScaffold(
      title: 'Сверка баланса',
      parentLabel: account?.name ?? 'Счёт',
      onBack: () => context.go('/finance/accounts/$id'),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [const FinanceOfflineNotice(), body],
          ),
        ),
      ),
    );
  }

  Widget _form(BuildContext context, Account account, int balance) {
    final c = context.colors;
    final t = context.text;
    final result = _result;
    final history = ref.watch(accountAdjustmentsProvider(account.id)).value;
    final notes = {
      for (final cp
          in ref.watch(checkpointsOfProvider(account.id)).value ??
              const <BalanceCheckpoint>[])
        cp.id: cp.note,
    };
    final zone = ref.watch(deviceTimeZoneProvider);
    final today = ref.watch(todayProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ПО УЧЁТУ СЕЙЧАС',
                style: t.overline.copyWith(color: c.textTertiary),
              ),
              const SizedBox(height: AppSpacing.s1),
              Text(
                moneyText(balance),
                key: const Key('reconcile-current'),
                style: t.kpi,
              ),
              const SizedBox(height: AppSpacing.s1),
              Text(
                'Сверь с остатком в банке: введи, сколько там сейчас. '
                'Сверка не создаёт операций — доходы и расходы не меняются.',
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
        const FieldLabel('Баланс в банке'),
        AmountField(
          key: const Key('reconcile-amount'),
          controller: _actual,
          allowNegative: true,
          autofocus: true,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
        ),
        const SizedBox(height: AppSpacing.s3),
        const FieldLabel('Заметка'),
        FormTextField(
          key: const Key('reconcile-note'),
          controller: _note,
          decoration: const InputDecoration(hintText: 'Необязательно'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s3),
            child: Row(
              key: const Key('reconcile-error'),
              children: [
                Icon(LucideIcons.circleAlert, size: 16, color: c.danger),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _error!,
                    style: t.bodyS.copyWith(color: c.danger),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.s4),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            key: const Key('reconcile-save'),
            onPressed: _saving ? null : _save,
            child: const Text('Сверить'),
          ),
        ),
        if (result != null) ...[
          const SizedBox(height: AppSpacing.s4),
          AppCard(
            child: Column(
              key: const Key('reconcile-result'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(adjustmentText(result.adjustment), style: t.h3),
                const SizedBox(height: AppSpacing.s1),
                Text(
                  'Баланс счёта теперь ${moneyText(result.actual)}. '
                  'Отдельной операции сверка не создаёт.',
                  style: t.bodyS.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.s6),
        Text(
          'ПРОШЛЫЕ СВЕРКИ',
          style: t.overline.copyWith(color: c.textTertiary),
        ),
        const SizedBox(height: AppSpacing.s2),
        if (history == null || history.isEmpty)
          Text(
            'Сверок ещё не было.',
            key: const Key('reconcile-history-empty'),
            style: t.bodyS.copyWith(color: c.textSecondary),
          )
        else
          for (final line in history.reversed)
            _HistoryRow(
              line: line,
              note: notes[line.checkpointId],
              when: whenText(utcToWall(zone, line.checkedAt), today),
              onDelete: () => unawaited(_deleteCheckpoint(line.checkpointId)),
            ),
      ],
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.line,
    required this.note,
    required this.when,
    required this.onDelete,
  });

  final BalanceAdjustment line;
  final String? note;
  final String when;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Container(
      key: Key('checkpoint-${line.checkpointId}'),
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('В банке ${moneyText(line.actual)}', style: t.bodyStrong),
                Text(
                  [when, ?note].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodyS.copyWith(color: c.textSecondary),
                ),
                Text(
                  adjustmentText(line.adjustment),
                  style: t.bodyS.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
          Text(
            moneyText(line.adjustment, signed: true),
            style: t.numM.copyWith(fontWeight: FontWeight.w600),
          ),
          IconButton(
            key: Key('checkpoint-delete-${line.checkpointId}'),
            tooltip: 'Удалить сверку',
            onPressed: onDelete,
            icon: Icon(LucideIcons.trash2, size: 18, color: c.textSecondary),
          ),
        ],
      ),
    );
  }
}
