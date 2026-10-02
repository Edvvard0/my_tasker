import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/domain/finance_views.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_tiles.dart';

/// Открывает выбор поверх формы: на телефоне — нижний лист, на десктопе —
/// небольшое окно по центру.
Future<T?> showPickerSheet<T>(
  BuildContext context, {
  required String title,
  required Widget Function(BuildContext context) builder,
}) {
  Widget body(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s4,
        AppSpacing.s2,
        AppSpacing.s4,
        AppSpacing.s4,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s2,
              0,
              AppSpacing.s2,
              AppSpacing.s2,
            ),
            child: Text(title, style: context.text.h2),
          ),
          Flexible(child: SingleChildScrollView(child: builder(context))),
        ],
      ),
    ),
  );
  if (context.windowClass.isCompact) {
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.8,
      ),
      builder: body,
    );
  }
  return showDialog<T>(
    context: context,
    builder: (dialogContext) => Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 420,
          maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.8,
        ),
        child: body(dialogContext),
      ),
    ),
  );
}

/// Выбор счёта: список со значками и балансами; `null` — отмена.
Future<String?> showAccountPicker(
  BuildContext context, {
  required List<Account> accounts,
  required FinanceBalances? balances,
  String? selectedId,
  String title = 'Счёт',
  String? allLabel,
}) => showPickerSheet<String>(
  context,
  title: title,
  builder: (sheetContext) => Column(
    key: const Key('account-picker'),
    children: [
      if (allLabel != null)
        _PlainRow(
          key: const Key('pick-account-all'),
          icon: LucideIcons.wallet,
          label: allLabel,
          selected: selectedId == null,
          onTap: () => Navigator.of(sheetContext).pop(''),
        ),
      for (final a in accounts)
        AccountTile(
          key: Key('pick-account-${a.id}'),
          account: a,
          balance: balances?.of(a.id) ?? 0,
          selected: a.id == selectedId,
          onTap: () => Navigator.of(sheetContext).pop(a.id),
        ),
    ],
  ),
);

/// Простая строка выбора (иконка и подпись) для служебных вариантов.
class _PlainRow extends StatelessWidget {
  const _PlainRow({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      borderRadius: AppRadii.borderM,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s2),
        decoration: BoxDecoration(
          color: selected ? c.surface3 : Colors.transparent,
          borderRadius: AppRadii.borderM,
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: c.textSecondary),
            const SizedBox(width: AppSpacing.s3),
            Expanded(child: Text(label, style: context.text.body)),
            if (selected)
              Icon(LucideIcons.check, size: 16, color: c.textPrimary),
          ],
        ),
      ),
    );
  }
}

/// Результат выбора категории: конкретная, «без категории» или «все».
class CategoryPick {
  const CategoryPick({this.id, this.without = false});

  /// Выбранная категория; `null` — «все» / «без категории».
  final String? id;

  /// Только операции без категории (в фильтре ленты).
  final bool without;
}

/// Выбор категории: два уровня (родитель и его подкатегории). [kind] —
/// нужный вид; `null` — оба вида с заголовками («Расходы», «Доходы», для
/// фильтра ленты). [noneLabel] — строка «снять выбор» («Без категории» в
/// форме, «Все категории» в фильтре); [withWithout] добавляет «Без
/// категории» в фильтр. `null` — отмена.
Future<CategoryPick?> showCategoryPicker(
  BuildContext context, {
  required List<FinanceCategory> categories,
  CategoryKind? kind,
  String? selectedId,
  String noneLabel = 'Без категории',
  bool withWithout = false,
}) => showPickerSheet<CategoryPick>(
  context,
  title: 'Категория',
  builder: (sheetContext) {
    final kinds = kind == null ? CategoryKind.values : [kind];
    Widget row(FinanceCategory c, {bool child = false}) {
      final colors = sheetContext.colors;
      final selected = c.id == selectedId;
      return InkWell(
        key: Key('pick-category-${c.id}'),
        borderRadius: AppRadii.borderM,
        onTap: () => Navigator.of(sheetContext).pop(CategoryPick(id: c.id)),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: EdgeInsets.only(
            left: AppSpacing.s2 + (child ? AppSpacing.s6 : 0),
            right: AppSpacing.s2,
          ),
          decoration: BoxDecoration(
            color: selected ? colors.surface3 : Colors.transparent,
            borderRadius: AppRadii.borderM,
          ),
          child: Row(
            children: [
              Icon(
                categoryIcon(c.icon),
                size: 18,
                color: parseHexColor(c.color) ?? colors.textSecondary,
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Text(
                  c.name,
                  style: sheetContext.text.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (selected)
                Icon(LucideIcons.check, size: 16, color: colors.textPrimary),
            ],
          ),
        ),
      );
    }

    final children = <Widget>[
      _PlainRow(
        key: const Key('pick-category-none'),
        icon: LucideIcons.circleSlash,
        label: noneLabel,
        selected: selectedId == null,
        onTap: () => Navigator.of(sheetContext).pop(const CategoryPick()),
      ),
      if (withWithout)
        _PlainRow(
          key: const Key('pick-category-without'),
          icon: LucideIcons.tag,
          label: 'Без категории',
          selected: false,
          onTap: () =>
              Navigator.of(sheetContext).pop(const CategoryPick(without: true)),
        ),
    ];
    for (final k in kinds) {
      final ofKind = [
        for (final c in categories)
          if (c.kind == k) c,
      ];
      if (ofKind.isEmpty) continue;
      final ids = {for (final c in ofKind) c.id};
      // Подкатегория удалённого родителя показывается на верхнем уровне.
      final tops = [
        for (final c in ofKind)
          if (c.parentId == null || !ids.contains(c.parentId)) c,
      ];
      if (kind == null) {
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s2,
              AppSpacing.s3,
              AppSpacing.s2,
              AppSpacing.s1,
            ),
            child: Text(
              k == CategoryKind.expense ? 'РАСХОДЫ' : 'ДОХОДЫ',
              style: sheetContext.text.overline.copyWith(
                color: sheetContext.colors.textTertiary,
              ),
            ),
          ),
        );
      }
      for (final top in tops) {
        children.add(row(top));
        for (final child in ofKind) {
          if (child.parentId == top.id) children.add(row(child, child: true));
        }
      }
    }
    return Column(
      key: const Key('category-picker'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  },
);
