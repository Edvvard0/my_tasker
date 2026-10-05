import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/banks/application/statement_import_controller.dart';
import 'package:my_tasker/features/banks/domain/statement_models.dart';
import 'package:my_tasker/features/banks/domain/statement_plan.dart';
import 'package:my_tasker/features/banks/presentation/banks_widgets.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/category_picker.dart';
import 'package:my_tasker/features/finance/presentation/finance_forms.dart';
import 'package:my_tasker/features/finance/presentation/finance_widgets.dart';
import 'package:my_tasker/features/work/domain/work_format.dart'
    show formatDateText;

/// Мастер импорта выписки: файл → счёт → категории и дубликаты →
/// подтверждение. Разбор идёт на сервере (файл там не хранится), всё
/// остальное — на устройстве.
class StatementImportScreen extends ConsumerWidget {
  const StatementImportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(statementImportProvider);
    return ScreenScaffold(
      key: const Key('statement-import-screen'),
      title: 'Импорт выписки',
      parentLabel: 'Банки',
      onBack: () {
        ref.read(statementImportProvider.notifier).reset();
        financeBack(context);
      },
      child: FinanceBuilder(
        builder: (context, data) => ImportWizardBody(state: state, data: data),
      ),
    );
  }
}

/// Содержимое мастера (используется и в golden-тесте).
class ImportWizardBody extends ConsumerWidget {
  const ImportWizardBody({required this.state, required this.data, super.key});

  final ImportState state;
  final FinanceData data;

  static const Map<ImportStep, String> _titles = {
    ImportStep.file: 'Файл',
    ImportStep.accounts: 'Счёт',
    ImportStep.review: 'Категории и дубликаты',
    ImportStep.confirm: 'Подтверждение',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(statementImportProvider.notifier);
    final step = state.step;
    final number = ImportStep.values.indexOf(step) + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (step != ImportStep.done)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s3),
            child: Text(
              'Шаг $number из 4 · ${_titles[step]}',
              key: const Key('import-step-title'),
              style: context.text.overline.copyWith(
                color: context.colors.textSecondary,
              ),
            ),
          ),
        if (state.error != null) ...[
          NoticeCard(
            key: const Key('import-error'),
            label: 'Ошибка',
            tone: StatusTone.danger,
            text: state.error!,
          ),
          const SizedBox(height: AppSpacing.s3),
        ],
        switch (step) {
          ImportStep.file => _FileStep(state: state, controller: controller),
          ImportStep.accounts => _AccountsStep(
            state: state,
            data: data,
            controller: controller,
          ),
          ImportStep.review => _ReviewStep(
            state: state,
            data: data,
            controller: controller,
          ),
          ImportStep.confirm => _ConfirmStep(
            state: state,
            data: data,
            controller: controller,
          ),
          ImportStep.done => _DoneStep(state: state, controller: controller),
        },
      ],
    );
  }
}

class _FileStep extends StatelessWidget {
  const _FileStep({required this.state, required this.controller});

  final ImportState state;
  final StatementImportController controller;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Выберите файл выписки', style: context.text.h3),
          const SizedBox(height: AppSpacing.s2),
          Text(
            'Подойдут CSV, XLSX и PDF из приложения или интернет-банка '
            'Т-Банка и ВТБ. Файл отправляется на ваш сервер только для '
            'разбора и там не сохраняется.',
            style: context.text.bodyS,
          ),
          const SizedBox(height: AppSpacing.s4),
          FilledButton.icon(
            key: const Key('import-pick'),
            onPressed: state.busy
                ? null
                : () => unawaited(controller.pickAndParse()),
            icon: state.busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.fileUp, size: 18),
            label: Text(state.busy ? 'Разбираем…' : 'Выбрать файл'),
          ),
        ],
      ),
    );
  }
}

class _AccountsStep extends StatelessWidget {
  const _AccountsStep({
    required this.state,
    required this.data,
    required this.controller,
  });

  final ImportState state;
  final FinanceData data;
  final StatementImportController controller;

