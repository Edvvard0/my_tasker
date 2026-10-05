import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/banks/application/bank_providers.dart';
import 'package:my_tasker/features/banks/data/bank_drafts.dart';
import 'package:my_tasker/features/banks/domain/bank_operations.dart';
import 'package:my_tasker/features/banks/domain/bank_rules.dart';
import 'package:my_tasker/features/banks/presentation/banks_widgets.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/category_picker.dart';
import 'package:my_tasker/features/finance/presentation/finance_icons.dart';
import 'package:my_tasker/features/finance/presentation/finance_widgets.dart';
import 'package:my_tasker/features/finance/presentation/transaction_editor.dart';

/// «Черновики»: операции из уведомлений банков и выписок, ещё не принятые
/// пользователем. В суммы и аналитику они не входят, пока не подтверждены.
/// Подтвердить / поправить / отклонить, массовое подтверждение, склейка
/// переводов между своими счетами.
class DraftsScreen extends ConsumerWidget {
  const DraftsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ScreenScaffold(
      key: const Key('drafts-screen'),
      title: 'Черновики',
      parentLabel: 'Банки',
      onBack: () => financeBack(context),
      child: FinanceBuilder(builder: (context, data) => DraftsBody(data: data)),
    );
  }
}

/// Содержимое экрана (используется и в golden-тесте).
class DraftsBody extends ConsumerStatefulWidget {
  const DraftsBody({required this.data, super.key});

  final FinanceData data;

  @override
  ConsumerState<DraftsBody> createState() => _DraftsBodyState();
}

class _DraftsBodyState extends ConsumerState<DraftsBody> {
  final Set<String> _selected = {};

  /// «Запомнить для этого мерчанта»: по умолчанию включено после того, как
  /// человек сам выбрал категорию.
  final Map<String, bool> _remember = {};

  List<FinTransaction> get _drafts => [
    for (final t in widget.data.transactions)
      if (!t.isConfirmed) t,
  ];

  Future<void> _confirm(FinTransaction tx) async {
    await ref
        .read(bankDraftsProvider)
        .confirm(tx.id, remember: _remember[tx.id] ?? false);
    if (mounted) setState(() => _selected.remove(tx.id));
  }

  Future<void> _reject(FinTransaction tx) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Отклонить операцию?',
      message:
          'Черновик уйдёт в корзину и не попадёт в суммы. Вернуть можно в '
          'течение 30 дней.',
      confirmLabel: 'Отклонить',
      danger: true,
    );
    if (!ok || !mounted) return;
    await ref.read(bankDraftsProvider).reject(tx.id);
    if (mounted) setState(() => _selected.remove(tx.id));
  }

  /// «Это дубль»: черновик уходит в корзину без лишних вопросов — формулировка
  /// кнопки сама называет действие.
  Future<void> _rejectDuplicate(FinTransaction tx) async {
    await ref.read(bankDraftsProvider).reject(tx.id);
    if (mounted) setState(() => _selected.remove(tx.id));
  }

  Future<void> _pickCategory(FinTransaction tx) async {
    final kind = tx.kind == TxKind.income
        ? CategoryKind.income
        : CategoryKind.expense;
    final choice = await showCategoryPicker(context, kind: kind);
    if (choice == null || !mounted) return;
    await ref
        .read(financeRepositoryProvider)
        .updateTransaction(tx.copyWith(categoryId: choice.id));
    if (mounted) setState(() => _remember[tx.id] = choice.id != null);
  }

  Future<void> _confirmSelected() async {
    final count = await ref.read(bankDraftsProvider).confirmAll(_selected);
    if (!mounted) return;
    setState(_selected.clear);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          'Подтверждено: $count ${plural(count, 'операция', 'операции', 'операций')}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final drafts = _drafts;
    final dismissed = ref.watch(dismissedTransfersProvider).value ?? const {};
    final pairs = transferSuggestions(data.transactions, dismissed: dismissed);
    final possible =
        ref.watch(possibleDuplicateTxIdsProvider).value ?? const <String>{};
    final confirmable = [
      for (final t in drafts)
        if (t.status == TxStatus.draft) t,
    ];
    // Выбранное могло исчезнуть (подтверждено на другом экране).
    _selected.removeWhere((id) => !confirmable.any((t) => t.id == id));
    if (drafts.isEmpty && pairs.isEmpty) {
      return const EmptyState(
        key: Key('drafts-empty'),
        icon: LucideIcons.clipboardCheck,
        title: 'Черновиков нет',
        message:
            'Операции из уведомлений банков и выписок появятся здесь: их '
            'можно подтвердить, поправить или отклонить.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final pair in pairs) ...[
          _TransferCard(data: data, pair: pair),
          const SizedBox(height: AppSpacing.s2),
        ],
        if (confirmable.isNotEmpty)
          _BulkBar(
            total: confirmable.length,
            selected: _selected.length,
            onSelectAll: () => setState(() {
              if (_selected.length == confirmable.length) {
                _selected.clear();
              } else {
                _selected
                  ..clear()
                  ..addAll(confirmable.map((t) => t.id));
              }
            }),
            onConfirm: _selected.isEmpty ? null : _confirmSelected,
          ),
        for (final tx in drafts) ...[
          _DraftCard(
            data: data,
            tx: tx,
            selected: _selected.contains(tx.id),
            possibleDuplicate: possible.contains(tx.id),
            remember: _remember[tx.id] ?? false,
            onSelect: tx.status != TxStatus.draft
                ? null
                : (v) => setState(() {
                    if (v) {
                      _selected.add(tx.id);
                    } else {
                      _selected.remove(tx.id);
                    }
                  }),
            onRemember: (v) => setState(() => _remember[tx.id] = v),
            onCategory: () => _pickCategory(tx),
            onConfirm: () => _confirm(tx),
            onEdit: () => showTransactionEditor(context, txId: tx.id),
            onReject: () => _reject(tx),
            onDuplicate: () => _rejectDuplicate(tx),
          ),
          const SizedBox(height: AppSpacing.s2),
        ],
      ],
    );
  }
}

