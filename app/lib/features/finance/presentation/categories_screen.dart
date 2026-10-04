import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/category_picker.dart';
import 'package:my_tasker/features/finance/presentation/finance_forms.dart';
import 'package:my_tasker/features/finance/presentation/finance_icons.dart';
import 'package:my_tasker/features/finance/presentation/finance_widgets.dart';
import 'package:my_tasker/features/work/presentation/work_forms.dart'
    show FormError;

/// «Категории»: двухуровневое дерево расходов и доходов. Предустановленные
/// категории можно переименовать, сменить иконку и удалить, как обычные.
class CategoriesScreen extends ConsumerStatefulWidget {
  const CategoriesScreen({super.key});

  @override
  ConsumerState<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends ConsumerState<CategoriesScreen> {
  CategoryKind _kind = CategoryKind.expense;

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      key: const Key('categories-screen'),
      title: 'Категории',
      parentLabel: 'Финансы',
      onBack: () => financeBack(context),
      actions: [
        IconButton(
          key: const Key('categories-add'),
          tooltip: 'Новая категория',
          onPressed: () => showCategoryEditor(context, kind: _kind),
          icon: const Icon(LucideIcons.squarePen, size: 22),
        ),
      ],
      child: FinanceBuilder(
        builder: (context, data) {
          final tree = data.categoryTree(_kind);
          final presetsMissing = data.categories.isEmpty;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ChipRow(
                children: [
                  for (final k in CategoryKind.values)
                    FilterPill(
                      key: Key('categories-kind-${k.wire}'),
                      label: k == CategoryKind.expense ? 'Расходы' : 'Доходы',
                      selected: _kind == k,
                      onTap: () => setState(() => _kind = k),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.s3),
              if (tree.isEmpty)
                EmptyState(
                  key: const Key('categories-empty'),
                  icon: LucideIcons.tags,
                  title: 'Категорий пока нет',
                  message: presetsMissing
                      ? 'Добавьте стандартный набор на русском или создайте '
                            'свои.'
                      : 'Создайте первую категорию.',
                  action: Wrap(
                    spacing: AppSpacing.s2,
                    runSpacing: AppSpacing.s2,
                    children: [
                      if (presetsMissing)
                        FilledButton(
                          key: const Key('categories-seed'),
                          onPressed: () => ref
                              .read(financeRepositoryProvider)
                              .seedPresetCategories(),
                          child: const Text('Стандартный набор'),
                        ),
                      OutlinedButton(
                        key: const Key('categories-empty-add'),
                        onPressed: () =>
                            showCategoryEditor(context, kind: _kind),
                        child: const Text('Своя категория'),
                      ),
                    ],
                  ),
                )
              else
                ListCard(
                  children: [
                    for (final node in tree) ...[
                      _CategoryRow(category: node.category),
                      for (final child in node.children)
                        _CategoryRow(category: child, child: true),
                    ],
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.category, this.child = false});

  final FinCategory category;
  final bool child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return ListTile(
      key: Key('category-${category.id}'),
      contentPadding: EdgeInsets.only(
        left: child ? AppSpacing.s12 : AppSpacing.s4,
        right: AppSpacing.s4,
      ),
      leading: Icon(
        categoryIcon(category.icon),
        size: child ? 18 : 20,
        color: child ? c.textTertiary : c.textSecondary,
      ),
      title: Text(category.name, style: child ? t.bodyS : t.body),
      trailing: Icon(LucideIcons.chevronRight, size: 16, color: c.textTertiary),
      onTap: () => showCategoryEditor(
        context,
        categoryId: category.id,
        kind: category.kind,
      ),
    );
  }
}

/// Форма категории: [categoryId] — правка, иначе новая вида [kind].
Future<void> showCategoryEditor(
  BuildContext context, {
  String? categoryId,
  CategoryKind kind = CategoryKind.expense,
  String? parentId,
}) => showEditorSheet<void>(
  context,
  builder: (_) =>
      CategoryEditor(categoryId: categoryId, kind: kind, parentId: parentId),
);

class CategoryEditor extends ConsumerStatefulWidget {
  const CategoryEditor({
    this.categoryId,
    this.kind = CategoryKind.expense,
    this.parentId,
    super.key,
  });

  final String? categoryId;
  final CategoryKind kind;
  final String? parentId;

  @override
  ConsumerState<CategoryEditor> createState() => _CategoryEditorState();
}

class _CategoryEditorState extends ConsumerState<CategoryEditor> {
  final _name = TextEditingController();
  bool _loading = true;
  bool _missing = false;
  FinCategory? _original;
  late CategoryKind _kind = widget.kind;
  String? _parentId;
  String? _icon;
  String? _error;
  bool _saving = false;

  bool get _isNew => widget.categoryId == null;

  @override
  void initState() {
    super.initState();
    _parentId = widget.parentId;
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
    final c = await ref
        .read(financeRepositoryProvider)
        .getCategory(widget.categoryId!);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (c == null) {
        _missing = true;
        return;
      }
      _original = c;
      _name.text = c.name;
      _kind = c.kind;
      _parentId = c.parentId;
      _icon = c.icon;
    });
  }

  Future<void> _pickParent() async {
    final choice = await showCategoryPicker(
      context,
      kind: _kind,
      topLevelOnly: true,
      excludeId: _original?.id,
    );
    if (choice != null && mounted) setState(() => _parentId = choice.id);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _error = null;
      _saving = true;
    });
    final repo = ref.read(financeRepositoryProvider);
    try {
      final base = _original;
      final category = FinCategory(
        id: base?.id ?? repo.newId(),
        name: _name.text,
        kind: _kind,
        parentId: _parentId,
        icon: _icon,
        color: base?.color,
        systemKey: base?.systemKey,
      );
      if (_isNew) {
        await repo.createCategory(category);
      } else {
        await repo.updateCategory(category);
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
      title: 'Удалить категорию?',
      message:
          'Операции останутся, но попадут в «Без категории»; подкатегории '
          'станут категориями верхнего уровня. Вернуть можно в течение 30 '
          'дней.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok || !mounted) return;
    await ref
        .read(financeRepositoryProvider)
        .deleteCategory(widget.categoryId!);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    if (_loading) return const EditorLoading();
    if (_missing) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHeader(title: 'Категория'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Категория не найдена: возможно, её удалили на другом устройстве.',
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final data = ref.watch(financeDataProvider).value;
    final hasChildren =
        data != null &&
        _original != null &&
        data.categories.any((k) => k.parentId == _original!.id);
    final parent = _parentId == null ? null : data?.categoryById[_parentId];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: _isNew ? 'Новая категория' : 'Категория'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FormBlock(
                    label: 'Название',
                    child: FormTextField(
                      key: const Key('category-name'),
                      controller: _name,
                      autofocus: _isNew,
                    ),
                  ),
                  if (_isNew)
                    FormBlock(
                      label: 'Вид',
                      child: ChipRow(
                        children: [
                          for (final k in CategoryKind.values)
                            FilterPill(
                              key: Key('category-kind-${k.wire}'),
                              label: k.label,
                              selected: _kind == k,
                              onTap: () => setState(() {
                                if (_kind != k) _parentId = null;
                                _kind = k;
                              }),
                            ),
                        ],
                      ),
                    ),
                  if (!hasChildren)
                    FormBlock(
                      label: 'Родительская категория',
                      child: PickerField(
                        key: const Key('category-parent'),
                        text: parent?.name ?? 'Нет (верхний уровень)',
                        placeholder: parent == null,
                        onTap: _pickParent,
                      ),
                    ),
                  FormBlock(
                    label: 'Иконка',
                    child: Wrap(
                      spacing: AppSpacing.s2,
                      runSpacing: AppSpacing.s2,
                      children: [
                        for (final e in categoryIcons.entries)
                          InkWell(
                            key: Key('category-icon-${e.key}'),
                            borderRadius: const BorderRadius.all(
                              Radius.circular(20),
                            ),
                            onTap: () => setState(() => _icon = e.key),
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: _icon == e.key
                                    ? c.surfaceInverse
                                    : c.surface3,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                e.value,
                                size: 20,
                                color: _icon == e.key
                                    ? c.textOnInverse
                                    : c.textPrimary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_original?.systemKey != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
                      child: Text(
                        'Предустановленная категория: её можно переименовать и '
                        'удалить, как обычную.',
                        style: t.caption.copyWith(color: c.textSecondary),
                      ),
                    ),
                  if (_error != null)
                    FormError(_error!, key: const Key('category-error')),
                ],
              ),
            ),
          ),
          EditorActions(
            saveKey: const Key('category-save'),
            onSave: _save,
            saving: _saving,
            deleteKey: const Key('category-delete'),
            onDelete: _isNew ? null : _delete,
          ),
        ],
      ),
    );
  }
}
