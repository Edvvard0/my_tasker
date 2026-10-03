import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/widgets/segmented_pill.dart';

/// Иконки, доступные для выбора: по одной на каждый рисунок Lucide.
final List<MapEntry<String, IconData>> categoryIconChoices = () {
  final seen = <IconData>{};
  return [
    for (final e in categoryIcons.entries)
      if (seen.add(e.value)) e,
  ];
}();

/// Открывает редактор категории: [categoryId] — правка, иначе создание
/// (с видом [kind] и, для подкатегории, родителем [parentId]).
Future<void> showCategoryEditor(
  BuildContext context, {
  String? categoryId,
  CategoryKind kind = CategoryKind.expense,
  String? parentId,
}) => showEditorSheet<void>(
  context,
  builder: (_) => CategoryEditor(
    categoryId: categoryId,
    initialKind: kind,
    initialParentId: parentId,
  ),
);

/// Редактор категории: название, вид (только при создании), родитель
/// (два уровня), иконка и цвет из небольшого набора; удаление.
class CategoryEditor extends ConsumerStatefulWidget {
  const CategoryEditor({
    this.categoryId,
    this.initialKind = CategoryKind.expense,
    this.initialParentId,
    super.key,
  });

  final String? categoryId;
  final CategoryKind initialKind;
  final String? initialParentId;

  @override
  ConsumerState<CategoryEditor> createState() => _CategoryEditorState();
}

class _CategoryEditorState extends ConsumerState<CategoryEditor> {
  final _name = TextEditingController();

  FinanceCategory? _original;
  late CategoryKind _kind = widget.initialKind;
  String? _parentId;
  String? _icon;
  String? _color;
  bool _loading = true;
  bool _missing = false;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.categoryId == null;

  @override
  void initState() {
    super.initState();
    _parentId = widget.initialParentId;
    if (_isNew) {
      _loading = false;
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(financeRepositoryProvider);
    final category = await repo.getCategory(widget.categoryId!);
    // Родителя могли удалить: тогда категория уже показывается в списке
    // верхнего уровня, и редактор начинает с «верхнего уровня».
    final parentId = category?.parentId;
    final parentLive =
        parentId == null ||
        (await repo.categories()).any((c) => c.id == parentId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (category == null) {
        _missing = true;
        return;
      }
      _original = category;
      _name.text = category.name;
      _kind = category.kind;
      _parentId = parentLive ? category.parentId : null;
      _icon = category.icon;
      _color = category.color;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _error = null;
      _saving = true;
    });
    final repo = ref.read(financeRepositoryProvider);
    try {
      final original = _original;
      if (original == null) {
        await repo.createCategory(
          FinanceCategory(
            id: repo.newId(),
            name: _name.text,
            kind: _kind,
            parentId: _parentId,
            icon: _icon,
            color: _color,
          ),
        );
      } else {
        await repo.updateCategory(
          original.copyWith(
            name: _name.text,
            parentId: _parentId,
            icon: _icon,
            color: _color,
          ),
        );
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
    final category = _original;
    if (category == null) return;
    final repo = ref.read(financeRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showConfirmDialog(
      context,
      title: 'Удалить «${category.name}»?',
      message:
          'Операции останутся, но будут без категории. Подкатегории станут '
          'категориями верхнего уровня. Удалённое хранится в корзине 30 '
          'дней.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok) return;
    await repo.deleteCategory(category.id);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('Категория «${category.name}» удалена'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Отменить',
            onPressed: () => repo.restoreCategory(category.id),
          ),
        ),
      );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final title = _isNew ? 'Новая категория' : 'Категория';
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
          SheetHeader(title: title),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Категория не найдена: возможно, её удалили на другом '
              'устройстве.',
              key: const Key('cat-missing'),
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final all = ref.watch(categoriesProvider).value ?? const [];
    final id = _original?.id;
    final hasChildren = id != null && all.any((x) => x.parentId == id);
    final parents = [
      for (final x in all)
        if (x.kind == _kind && x.parentId == null && x.id != id) x,
    ];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: title),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_isNew)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.s4),
                      child: SegmentedPill<CategoryKind>(
                        keyPrefix: 'cat-kind',
                        options: {
                          for (final k in CategoryKind.values) k: k.label,
                        },
                        selected: _kind,
                        onChanged: (k) => setState(() {
                          _kind = k;
                          _parentId = null;
                        }),
                      ),
                    ),
                  FormBlock(
                    label: 'Название',
                    child: FormTextField(
                      key: const Key('cat-name'),
                      controller: _name,
                      autofocus: _isNew,
                      decoration: const InputDecoration(
                        hintText: 'Например, «Кофе»',
                      ),
                    ),
                  ),
                  if (!hasChildren && parents.isNotEmpty)
                    FormBlock(
                      label: 'Родитель',
                      child: ChipRow(
                        children: [
                          FilterPill(
                            key: const Key('cat-parent-none'),
                            label: 'Верхний уровень',
                            selected: _parentId == null,
                            onTap: () => setState(() => _parentId = null),
                          ),
                          for (final p in parents)
                            FilterPill(
                              key: Key('cat-parent-${p.id}'),
                              label: p.name,
                              selected: _parentId == p.id,
                              onTap: () => setState(() => _parentId = p.id),
                            ),
                        ],
                      ),
                    ),
                  FormBlock(
                    label: 'Иконка',
                    child: Wrap(
                      spacing: AppSpacing.s2,
                      runSpacing: AppSpacing.s2,
                      children: [
                        for (final e in categoryIconChoices)
                          _Swatch(
                            key: Key('cat-icon-${e.key}'),
                            selected: _icon == e.key,
                            onTap: () => setState(() => _icon = e.key),
                            child: Icon(
                              e.value,
                              size: 20,
                              color: _icon == e.key
                                  ? c.textOnInverse
                                  : c.textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  FormBlock(
                    label: 'Цвет',
                    child: Wrap(
                      spacing: AppSpacing.s2,
                      runSpacing: AppSpacing.s2,
                      children: [
                        for (final hex in categoryColors)
                          _Swatch(
                            key: Key('cat-color-${hex.substring(1)}'),
                            selected: _color == hex,
                            onTap: () => setState(() => _color = hex),
                            child: Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                color: parseHexColor(hex),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
                      child: Row(
                        key: const Key('cat-error'),
                        children: [
                          Icon(
                            LucideIcons.circleAlert,
                            size: 16,
                            color: c.danger,
                          ),
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
                    key: const Key('cat-delete'),
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
                  key: const Key('cat-save'),
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

/// Круглая плитка выбора (иконка или цвет): выбранная — белая заливка.
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.selected,
    required this.onTap,
    required this.child,
    super.key,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? c.surfaceInverse : c.surface3,
            shape: BoxShape.circle,
          ),
          child: child,
        ),
      ),
    );
  }
}
