import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_icons.dart';

/// Результат выбора категории: [id] `null` — «без категории».
class CategoryChoice {
  const CategoryChoice(this.id);

  final String? id;
}

/// Выбор категории из двухуровневого дерева вида [kind]. Возвращает
/// [CategoryChoice] или `null`, если закрыли. [topLevelOnly] — выбирать
/// только категории верхнего уровня (фильтр ленты, родитель категории).
Future<CategoryChoice?> showCategoryPicker(
  BuildContext context, {
  required CategoryKind kind,
  bool topLevelOnly = false,
  bool allowNone = true,
  String? excludeId,
}) => showEditorSheet<CategoryChoice>(
  context,
  builder: (_) => CategoryPickerSheet(
    kind: kind,
    topLevelOnly: topLevelOnly,
    allowNone: allowNone,
    excludeId: excludeId,
  ),
);

class CategoryPickerSheet extends ConsumerWidget {
  const CategoryPickerSheet({
    required this.kind,
    required this.topLevelOnly,
    required this.allowNone,
    this.excludeId,
    super.key,
  });

  final CategoryKind kind;
  final bool topLevelOnly;
  final bool allowNone;
  final String? excludeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final data = ref.watch(financeDataProvider).value;
    final tree = data?.categoryTree(kind) ?? const <CategoryNode>[];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(
          title: kind == CategoryKind.income
              ? 'Категория дохода'
              : 'Категория расхода',
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: AppSpacing.s4),
            children: [
              if (allowNone)
                ListTile(
                  key: const Key('category-pick-none'),
                  leading: Icon(
                    LucideIcons.tag,
                    size: 20,
                    color: c.textSecondary,
                  ),
                  title: Text('Без категории', style: t.body),
                  onTap: () =>
                      Navigator.of(context).pop(const CategoryChoice(null)),
                ),
              if (tree.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.s6),
                  child: Text(
                    'Категорий пока нет. Добавьте их в разделе «Категории».',
                    key: const Key('category-pick-empty'),
                    style: t.body.copyWith(color: c.textSecondary),
                  ),
                ),
              for (final node in tree)
                if (node.category.id != excludeId) ...[
                  ListTile(
                    key: Key('category-pick-${node.category.id}'),
                    leading: Icon(
                      categoryIcon(node.category.icon),
                      size: 20,
                      color: c.textSecondary,
                    ),
                    title: Text(node.category.name, style: t.body),
                    onTap: () =>
                        Navigator.of(context)
                            .pop(CategoryChoice(node.category.id)),
                  ),
                  if (!topLevelOnly)
                    for (final child in node.children)
                      ListTile(
                        key: Key('category-pick-${child.id}'),
                        contentPadding: const EdgeInsets.only(
                          left: AppSpacing.s12,
                          right: AppSpacing.s4,
                        ),
                        leading: Icon(
                          categoryIcon(child.icon),
                          size: 18,
                          color: c.textTertiary,
                        ),
                        title: Text(child.name, style: t.bodyS),
                        onTap: () =>
                            Navigator.of(context).pop(CategoryChoice(child.id)),
                      ),
                ],
            ],
          ),
        ),
      ],
    );
  }
}
