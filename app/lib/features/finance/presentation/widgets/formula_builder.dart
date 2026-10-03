import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_validation.dart';
import 'package:my_tasker/features/finance/domain/goal_models.dart';
import 'package:my_tasker/features/finance/domain/goal_views.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/goal_format.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_pickers.dart';
import 'package:my_tasker/features/finance/presentation/widgets/goal_tiles.dart';
import 'package:my_tasker/features/finance/presentation/widgets/segmented_pill.dart';

/// Выбор нескольких счетов (не больше [maxTermIds]): список с галочками и
/// «Готово». `null` — отмена; результат — id в порядке выбора.
Future<List<String>?> showAccountsMultiPicker(
  BuildContext context, {
  required List<Account> accounts,
  required List<String> selected,
}) => showPickerSheet<List<String>>(
  context,
  title: 'Какие счета считать',
  builder: (sheetContext) => _AccountsMultiList(
    accounts: accounts,
    selected: selected,
    onDone: (ids) => Navigator.of(sheetContext).pop(ids),
  ),
);

class _AccountsMultiList extends StatefulWidget {
  const _AccountsMultiList({
    required this.accounts,
    required this.selected,
    required this.onDone,
  });

  final List<Account> accounts;
  final List<String> selected;
  final ValueChanged<List<String>> onDone;

  @override
  State<_AccountsMultiList> createState() => _AccountsMultiListState();
}

class _AccountsMultiListState extends State<_AccountsMultiList> {
  late final List<String> _chosen = [...widget.selected];

  bool get _full => _chosen.length >= maxTermIds;

