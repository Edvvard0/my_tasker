import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/ai_chat/application/ai_providers.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/data/context_sources.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/presentation/chat_sheets.dart';
import 'package:my_tasker/features/ai_chat/presentation/settings/ai_settings_screen.dart';

/// «Пресеты контекста»: список, создание, правка, удаление в корзину.
class PresetsScreen extends ConsumerWidget {
  const PresetsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presets = ref.watch(presetsProvider);
    final sources = ref.watch(contextSourcesProvider);
    final c = context.colors;
    String summary(ContextPreset p) => p.sources.isEmpty
        ? 'Без источников'
        : p.sources
              .map(
                (s) =>
                    sources.where((x) => x.id == s.source).firstOrNull?.label ??
                    s.source,
              )
              .join(', ');
    return ScreenScaffold(
      title: 'Пресеты контекста',
      parentLabel: 'Настройки ИИ',
      onBack: () => context.go('/ai/settings'),
      actions: [
        IconButton(
          key: const Key('preset-add'),
          tooltip: 'Новый пресет',
          onPressed: () => showPresetEditor(context),
          icon: const Icon(LucideIcons.plus, size: 22),
        ),
      ],
      child: presets.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const EmptyState(
          icon: LucideIcons.circleAlert,
          title: 'Не удалось прочитать пресеты',
          message: 'Попробуйте открыть экран ещё раз.',
        ),
        data: (list) => list.isEmpty
            ? EmptyState(
                icon: LucideIcons.layers,
                title: 'Пресетов пока нет',
                message:
                    'Пресет — набор данных (задачи, расписание), который '
                    'подключается к чату одним нажатием.',
                action: ElevatedButton(
                  key: const Key('preset-empty-add'),
                  onPressed: () => showPresetEditor(context),
                  child: const Text('Создать пресет'),
                ),
              )
            : Container(
                decoration: BoxDecoration(
                  color: c.surface1,
                  borderRadius: AppRadii.borderL,
                ),
                child: Column(
                  children: [
                    for (final p in list)
                      AiSettingsTile(
                        key: Key('preset-${p.id}'),
                        icon: p.sensitive
                            ? LucideIcons.lock
                            : LucideIcons.layers,
                        title: p.sensitive ? '${p.name} · не в облако' : p.name,
                        subtitle: summary(p),
                        onTap: () => showPresetEditor(context, preset: p),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

Future<void> showPresetEditor(BuildContext context, {ContextPreset? preset}) =>
    showEditorSheet<void>(
      context,
      builder: (_) => PresetEditor(preset: preset),
    );

/// Форма пресета: название, пометка «не отправлять в облако», источники.
class PresetEditor extends ConsumerStatefulWidget {
  const PresetEditor({this.preset, super.key});

  final ContextPreset? preset;

  @override
  ConsumerState<PresetEditor> createState() => _PresetEditorState();
}

class _PresetEditorState extends ConsumerState<PresetEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.preset?.name ?? '',
  );
  late bool _sensitive = widget.preset?.sensitive ?? false;
  late List<ContextSourceRef> _sources = [...?widget.preset?.sources];
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  ContextSourceRef? _of(String id) =>
      _sources.where((s) => s.source == id).firstOrNull;

  Future<void> _save() async {
    final repo = ref.read(aiRepositoryProvider);
    try {
      if (widget.preset == null) {
        await repo.createPreset(_name.text, _sources, sensitive: _sensitive);
      } else {
        await repo.updatePreset(
          widget.preset!.id,
          _name.text,
          _sources,
          sensitive: _sensitive,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } on AiValidationError catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _delete() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Удалить пресет?',
      message: '«${widget.preset!.name}» уйдёт в корзину на 30 дней.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok || !mounted) return;
    await ref.read(aiRepositoryProvider).deletePreset(widget.preset!.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final sources = ref.watch(contextSourcesProvider);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SheetHeader(title: widget.preset == null ? 'Новый пресет' : 'Пресет'),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.s6,
                    ),
                    child: FormBlock(
                      label: 'Название',
                      child: FormTextField(
                        key: const Key('preset-field-name'),
                        controller: _name,
                        decoration: const InputDecoration(),
                      ),
                    ),
                  ),
                  SwitchListTile(
                    key: const Key('preset-field-sensitive'),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.s6,
                    ),
                    title: const Text('Не отправлять в облако'),
                    subtitle: const Text(
                      'Только для локальной модели: в облачном чате '
                      'пресет не работает.',
                    ),
                    value: _sensitive,
                    onChanged: (v) => setState(() => _sensitive = v),
                  ),
                  for (final source in sources)
                    ContextSourceTile(
                      key: Key('preset-source-${source.id}'),
                      source: source,
                      ref: _of(source.id),
                      onToggle: () => setState(() {
                        _sources = _of(source.id) != null
                            ? [
                                for (final s in _sources)
                                  if (s.source != source.id) s,
                              ]
                            : [
                                ..._sources,
                                ContextSourceRef(
                                  source: source.id,
                                  filter: source.defaultFilter,
                                ),
                              ];
                      }),
                      onFilter: (filter) => setState(() {
                        _sources = [
                          for (final s in _sources)
                            if (s.source == source.id)
                              s.copyWith(filter: filter)
                            else
                              s,
                        ];
                      }),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.s6),
                      child: Text(
                        _error!,
                        key: const Key('preset-error'),
                        style: context.text.bodyS.copyWith(color: c.danger),
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
                if (widget.preset != null)
                  TextButton(
                    key: const Key('preset-delete'),
                    onPressed: _delete,
                    child: const Text('Удалить'),
                  ),
                const Spacer(),
                ElevatedButton(
                  key: const Key('preset-field-save'),
                  onPressed: _save,
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