class _BulkBar extends StatelessWidget {
  const _BulkBar({
    required this.total,
    required this.selected,
    required this.onSelectAll,
    required this.onConfirm,
  });

  final int total;
  final int selected;
  final VoidCallback onSelectAll;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s2),
      child: Row(
        children: [
          TextButton(
            key: const Key('drafts-select-all'),
            onPressed: onSelectAll,
            child: Text(
              selected == total ? 'Снять выбор' : 'Выбрать все ($total)',
            ),
          ),
          const Spacer(),
          FilledButton.icon(
            key: const Key('drafts-confirm-selected'),
            onPressed: onConfirm,
            icon: const Icon(LucideIcons.check, size: 18),
            label: Text(
              selected == 0 ? 'Подтвердить' : 'Подтвердить ($selected)',
            ),
          ),
        ],
      ),
    );
  }
}

class _DraftCard extends StatelessWidget {
  const _DraftCard({
    required this.data,
    required this.tx,
    required this.selected,
    required this.possibleDuplicate,
    required this.remember,
    required this.onSelect,
    required this.onRemember,
    required this.onCategory,
    required this.onConfirm,
    required this.onEdit,
    required this.onReject,
    required this.onDuplicate,
  });

  final FinanceData data;
  final FinTransaction tx;
  final bool selected;

