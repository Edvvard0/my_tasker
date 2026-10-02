import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/format/ru_format.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/ai_chat/application/ai_providers.dart';
import 'package:my_tasker/features/ai_chat/data/agent_reset.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/presentation/settings/ai_settings_screen.dart';

/// Редактор промта агента: правка с новой версией, история, откат,
/// «Сбросить» (для предустановленных), пресет контекста по умолчанию.
class AgentEditorScreen extends ConsumerStatefulWidget {
  const AgentEditorScreen({required this.agentId, super.key});

  final String agentId;

  @override
  ConsumerState<AgentEditorScreen> createState() => _AgentEditorScreenState();
}

class _AgentEditorScreenState extends ConsumerState<AgentEditorScreen> {
  final TextEditingController _prompt = TextEditingController();
  String? _loadedFor;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _prompt.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  void _toast(String text) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _save(AgentProfile agent) async {
    setState(() => _busy = true);
    try {
      final changed = await ref
          .read(aiRepositoryProvider)
          .editPrompt(agent.id, _prompt.text);
      _toast(
        changed
            ? 'Сохранена версия ${agent.promptVersion + 1}'
            : 'Без изменений',
      );
    } on AiValidationError catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset(AgentProfile agent) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Сбросить промт?',
      message:
          'Текст вернётся к исходному, текущий останется в истории версий.',
      confirmLabel: 'Сбросить',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await resetAgentPrompt(
        api: ref.read(aiApiProvider),
        store: ref.read(syncStoreProvider),
        seedKey: agent.seedKey!,
      );
      _loadedFor = null; // подтянуть сброшенный текст в поле
      _toast('Промт сброшен');
    } on ApiException catch (e) {
      _toast(
        e.isNetwork
            ? 'Нет сети: сброс выполняется на сервере.'
            : 'Не удалось сбросить промт.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openVersion(AgentProfile agent, PromptVersion v) async {
    final rollback = await showEditorSheet<bool>(
      context,
      builder: (_) => _VersionSheet(
        version: v,
        isCurrent: v.version == agent.promptVersion,
      ),
    );
    if (rollback != true || !mounted) return;
    try {
      await ref.read(aiRepositoryProvider).rollbackPrompt(agent.id, v.version);
      _loadedFor = null;
      _toast('Откат к версии ${v.version}: сохранена новая версия');
    } on AiValidationError catch (e) {
      _toast(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final agents = ref.watch(agentsProvider).value ?? const [];
    final agent = agents.where((a) => a.id == widget.agentId).firstOrNull;
    final c = context.colors;
    final t = context.text;
    if (agent == null) {
      return ScreenScaffold(
        title: 'Агент',
        onBack: () => context.go('/ai/settings/agents'),
        child: const EmptyState(
          icon: LucideIcons.bot,
          title: 'Агент не найден',
          message: 'Возможно, он ещё не синхронизирован.',
        ),
      );
    }
    final key = '${agent.id}:${agent.promptVersion}';
    if (_loadedFor != key) {
      _loadedFor = key;
      _prompt.text = agent.systemPrompt;
    }
    final versions =
        ref.watch(promptVersionsProvider(agent.id)).value ?? const [];
    final presets = ref.watch(presetsProvider).value ?? const [];
    final changed = _prompt.text != agent.systemPrompt;
    return ScreenScaffold(
      title: agent.name,
      parentLabel: 'Агенты',
      onBack: () => context.go('/ai/settings/agents'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Системный промт · версия ${agent.promptVersion}',
            style: t.overline.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: AppSpacing.s2),
          FormTextField(
            key: const Key('prompt-field'),
            controller: _prompt,
            minLines: 8,
            maxLines: 20,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(),
          ),
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s1),
            child: Text(
              '${_prompt.text.length} / $maxPromptLength',
              style: t.caption.copyWith(color: c.textTertiary),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          Row(
            children: [
              ElevatedButton(
                key: const Key('prompt-save'),
                onPressed: changed && !_busy ? () => _save(agent) : null,
                child: const Text('Сохранить'),
              ),
              const SizedBox(width: AppSpacing.s3),
              if (agent.isSeed)
                OutlinedButton(
                  key: const Key('prompt-reset'),
                  onPressed: _busy ? null : () => _reset(agent),
                  child: const Text('Сбросить'),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.s6),
          Text(
            'Пресет контекста по умолчанию',
            style: t.overline.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: AppSpacing.s2),
          Wrap(
            spacing: AppSpacing.s2,
            runSpacing: AppSpacing.s2,
            children: [
              FilterPill(
                key: const Key('agent-preset-none'),
                label: 'Без контекста',
                selected: agent.defaultContextPresetId == null,
                onTap: () => ref
                    .read(aiRepositoryProvider)
                    .setAgentDefaultPreset(agent.id, null),
              ),
              for (final p in presets)
                FilterPill(
                  key: Key('agent-preset-${p.id}'),
                  label: p.name,
                  selected: agent.defaultContextPresetId == p.id,
                  onTap: p.sensitive
                      ? null
                      : () => ref
                            .read(aiRepositoryProvider)
                            .setAgentDefaultPreset(agent.id, p.id),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.s6),
          Text(
            'История версий',
            style: t.overline.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: AppSpacing.s2),
          Container(
            decoration: BoxDecoration(
              color: c.surface1,
              borderRadius: AppRadii.borderL,
            ),
            child: versions.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(AppSpacing.s4),
                    child: Text(
                      'Версий пока нет.',
                      style: t.bodyS.copyWith(color: c.textSecondary),
                    ),
                  )
                : Column(
                    children: [
                      for (final v in versions)
                        AiSettingsTile(
                          key: Key('version-${v.version}'),
                          icon: LucideIcons.history,
                          title:
                              'Версия ${v.version}'
                              '${v.version == agent.promptVersion ? ' · текущая' : ''}',
                          subtitle: [
                            v.source.label,
                            if (v.createdAt != null)
                              formatMoment(v.createdAt!, DateTime.now()),
                          ].join(' · '),
                          onTap: () => _openVersion(agent, v),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _VersionSheet extends StatelessWidget {
  const _VersionSheet({required this.version, required this.isCurrent});

  final PromptVersion version;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SheetHeader(title: 'Версия ${version.version}'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.s3),
                decoration: BoxDecoration(
                  color: c.surface3,
                  borderRadius: AppRadii.borderS,
                ),
                child: SelectableText(
                  version.text,
                  key: const Key('version-text'),
                  style: context.text.bodyS,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s4),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                key: const Key('version-rollback'),
                onPressed: isCurrent
                    ? null
                    : () => Navigator.of(context).pop(true),
                child: const Text('Откатить к этой версии'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
