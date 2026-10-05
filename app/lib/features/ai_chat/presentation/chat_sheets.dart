import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/ai_chat/application/ai_providers.dart';
import 'package:my_tasker/features/ai_chat/application/chat_context.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/data/context_sources.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_format.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_protocol.dart';
import 'package:my_tasker/features/ai_chat/domain/context_builder.dart';
import 'package:my_tasker/features/calendar/application/calendar_providers.dart';
import 'package:my_tasker/features/finance/application/privacy_providers.dart';
import 'package:my_tasker/features/finance/presentation/finance_gate.dart';

/// Выбранная модель (id из каталога, имя для показа).
class ModelChoice {
  const ModelChoice({
    required this.id,
    required this.name,
    required this.supportsTools,
  });

  final String id;
  final String name;
  final bool supportsTools;
}

/// Короткое имя модели для пилюли: имя избранной или хвост id.
String shortModelName(String? id, List<ModelFavorite> favorites) {
  if (id == null) return 'Выбрать модель';
  for (final f in favorites) {
    if (f.modelId == id) return f.displayName;
  }
  final slash = id.lastIndexOf('/');
  return slash >= 0 ? id.substring(slash + 1) : id;
}

/// Строка выбора в листах: заголовок, подпись, отметка текущего.
class PickerRow extends StatelessWidget {
  const PickerRow({
    required this.title,
    required this.onTap,
    this.subtitle,
    this.selected = false,
    this.leading,
    this.trailing,
    super.key,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final IconData? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s6,
          vertical: AppSpacing.s3,
        ),
        child: Row(
          children: [
            if (leading != null) ...[
              Icon(leading, size: 20, color: c.textSecondary),
              const SizedBox(width: AppSpacing.s3),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: t.body),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: t.bodyS.copyWith(color: c.textSecondary),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            ?trailing,
            if (selected)
              Icon(LucideIcons.check, size: 18, color: c.textPrimary),
          ],
        ),
      ),
    );
  }
}

// ---- модель ---------------------------------------------------------------

/// Быстрый выбор модели (02, 5.2.3): избранные сверху, ниже поиск по
/// каталогу, внизу «Управлять моделями».
Future<ModelChoice?> showModelPicker(
  BuildContext context, {
  required String? currentModel,
}) => showEditorSheet<ModelChoice>(
  context,
  builder: (_) => ModelPickerSheet(currentModel: currentModel),
);

class ModelPickerSheet extends ConsumerStatefulWidget {
  const ModelPickerSheet({required this.currentModel, super.key});

  final String? currentModel;