  @override
  Widget build(BuildContext context) {
    final statement = state.statement!;
    final c = context.colors;
    final t = context.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          key: const Key('import-summary'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${state.fileName ?? 'Выписка'} · '
                '${statementBankName(statement.bank)}',
                style: t.bodyStrong,
              ),
              const SizedBox(height: AppSpacing.s1),
              Text(
                '${statement.lines.length} '
                '${plural(statement.lines.length, 'операция', 'операции', 'операций')}'
                '${statement.periodFrom == null ? '' : ' · ${formatDateText(statement.periodFrom, data.now)} — ${formatDateText(statement.periodTo, data.now)}'}',
                style: t.caption.copyWith(color: c.textSecondary),
              ),
              if (statement.skipped.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.s1),
                Text(
                  'Пропущено строк: ${statement.skipped.length} '
                  '(${{for (final s in statement.skipped) skippedReasonText(s.reason)}.join(', ')})',
                  key: const Key('import-skipped'),
                  style: t.caption.copyWith(color: c.textSecondary),
                ),
              ],
            ],
          ),
        ),
        for (final group in state.groups) ...[
          const SizedBox(height: AppSpacing.s3),
          Text(
            group == null
                ? 'Счёт для операций без номера карты'
                : 'Карта •••• $group — какой счёт?',
            style: t.bodyStrong,
          ),
          const SizedBox(height: AppSpacing.s2),
          AccountChips(
            accounts: data.activeAccounts,
            selectedId: state.accountOfCard[group],
            keyPrefix: 'import-account-${group ?? 'none'}',
            onSelect: (id) => controller.setAccount(group, id),
          ),
        ],
        if (data.activeAccounts.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: AppSpacing.s3),
            child: FinanceWarning(
              key: Key('import-no-accounts'),
              text: 'Сначала добавьте счёт в «Финансах».',
            ),
          ),
        const SizedBox(height: AppSpacing.s4),
        _NavRow(
          onBack: controller.back,
          nextLabel: 'Далее',
          onNext: state.allAccountsChosen && !state.busy
              ? () => unawaited(controller.toReview())
              : null,
          nextKey: const Key('import-next-accounts'),
        ),
      ],
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.onBack,
    required this.nextLabel,
    required this.onNext,
    required this.nextKey,
  });

  final VoidCallback onBack;
  final String nextLabel;
  final VoidCallback? onNext;
  final Key nextKey;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        OutlinedButton(
          key: const Key('import-back'),
          onPressed: onBack,
          child: const Text('Назад'),
        ),
        const Spacer(),
        FilledButton(key: nextKey, onPressed: onNext, child: Text(nextLabel)),
      ],
    );
  }
}

class _ReviewStep extends StatelessWidget {
  const _ReviewStep({
    required this.state,
    required this.data,
    required this.controller,
  });

  final ImportState state;
  final FinanceData data;
  final StatementImportController controller;

