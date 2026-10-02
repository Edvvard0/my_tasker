import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/category_editor.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_states.dart';
import 'package:my_tasker/features/finance/presentation/widgets/finance_tiles.dart';
import 'package:my_tasker/features/finance/presentation/widgets/segmented_pill.dart';

/// «Категории»: расходы и доходы, два уровня (категория и подкатегории);
/// создание, правка и удаление.
class CategoriesScreen extends ConsumerStatefulWidget {
  const CategoriesScreen({super.key});

  @override
  ConsumerState<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends ConsumerState<CategoriesScreen> {
  CategoryKind _kind = CategoryKind.expense;

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider);
    final Widget body;
    if (categories.hasError && !categories.hasValue) {
      body = const FinanceErrorNotice();
    } else if (!categories.hasValue) {
      body = const ListSkeleton(rows: 5);
    } else {
      final all = categories.requireValue;
      final ofKind = [
        for (final c in all)
          if (c.kind == _kind) c,
      ];
      final ids = {for (final c in ofKind) c.id};
      // Подкатегория удалённого родителя — на верхнем уровне (spec 2).
      final tops = [
        for (final c in ofKind)
          if (c.parentId == null || !ids.contains(c.parentId)) c,
      ];
      body = tops.isEmpty
          ? EmptyState(
              key: const Key('cats-empty'),
              icon: LucideIcons.tags,
              title: 'Категорий нет',
              message:
                  'Стартовые категории появятся после первой синхронизации. '
                  'Можно добавить свою.',
              action: FilledButton(
                key: const Key('cats-empty-add'),
                onPressed: () =>
                    unawaited(showCategoryEditor(context, kind: _kind)),
                child: const Text('Добавить категорию'),
              ),
            )
          : Column(
              key: const Key('cats-list'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final top in tops) ...[
                  _CategoryRow(category: top, kind: _kind),
                  for (final child in ofKind)
                    if (child.parentId == top.id)
                      _CategoryRow(category: child, kind: _kind, child: true),
                ],
              ],
            );
    }
    return ScreenScaffold(
      title: 'Категории',
      parentLabel: 'Финансы',
      onBack: () => context.go('/finance'),
      actions: [
        IconButton(
          key: const Key('cat-add'),
          tooltip: 'Новая категория',
          onPressed: () => unawaited(showCategoryEditor(context, kind: _kind)),
          icon: const Icon(LucideIcons.plus, size: 22),
        ),
      ],
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const FinanceOfflineNotice(),
              SegmentedPill<CategoryKind>(
                keyPrefix: 'cats-kind',
                options: {for (final k in CategoryKind.values) k: k.label},
                selected: _kind,
                onChanged: (k) => setState(() => _kind = k),
              ),
              const SizedBox(height: AppSpacing.s3),
              body,
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.category,
    required this.kind,
    this.child = false,
  });

  final FinanceCategory category;
  final CategoryKind kind;
  final bool child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Padding(
      padding: EdgeInsets.only(left: child ? AppSpacing.s8 : 0),
      child: InkWell(
        key: Key('cat-row-${category.id}'),
        borderRadius: AppRadii.borderM,
        onTap: () =>
            unawaited(showCategoryEditor(context, categoryId: category.id)),
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
          child: Row(
            children: [
              LeadingIcon(
                categoryIcon(category.icon),
                color: parseHexColor(category.color),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Text(
                  category.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: child ? t.body : t.bodyStrong,
                ),
              ),
              if (!child)
                IconButton(
                  key: Key('cat-add-sub-${category.id}'),
                  tooltip: 'Добавить подкатегорию',
                  onPressed: () => unawaited(
                    showCategoryEditor(
                      context,
                      kind: kind,
                      parentId: category.id,
                    ),
                  ),
                  icon: Icon(
                    LucideIcons.plus,
                    size: 18,
                    color: c.textSecondary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