  @override
  ConsumerState<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends ConsumerState<ModelPickerSheet> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final favorites = ref.watch(favoritesProvider).value ?? const [];
    final catalog = ref.watch(modelCatalogProvider);
    final known = catalog.value;
    final query = _query.text.trim().toLowerCase();
    final found = known == null
        ? const <ModelInfo>[]
        : [
            for (final m in known.models)
              if (query.isNotEmpty &&
                  (m.id.toLowerCase().contains(query) ||
                      m.name.toLowerCase().contains(query)))
                m,
          ].take(30).toList();
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHeader(title: 'Модель'),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (favorites.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.s6,
                        vertical: AppSpacing.s2,
                      ),
                      child: Text(
                        'Быстрый выбор пуст. Найдите модель в каталоге ниже '
                        'или добавьте избранные в настройках.',
                        key: const Key('model-empty'),
                        style: t.bodyS.copyWith(color: c.textSecondary),
                      ),
                    ),
                  for (final f in favorites)
                    PickerRow(
                      key: Key('model-fav-${f.modelId}'),
                      title: f.displayName,
                      subtitle: _availability(known, f),
                      selected: f.modelId == widget.currentModel,
                      leading: LucideIcons.cloud,
                      onTap: () => Navigator.of(context).pop(
                        ModelChoice(
                          id: f.modelId,
                          name: f.displayName,
                          supportsTools: f.supportsTools,
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.s6,
                      AppSpacing.s3,
                      AppSpacing.s6,
                      AppSpacing.s2,
                    ),
                    child: FormTextField(
                      key: const Key('model-search'),
                      controller: _query,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        hintText: 'Поиск по каталогу моделей',
                        prefixIcon: Icon(LucideIcons.search, size: 18),
                      ),
                    ),
                  ),
                  if (catalog.isLoading)
                    const Padding(
                      padding: EdgeInsets.all(AppSpacing.s4),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  if (catalog.hasError)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.s6,
                        vertical: AppSpacing.s2,
                      ),
                      child: Text(
                        'Каталог недоступен: нет связи с сервером.',
                        key: const Key('catalog-error'),
                        style: t.bodyS.copyWith(color: c.textSecondary),
                      ),
                    ),
                  for (final m in found)
                    PickerRow(
                      key: Key('model-cat-${m.id}'),
                      title: m.name,
                      subtitle: m.id,
                      selected: m.id == widget.currentModel,
                      leading: LucideIcons.cloud,
                      onTap: () => Navigator.of(context).pop(
                        ModelChoice(
                          id: m.id,
                          name: m.name,
                          supportsTools: m.supportsTools,
                        ),
                      ),
                    ),
                  TextButton(
                    key: const Key('model-manage'),
                    onPressed: () {
                      final router = GoRouter.of(context);
                      Navigator.of(context).pop();
                      router.go('/ai/settings/models');
                    },
                    child: const Text('Управлять моделями →'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String? _availability(ModelCatalog? catalog, ModelFavorite f) {
    if (catalog == null) return f.modelId;
    return catalog.byId(f.modelId) == null
        ? 'Недоступна в каталоге'
        : f.modelId;
  }
}

// ---- агент --------------------------------------------------------------

Future<AgentProfile?> showAgentPicker(
  BuildContext context, {
  required String? currentAgentId,
}) => showEditorSheet<AgentProfile>(
  context,
  builder: (_) => AgentPickerSheet(currentAgentId: currentAgentId),
);

class AgentPickerSheet extends ConsumerWidget {
  const AgentPickerSheet({required this.currentAgentId, super.key});

  final String? currentAgentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agents = ref.watch(agentsProvider).value ?? const [];
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHeader(title: 'Агент'),
          if (agents.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.s6),
              child: Text(
                'Агенты загрузятся с сервера при первой синхронизации.',
                key: const Key('agents-empty'),
                style: context.text.bodyS.copyWith(
                  color: context.colors.textSecondary,
                ),
              ),
            ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (final a in agents)
                    PickerRow(
                      key: Key('agent-${a.id}'),
                      title: a.name,
                      subtitle: a.topic.hint,
                      leading: a.topic.icon,
                      selected: a.id == currentAgentId,
                      onTap: () => Navigator.of(context).pop(a),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- контекст -------------------------------------------------------------

/// Сборка контекста для показа (оценка токенов и превью): обновляется при
/// смене выбора и данных задач и календаря.
///
/// Чувствительные источники (финансы) собираются только при открытом замке
/// раздела «Финансы»: иначе превью показало бы суммы в обход PIN, и вместо
/// текста возвращается [ContextPackage.withheld]. Режим «скрыть суммы»
/// действует и на превью (маска вместо сумм).
// Тип семейства Riverpod 3 недоступен из публичного API.
// ignore: specify_nonobvious_property_types
final contextPreviewProvider = FutureProvider.autoDispose
    .family<ContextPackage, String>((ref, conversationId) {
      final selection = ref.watch(chatContextProvider(conversationId));
      ref
        ..watch(tasksProvider)
        ..watch(eventsProvider);
      final builder = ref.read(contextBuilderProvider);
      var env = ref.read(contextEnvProvider)();
      if (builder.isSensitive(selection.sources)) {
        final lock = ref.watch(financeLockProvider);
        if (!lock.loaded || lock.locked) return const ContextPackage.withheld();
        env = env.copyWith(hideAmounts: ref.watch(hideAmountsProvider));
      }
      return builder.build(selection.sources, env);
    });

/// «Что знает ассистент в этом чате» (02, 5.2.3).
Future<void> showContextSheet(
  BuildContext context, {
  required String conversationId,
}) => showEditorSheet<void>(
  context,
  builder: (_) => ContextSheet(conversationId: conversationId),
);

class ContextSheet extends ConsumerWidget {
  const ContextSheet({required this.conversationId, super.key});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final sources = ref.watch(contextSourcesProvider);
    final selection = ref.watch(chatContextProvider(conversationId));
    final presets = ref.watch(presetsProvider).value ?? const [];
    final package = ref.watch(contextPreviewProvider(conversationId));
    final notifier = ref.read(chatContextProvider(conversationId).notifier);
    final tokens = package.value?.tokens ?? 0;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SheetHeader(
            title: 'Контекст чата',
            trailing: Text(
              formatTokens(tokens),
              key: const Key('context-tokens'),
              style: t.bodyS.copyWith(color: c.textSecondary),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (presets.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: AppSpacing.s6),
                      child: FieldLabel('Пресеты'),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.s6,
                      ),
                      child: Wrap(
                        spacing: AppSpacing.s2,
                        runSpacing: AppSpacing.s2,
                        children: [
                          for (final p in presets)
                            FilterPill(
                              key: Key('context-preset-${p.id}'),
                              label: p.sensitive
                                  ? '${p.name} · локально'
                                  : p.name,
                              selected: selection.presetId == p.id,
                              icon: p.sensitive ? LucideIcons.lock : null,
                              onTap: p.sensitive
                                  ? () => _sensitiveNotice(context)
                                  : () => notifier.applyPreset(p),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s3),
                  ],
                  for (final source in sources)
                    ContextSourceTile(
                      source: source,
                      ref: selection.of(source.id),
                      onToggle: () => notifier.toggle(
                        source.id,
                        ContextSourceRef(
                          source: source.id,
                          filter: source.defaultFilter,
                        ),
                      ),
                      onFilter: (filter) =>
                          notifier.setFilter(source.id, filter),
                    ),
                  if (package.hasError)
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.s6),
                      child: Text(
                        'Не удалось собрать контекст.',
                        style: t.bodyS.copyWith(color: c.textSecondary),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s4),
            child: Row(
              children: [
                TextButton(
                  key: const Key('context-clear'),
                  onPressed: selection.isEmpty ? null : notifier.clear,
                  child: const Text('Очистить'),
                ),
                const Spacer(),
                TextButton(
                  key: const Key('context-save-preset'),
                  onPressed: selection.isEmpty
                      ? null
                      : () => _savePreset(context, ref, selection),
                  child: const Text('Сохранить пресет'),
                ),
                const SizedBox(width: AppSpacing.s2),
                ElevatedButton(
                  key: const Key('context-preview'),
                  onPressed: package.hasValue
                      ? () => showContextPreview(
                          context,
                          conversationId: conversationId,
                        )
                      : null,
                  child: const Text('Превью'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _sensitiveNotice(BuildContext context) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text(
            'Этот пресет помечен «не отправлять в облако»: он для локальной '
            'модели.',
          ),
        ),
      );
  }

  Future<void> _savePreset(
    BuildContext context,
    WidgetRef ref,
    ChatContextSelection selection,
  ) async {
    final repo = ref.read(aiRepositoryProvider);
    final notifier = ref.read(chatContextProvider(conversationId).notifier);
    final result = await showDialog<({String name, bool sensitive})>(
      context: context,
      builder: (_) => const _PresetNameDialog(),
    );
    if (result == null) return;
    final id = await repo.createPreset(
      result.name,
      selection.sources,
      sensitive: result.sensitive,
    );
    final saved = await repo.getPreset(id);
    if (saved != null && !saved.sensitive) notifier.applyPreset(saved);
  }
}

/// Источник контекста с переключателем и параметрами фильтра.
class ContextSourceTile extends StatelessWidget {
  const ContextSourceTile({
    required this.source,
    required this.ref,
    required this.onToggle,
    required this.onFilter,
    super.key,
  });

  final ContextSource source;
  final ContextSourceRef? ref;
  final VoidCallback onToggle;
  final ValueChanged<Map<String, Object?>> onFilter;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final on = ref != null;
    final filter = {...source.defaultFilter, ...?ref?.filter};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: Key('context-source-${source.id}'),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s6,
              vertical: AppSpacing.s3,
            ),
            child: Row(
              children: [
                Icon(
                  on ? LucideIcons.squareCheck : LucideIcons.square,
                  size: 20,
                  color: on ? c.textPrimary : c.textTertiary,
                ),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(source.label, style: t.body),
                      Text(
                        source.sensitive
                            ? '${source.description} · только локально'
                            : source.description,
                        style: t.bodyS.copyWith(color: c.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (on)
          for (final field in source.filters)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.s6 + 32,
                0,
                AppSpacing.s6,
                AppSpacing.s2,
              ),
              child: Wrap(
                spacing: AppSpacing.s2,
                runSpacing: AppSpacing.s2,
                children: [
                  for (final option in field.options.entries)
                    FilterPill(
                      key: Key('context-filter-${source.id}-${option.key}'),
                      label: option.value,
                      selected: '${filter[field.key]}' == option.key,
                      onTap: () => onFilter({...filter, field.key: option.key}),
                    ),
                ],
              ),
            ),
      ],
    );
  }
}

class _PresetNameDialog extends StatefulWidget {
  const _PresetNameDialog();

  @override
  State<_PresetNameDialog> createState() => _PresetNameDialogState();
}

class _PresetNameDialogState extends State<_PresetNameDialog> {
  final TextEditingController _name = TextEditingController();
  bool _sensitive = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Сохранить пресет', style: context.text.h3),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FormTextField(
            key: const Key('preset-name'),
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Название'),
          ),
          SwitchListTile(
            key: const Key('preset-sensitive'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Не отправлять в облако'),
            value: _sensitive,
            onChanged: (v) => setState(() => _sensitive = v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        ElevatedButton(
          key: const Key('preset-save'),
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            Navigator.of(context).pop((name: name, sensitive: _sensitive));
          },
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

/// Превью контекста: текст, который уйдёт в запрос (`context.text`). Для
/// чувствительного контекста (финансы) он не уходит в облако, а используется
/// только локальной моделью, и показывается только при открытом разделе.
Future<void> showContextPreview(
  BuildContext context, {
  required String conversationId,
}) => showEditorSheet<void>(
  context,
  builder: (_) => ContextPreviewSheet(conversationId: conversationId),
);

class ContextPreviewSheet extends ConsumerWidget {
  const ContextPreviewSheet({required this.conversationId, super.key});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final package =
        ref.watch(contextPreviewProvider(conversationId)).value ??
        ContextPackage.empty;
    final hidden = ref.watch(hideAmountsProvider);
    final local = package.containsSensitive;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SheetHeader(
            title: local ? 'Для локальной модели' : 'Что уйдёт в облако',
            trailing: Text(
              formatTokens(package.tokens),
              style: t.bodyS.copyWith(color: c.textSecondary),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.s6,
                0,
                AppSpacing.s6,
                AppSpacing.s6,
              ),
              child: package.withheld
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Раздел «Финансы» закрыт. Откройте его, чтобы '
                          'увидеть контекст: он содержит суммы.',
                          key: const Key('preview-withheld'),
                          style: t.body.copyWith(color: c.textSecondary),
                        ),
                        const SizedBox(height: AppSpacing.s3),
                        FilledButton(
                          key: const Key('preview-unlock'),
                          onPressed: () =>
                              unawaited(ensureFinanceUnlocked(context, ref)),
                          child: const Text('Открыть раздел'),
                        ),
                      ],
                    )
                  : package.text.isEmpty
                  ? Text(
                      'Контекст не выбран: в запрос уйдёт только переписка.',
                      key: const Key('preview-empty'),
                      style: t.body.copyWith(color: c.textSecondary),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (local && hidden)
                          Padding(
                            padding: const EdgeInsets.only(
                              bottom: AppSpacing.s2,
                            ),
                            child: Text(
                              'Суммы скрыты режимом «скрыть суммы» только в '
                              'этом окне: локальная модель получит их '
                              'полностью.',
                              key: const Key('preview-masked-note'),
                              style: t.caption.copyWith(color: c.textSecondary),
                            ),
                          ),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(AppSpacing.s3),
                          decoration: BoxDecoration(
                            color: c.surface3,
                            borderRadius: AppRadii.borderS,
                          ),
                          child: SelectableText(
                            package.text,
                            key: const Key('preview-text'),
                            style: t.bodyS,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Согласие на финансовые инструменты облачного агента (spec Этапа 3, 5.1).
/// `true` — разрешено для этого чата, `false` — не разрешать, `null` — окно
/// закрыто без выбора (решение не сохраняется).
Future<bool?> showSensitiveConsentDialog(BuildContext context) =>
    showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('sensitive-consent-dialog'),
        title: Text('Данные «Финансов» в облако?', style: context.text.h3),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Text(
            'Данные из раздела «Финансы» (балансы, долги, цели) будут '
            'отправлены в polza.ai. Без разрешения агент ответит без цифр.',
            style: context.text.body.copyWith(
              color: context.colors.textSecondary,
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('consent-deny'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Не разрешать'),
          ),
          FilledButton(
            key: const Key('consent-allow'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Разрешить для этого чата'),
          ),
        ],
      ),
    );