  void _toggle(String id) => setState(() {
    if (_chosen.contains(id)) {
      _chosen.remove(id);
    } else if (!_full) {
      _chosen.add(id);
    }
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Column(
      key: const Key('accounts-multi-picker'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final a in widget.accounts)
          InkWell(
            key: Key('multi-account-${a.id}'),
            borderRadius: AppRadii.borderM,
            onTap: () => _toggle(a.id),
            child: Container(
              constraints: const BoxConstraints(minHeight: 56),
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s2),
              child: Row(
                children: [
                  Icon(
                    accountKindIcon(a.kind),
                    size: 18,
                    color: c.textSecondary,
                  ),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(a.name, style: t.body),
                        Text(
                          a.archived
                              ? '${accountSubtitle(a)} · в архиве'
                              : accountSubtitle(a),
                          style: t.bodyS.copyWith(color: c.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  IgnorePointer(
                    child: Checkbox(
                      value: _chosen.contains(a.id),
                      onChanged: (_) {},
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_full)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s2),
            child: Text(
              'Не больше $maxTermIds счетов в одном слагаемом.',
              key: const Key('multi-accounts-limit'),
              style: t.bodyS.copyWith(color: c.textSecondary),
            ),
          ),
        const SizedBox(height: AppSpacing.s2),
        FilledButton(
          key: const Key('multi-accounts-done'),
          onPressed: () => widget.onDone([..._chosen]),
          child: const Text('Готово'),
        ),
      ],
    );
  }
}

/// Выбор вида нового слагаемого.
Future<GoalTermKind?> showTermKindPicker(BuildContext context) =>
    showPickerSheet<GoalTermKind>(
      context,
      title: 'Что добавить в «Есть»',
      builder: (sheetContext) {
        final c = sheetContext.colors;
        final t = sheetContext.text;
        return Column(
          key: const Key('term-kind-picker'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final kind in GoalTermKind.values)
              InkWell(
                key: Key('add-kind-${kind.wire}'),
                borderRadius: AppRadii.borderM,
                onTap: () => Navigator.of(sheetContext).pop(kind),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 56),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s2,
                    vertical: AppSpacing.s2,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(kind.label, style: t.body),
                      Text(
                        goalKindHint(kind),
                        style: t.bodyS.copyWith(color: c.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );

/// Конструктор формулы «Есть» (spec 6.2): слагаемые с знаком «+»/«−»,
/// выбор счетов, добавление и удаление. Не больше [maxGoalTerms] слагаемых;
/// предупреждает о счетах, учтённых дважды (`all_accounts` + `accounts`), и
/// честно пишет, что «ожидаемые поступления» пока считаются как 0.
class FormulaBuilder extends StatelessWidget {
  const FormulaBuilder({
    required this.terms,
    required this.accounts,
    required this.onChanged,
    super.key,
  });

  final List<GoalTerm> terms;

  /// Видимые счета (включая архивные: формула считает их независимо).
  final List<Account> accounts;
  final ValueChanged<List<GoalTerm>> onChanged;

  Account? _account(String id) {
    for (final a in accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  void _replace(int index, GoalTerm term) =>
      onChanged([...terms]..[index] = term);

  Future<void> _add(BuildContext context) async {
    final kind = await showTermKindPicker(context);
    if (kind == null) return;
    final term = GoalTerm.initial(kind);
    onChanged([...terms, term]);
  }

  Future<void> _pickAccounts(BuildContext context, int index) async {
    final term = terms[index];
    final picked = await showAccountsMultiPicker(
      context,
      accounts: accounts,
      selected: term.accountIds ?? const [],
    );
    if (picked == null) return;
    _replace(index, term.copyWith(accountIds: picked));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final overlap = formulaOverlap(terms, accounts);
    final overlapNames = [
      for (final id in overlap) _account(id)?.name ?? 'Счёт',
    ];
    final hasReceivables = terms.any((x) => x.kind == GoalTermKind.receivables);
    final atLimit = terms.length >= maxGoalTerms;
    return Column(
      key: const Key('formula-builder'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Из чего складывается «Есть»: сумма слагаемых, у каждого знак «+» '
          'или «−».',
          style: t.bodyS.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: AppSpacing.s3),
        if (terms.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s3),
            child: Text(
              'В формуле пока нет слагаемых.',
              key: const Key('formula-empty'),
              style: t.bodyS.copyWith(color: c.textTertiary),
            ),
          ),
        for (var i = 0; i < terms.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s2),
            child: _TermRow(
              index: i,
              term: terms[i],
              accounts: accounts,
              onSign: (sign) => _replace(i, terms[i].copyWith(sign: sign)),
              onRemove: () => onChanged([...terms]..removeAt(i)),
              onPickAccounts: () => _pickAccounts(context, i),
              onRemoveAccount: (id) => _replace(
                i,
                terms[i].copyWith(
                  accountIds: [...?terms[i].accountIds]..remove(id),
                ),
              ),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: ElevatedButton.icon(
            key: const Key('formula-add'),
            onPressed: atLimit ? null : () => _add(context),
            icon: const Icon(LucideIcons.plus, size: 18),
            label: const Text('Добавить слагаемое'),
          ),
        ),
        if (atLimit)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s2),
            child: Text(
              'Не больше $maxGoalTerms слагаемых в формуле.',
              key: const Key('formula-limit'),
              style: t.bodyS.copyWith(color: c.textSecondary),
            ),
          ),
        if (overlap.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s3),
            child: _Warning(
              key: const Key('formula-overlap'),
              text:
                  'Счета входят и в «Все счета», и в «Выбранные счета» '
                  '(${overlapNames.join(', ')}): каждое слагаемое считается '
                  'отдельно, поэтому они учтутся дважды.',
            ),
          ),
        if (hasReceivables) const ReceivablesNote(top: AppSpacing.s3),
      ],
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: AppRadii.borderM,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.triangleAlert, size: 16, color: c.textPrimary),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text(
              text,
              style: context.text.bodyS.copyWith(color: c.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _TermRow extends StatelessWidget {
  const _TermRow({
    required this.index,
    required this.term,
    required this.accounts,
    required this.onSign,
    required this.onRemove,
    required this.onPickAccounts,
    required this.onRemoveAccount,
  });

  final int index;
  final GoalTerm term;
  final List<Account> accounts;
  final ValueChanged<GoalSign> onSign;
  final VoidCallback onRemove;
  final VoidCallback onPickAccounts;
  final ValueChanged<String> onRemoveAccount;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final ids = term.accountIds ?? const <String>[];
    final byId = {for (final a in accounts) a.id: a};
    return Container(
      key: Key('term-$index'),
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: AppRadii.borderM,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 104,
                child: SegmentedPill<GoalSign>(
                  keyPrefix: 'term-sign-$index',
                  options: {for (final s in GoalSign.values) s: s.label},
                  selected: term.sign,
                  onChanged: onSign,
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Text(
                  term.kind.label,
                  key: Key('term-kind-$index'),
                  style: t.bodyStrong,
                ),
              ),
              IconButton(
                key: Key('term-remove-$index'),
                tooltip: 'Убрать слагаемое',
                onPressed: onRemove,
                icon: const Icon(LucideIcons.x, size: 20),
              ),
            ],
          ),
          if (term.kind == GoalTermKind.accounts) ...[
            const SizedBox(height: AppSpacing.s2),
            Wrap(
              spacing: AppSpacing.s2,
              runSpacing: AppSpacing.s2,
              children: [
                for (final id in ids)
                  InputPill(
                    key: Key('term-$index-account-$id'),
                    label: byId[id]?.name ?? 'Счёт удалён',
                    icon: byId[id] == null
                        ? LucideIcons.trash2
                        : accountKindIcon(byId[id]!.kind),
                    onRemove: () => onRemoveAccount(id),
                  ),
                ElevatedButton.icon(
                  key: Key('term-accounts-$index'),
                  onPressed: onPickAccounts,
                  icon: const Icon(LucideIcons.wallet, size: 16),
                  label: Text(ids.isEmpty ? 'Выбрать счета' : 'Изменить'),
                ),
              ],
            ),
            if (ids.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.s1),
                child: Text(
                  'Выбери хотя бы один счёт.',
                  key: Key('term-$index-empty'),
                  style: t.bodyS.copyWith(color: c.textSecondary),
                ),
              ),
          ],
          if (term.kind == GoalTermKind.receivables)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s1),
              child: Text(
                term.clientIds == null
                    ? 'Все заказчики'
                    : 'Заказчики Работы: ${term.clientIds!.length}',
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}