  /// Похоже на уже внесённую операцию (дубль выписки или ручной записи).
  final bool possibleDuplicate;
  final bool remember;
  final ValueChanged<bool>? onSelect;
  final ValueChanged<bool> onRemember;
  final VoidCallback onCategory;
  final VoidCallback onConfirm;
  final VoidCallback onEdit;
  final VoidCallback onReject;
  final VoidCallback onDuplicate;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final needsReview = tx.status == TxStatus.needsReview;
    final category = tx.categoryId == null
        ? null
        : data.categoryById[tx.categoryId];
    final amount = tx.kind == TxKind.income ? tx.amount : -tx.amount;
    final merchant = tx.merchant;
    final canRemember =
        merchant != null && merchant.isNotEmpty && tx.categoryId != null;
    return AppCard(
      key: Key('draft-card-${tx.id}'),
      padding: const EdgeInsets.all(AppSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (onSelect != null)
                Checkbox(
                  key: Key('draft-select-${tx.id}'),
                  value: selected,
                  onChanged: (v) => onSelect!(v ?? false),
                )
              else
                const SizedBox(width: AppSpacing.s2),
              IconBadge(
                icon: category != null
                    ? categoryIcon(category.icon)
                    : bankKindIcon(tx.kind.wire),
                size: 36,
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.transactionTitle(tx),
                      style: t.bodyStrong,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      [
                        data.accountName(tx.accountId),
                        momentText(
                          tx.occurredAt,
                          data.now,
                          withTime: !isDateOnlyMoment(tx),
                        ),
                      ].join(' · '),
                      style: t.caption.copyWith(color: c.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              AmountText(
                amount,
                signed: true,
                textKey: Key('draft-amount-${tx.id}'),
                style: t.numL.copyWith(color: c.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
          Wrap(
            spacing: AppSpacing.s2,
            runSpacing: AppSpacing.s1,
            children: [
              StatusPill(
                label: tx.status.label,
                tone: needsReview ? StatusTone.warning : StatusTone.info,
              ),
              StatusPill(label: tx.source.label, tone: StatusTone.neutral),
              if (possibleDuplicate)
                StatusPill(
                  key: Key('draft-possible-duplicate-${tx.id}'),
                  label: 'Возможный дубль',
                  tone: StatusTone.warning,
                ),
            ],
          ),
          if (possibleDuplicate) ...[
            const SizedBox(height: AppSpacing.s2),
            Text(
              'Похожая операция (из выписки или внесённая вручную) уже есть. '
              'Это повтор или отдельная покупка?',
              key: Key('draft-possible-duplicate-text-${tx.id}'),
              style: t.caption.copyWith(color: c.textSecondary),
            ),
          ],
          if (tx.comment != null && tx.comment!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s2),
            Text(
              tx.comment!,
              key: Key('draft-comment-${tx.id}'),
              style: t.caption.copyWith(color: c.textSecondary),
            ),
          ],
          const SizedBox(height: AppSpacing.s2),
          InkWell(
            key: Key('draft-category-${tx.id}'),
            borderRadius: AppRadii.borderS,
            onTap: onCategory,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s3,
                vertical: AppSpacing.s2,
              ),
              decoration: BoxDecoration(
                color: c.surface3,
                borderRadius: AppRadii.borderS,
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.tag, size: 16, color: c.textSecondary),
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: Text(
                      data.categoryTitle(tx.categoryId),
                      style: t.bodyS.copyWith(
                        color: tx.categoryId == null
                            ? c.textTertiary
                            : c.textPrimary,
                      ),
                    ),
                  ),
                  Icon(
                    LucideIcons.chevronRight,
                    size: 16,
                    color: c.textTertiary,
                  ),
                ],
              ),
            ),
          ),
          if (canRemember)
            InkWell(
              borderRadius: AppRadii.borderS,
              onTap: () => onRemember(!remember),
              child: Row(
                children: [
                  Checkbox(
                    key: Key('draft-remember-${tx.id}'),
                    value: remember,
                    onChanged: (v) => onRemember(v ?? false),
                    visualDensity: VisualDensity.compact,
                  ),
                  Expanded(
                    child: Text(
                      'Запомнить категорию для «$merchant»',
                      style: t.caption,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.s2),
          Wrap(
            spacing: AppSpacing.s2,
            runSpacing: AppSpacing.s2,
            children: [
              if (needsReview)
                FilledButton(
                  key: Key('draft-check-${tx.id}'),
                  onPressed: onEdit,
                  child: const Text('Проверить'),
                )
              else
                FilledButton(
                  key: Key('draft-confirm-${tx.id}'),
                  onPressed: onConfirm,
                  child: Text(
                    possibleDuplicate ? 'Отдельная покупка' : 'Подтвердить',
                  ),
                ),
              if (!needsReview)
                OutlinedButton(
                  key: Key('draft-edit-${tx.id}'),
                  onPressed: onEdit,
                  child: const Text('Поправить'),
                ),
              TextButton(
                key: Key('draft-reject-${tx.id}'),
                onPressed: possibleDuplicate ? onDuplicate : onReject,
                style: TextButton.styleFrom(foregroundColor: c.danger),
                child: Text(possibleDuplicate ? 'Это дубль' : 'Отклонить'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// «Похоже на перевод между своими счетами»: склеить в один перевод.
class _TransferCard extends ConsumerWidget {
  const _TransferCard({required this.data, required this.pair});

  final FinanceData data;
  final TransferPair pair;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final expense = data.transactions.firstWhere((x) => x.id == pair.expenseId);
    final income = data.transactions.firstWhere((x) => x.id == pair.incomeId);
    return AppCard(
      key: Key('transfer-card-${pair.expenseId}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(LucideIcons.arrowLeftRight, size: 18),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text(
                  'Похоже на перевод между своими счетами',
                  style: t.bodyStrong,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${data.accountName(expense.accountId)} → '
                  '${data.accountName(income.accountId)}',
                  style: t.bodyS.copyWith(color: c.textSecondary),
                ),
              ),
              AmountText(expense.amount, style: t.numM),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          Wrap(
            spacing: AppSpacing.s2,
            children: [
              FilledButton(
                key: Key('transfer-merge-${pair.expenseId}'),
                onPressed: () => ref
                    .read(bankDraftsProvider)
                    .mergeTransfer(
                      expenseId: pair.expenseId,
                      incomeId: pair.incomeId,
                    ),
                child: const Text('Склеить в перевод'),
              ),
              TextButton(
                key: Key('transfer-dismiss-${pair.expenseId}'),
                onPressed: () => ref
                    .read(dismissedTransfersProvider.notifier)
                    .dismiss(transferPairKey(pair)),
                child: const Text('Это не перевод'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