  @override
  Widget build(BuildContext context) {
    final summary = summarize(state.items);
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Новых: ${summary.toCreate} · уточнений черновиков: '
          '${summary.toRefine} · уже есть: ${summary.duplicates}',
          key: const Key('import-review-summary'),
          style: context.text.caption.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: AppSpacing.s2),
        Row(
          children: [
            TextButton(
              key: const Key('import-select-new'),
              onPressed: () => controller.setAllSelected(selected: true),
              child: const Text('Отметить новые'),
            ),
            TextButton(
              key: const Key('import-select-none'),
              onPressed: () => controller.setAllSelected(selected: false),
              child: const Text('Снять все'),
            ),
          ],
        ),
        for (var i = 0; i < state.items.length; i++) ...[
          _ItemCard(
            index: i,
            item: state.items[i],
            data: data,
            controller: controller,
          ),
          const SizedBox(height: AppSpacing.s2),
        ],
        const SizedBox(height: AppSpacing.s2),
        _NavRow(
          onBack: controller.back,
          nextLabel: 'Далее',
          onNext: controller.toConfirm,
          nextKey: const Key('import-next-review'),
        ),
      ],
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({
    required this.index,
    required this.item,
    required this.data,
    required this.controller,
  });

  final int index;
  final ImportItem item;
  final FinanceData data;
  final StatementImportController controller;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final line = item.line;
    final amount = line.kind == 'income' ? line.amount : -line.amount;
    final (label, tone) = _status(item);
    return AppCard(
      key: Key('import-item-$index'),
      padding: const EdgeInsets.all(AppSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                key: Key('import-check-$index'),
                value: item.selected,
                onChanged: item.accountId == null
                    ? null
                    : (_) => controller.toggle(index),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      line.merchant ??
                          (line.kind == 'income' ? 'Доход' : 'Расход'),
                      style: t.bodyStrong,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      momentText(
                        line.occurredAt,
                        data.now,
                        withTime: !line.dateOnly,
                      ),
                      style: t.caption.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
              AmountText(
                amount,
                signed: true,
                style: t.numL,
                textKey: Key('import-amount-$index'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s1),
          Wrap(
            spacing: AppSpacing.s2,
            runSpacing: AppSpacing.s1,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusPill(label: label, tone: tone),
              InkWell(
                key: Key('import-category-$index'),
                borderRadius: AppRadii.borderS,
                onTap: () async {
                  final choice = await showCategoryPicker(
                    context,
                    kind: line.kind == 'income'
                        ? CategoryKind.income
                        : CategoryKind.expense,
                  );
                  if (choice != null) controller.setCategory(index, choice.id);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s2,
                    vertical: AppSpacing.s1,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.tag, size: 14, color: c.textSecondary),
                      const SizedBox(width: AppSpacing.s1),
                      Text(
                        data.categoryTitle(item.categoryId),
                        style: t.caption.copyWith(color: c.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  (String, StatusTone) _status(ImportItem item) {
    if (item.accountId == null) return ('Нет счёта', StatusTone.warning);
    if (item.isRefinement) {
      return ('Уточнит черновик', StatusTone.info);
    }
    if (item.isDuplicate) return ('Уже есть', StatusTone.neutral);
    if (item.line.needsReview) {
      return ('Чужая валюта: проверьте', StatusTone.warning);
    }
    return ('Новая', StatusTone.success);
  }
}

class _ConfirmStep extends StatelessWidget {
  const _ConfirmStep({
    required this.state,
    required this.data,
    required this.controller,
  });

  final ImportState state;
  final FinanceData data;
  final StatementImportController controller;

  @override
  Widget build(BuildContext context) {
    final summary = summarize(state.items);
    final closing = state.statement?.closingBalance;
    final t = context.text;
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          key: const Key('import-confirm-card'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('К импорту', style: t.h3),
              const SizedBox(height: AppSpacing.s2),
              Text(
                'Создать операций: ${summary.toCreate}',
                key: const Key('import-confirm-create'),
                style: t.body,
              ),
              Text('Уточнить черновиков: ${summary.toRefine}', style: t.body),
              Text(
                'Пропустить как уже существующие: ${summary.duplicates}',
                style: t.body,
              ),
              if (summary.foreign > 0)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s2),
                  child: Text(
                    '${summary.foreign} в чужой валюте: попадут в '
                    '«Черновики» со статусом «Требует проверки».',
                    style: t.caption.copyWith(color: c.textSecondary),
                  ),
                ),
              if (closing != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s2),
                  child: Text(
                    'Остаток на конец периода '
                    '${momentText(closing.at, data.now, withTime: false)}: '
                    'будет записана точка сверки.',
                    key: const Key('import-confirm-closing'),
                    style: t.caption.copyWith(color: c.textSecondary),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
        _NavRow(
          onBack: controller.back,
          nextLabel: state.busy ? 'Сохраняем…' : 'Импортировать',
          onNext: state.busy ? null : () => unawaited(controller.commit()),
          nextKey: const Key('import-commit'),
        ),
      ],
    );
  }
}

class _DoneStep extends StatelessWidget {
  const _DoneStep({required this.state, required this.controller});

  final ImportState state;
  final StatementImportController controller;

  @override
  Widget build(BuildContext context) {
    final result = state.result!;
    return AppCard(
      key: const Key('import-done'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: StatusPill(label: 'Готово', tone: StatusTone.success),
          ),
          const SizedBox(height: AppSpacing.s3),
          Text(
            'Создано операций: ${result.created}',
            key: const Key('import-done-created'),
            style: context.text.body,
          ),
          Text(
            'Уточнено черновиков: ${result.refined}',
            style: context.text.body,
          ),
          Text('Пропущено: ${result.skipped}', style: context.text.body),
          if (result.checkpointCreated)
            Text(
              'Остаток из выписки записан как точка сверки.',
              style: context.text.body,
            ),
          const SizedBox(height: AppSpacing.s4),
          Wrap(
            spacing: AppSpacing.s2,
            children: [
              FilledButton(
                key: const Key('import-finish'),
                onPressed: () {
                  controller.reset();
                  context.go('/finance/banks');
                },
                child: const Text('Готово'),
              ),
              OutlinedButton(
                key: const Key('import-another'),
                onPressed: controller.reset,
                child: const Text('Ещё одну выписку'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
