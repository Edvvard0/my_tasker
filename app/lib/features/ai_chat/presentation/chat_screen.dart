import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/sync/ids.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_text_field.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/features/ai_chat/application/ai_providers.dart';
import 'package:my_tasker/features/ai_chat/application/chat_context.dart';
import 'package:my_tasker/features/ai_chat/application/chat_session.dart';
import 'package:my_tasker/features/ai_chat/application/sensitive_consent.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_errors.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_format.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/sensitive_tools.dart';
import 'package:my_tasker/features/ai_chat/presentation/chat_sheets.dart';
import 'package:my_tasker/features/ai_chat/presentation/message_widgets.dart';
import 'package:my_tasker/features/finance/presentation/finance_gate.dart';

/// Подсказки-примеры для пустого чата по теме (02, 5.2.2).
const Map<AiTopic, List<String>> topicSuggestions = {
  AiTopic.general: [
    'Помоги спланировать неделю',
    'Объясни простыми словами, как работает инфляция',
    'Придумай идеи для подарка',
  ],
  AiTopic.calendarTasks: [
    'Какие у меня задачи на этой неделе?',
    'Что у меня в расписании завтра?',
    'Создай задачу: оплатить домен до пятницы',
  ],
  AiTopic.work: [
    'Помоги оценить сроки доработки',
    'Составь план созвона с клиентом',
    'Сформулируй письмо заказчику',
  ],
  AiTopic.finance: [
    'Как распределить бюджет на месяц?',
    'Составь список регулярных трат',
    'Как копить на цель?',
  ],
  AiTopic.study: [
    'Объясни тему простыми словами',
    'Составь план подготовки к экзамену',
    'Проверь мой конспект',
  ],
  AiTopic.sleep: [
    'Как наладить режим сна?',
    'Составь вечерний ритуал',
    'Почему я просыпаюсь ночью?',
  ],
};

/// Экран чата (02, 5.2.3–5.2.6): шапка с моделью, агентом и контекстом,
/// лента со стримингом, карточки предложений, поле ввода с «Остановить».
///
/// [conversationId] = `null` — новый чат: строка создаётся при первой
/// отправке (пока это черновик в памяти).
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({this.conversationId, super.key});

  final String? conversationId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  late final String _id = widget.conversationId ?? uuid7();
  late Conversation _draft = Conversation(
    id: _id,
    title: '',
    topic: AiTopic.general,
  );
  bool _modelChosen = false;
  bool _agentChosen = false;
  final TextEditingController _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    _input.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  AgentProfile? _agentFor(AiTopic topic, List<AgentProfile> agents) {
    for (final a in agents) {
      if (a.topic == topic) return a;
    }
    return null;
  }

  /// Чат с учётом умолчаний: модель — первая избранная, агент — по теме.
  Conversation _effective(
    Conversation? row,
    List<ModelFavorite> favorites,
    List<AgentProfile> agents,
  ) {
    if (row != null) return row;
    var draft = _draft;
    if (!_modelChosen && draft.model == null && favorites.isNotEmpty) {
      draft = draft.copyWith(model: favorites.first.modelId);
    }
    if (!_agentChosen && draft.agentId == null) {
      final agent = _agentFor(draft.topic, agents);
      if (agent != null) draft = draft.copyWith(agentId: agent.id);
    }
    return draft;
  }

  Future<void> _pickModel(Conversation conv, {required bool persisted}) async {
    final choice = await showModelPicker(context, currentModel: conv.model);
    if (choice == null || !mounted) return;
    if (persisted) {
      await ref.read(aiRepositoryProvider).setModel(_id, choice.id);
    } else {
      setState(() {
        _modelChosen = true;
        _draft = _draft.copyWith(model: choice.id);
      });
    }
  }

  Future<void> _pickAgent(Conversation conv, {required bool persisted}) async {
    final agent = await showAgentPicker(context, currentAgentId: conv.agentId);
    if (agent == null || !mounted) return;
    await _selectAgent(agent, persisted: persisted);
  }

  Future<void> _selectAgent(
    AgentProfile agent, {
    required bool persisted,
  }) async {
    if (persisted) {
      await ref
          .read(aiRepositoryProvider)
          .setAgent(_id, agentId: agent.id, topic: agent.topic);
    } else {
      setState(() {
        _agentChosen = true;
        _draft = _draft.copyWith(agentId: agent.id, topic: agent.topic);
      });
    }
    final presetId = agent.defaultContextPresetId;
    if (presetId != null) {
      final preset = await ref.read(aiRepositoryProvider).getPreset(presetId);
      if (mounted && preset != null && !preset.sensitive) {
        ref.read(chatContextProvider(_id).notifier).seed(preset);
      }
    }
  }

  Future<void> _send(Conversation conv, {required bool persisted}) async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    if (conv.model == null) {
      await _pickModel(conv, persisted: persisted);
      return;
    }
    final consent = await _sensitiveConsent(conv);
    if (!mounted) return;
    _input.clear();
    final accepted = await ref
        .read(chatSessionProvider(_id).notifier)
        .send(text, conversation: conv, sensitiveToolsConsent: consent);
    if (!accepted && mounted && _input.text.isEmpty) _input.text = text;
  }

  Future<void> _retry(Conversation conv) async {
    final consent = await _sensitiveConsent(conv);
    if (!mounted) return;
    await ref
        .read(chatSessionProvider(_id).notifier)
        .retry(conversation: conv, sensitiveToolsConsent: consent);
  }

  /// Нужно ли отправить с запросом согласие на финансовые инструменты
  /// агента. Только для агентов с такими инструментами. Если раздел
  /// «Финансы» закрыт PIN, сначала разблокировка (отказ от неё — ответ без
  /// цифр, решение не сохраняется). Первый раз спрашивает диалогом;
  /// решение хранится на уровне беседы. «Не разрешать» — поле не уходит.
  Future<bool> _sensitiveConsent(Conversation conv) async {
    final agents = ref.read(agentsProvider).value ?? const [];
    final agent = agents.where((a) => a.id == conv.agentId).firstOrNull;
    if (!agentUsesSensitiveTools(agent)) return false;
    final store = ref.read(sensitiveToolsConsentProvider);
    final decision = await store.read(_id);
    if (decision == false || !mounted) return false;
    final unlocked = await ensureFinanceUnlocked(
      context,
      ref,
      hint: 'Чтобы агент ответил с цифрами из «Финансов», откройте раздел.',
    );
    if (!unlocked || !mounted) return false;
    if (decision != null) return true;
    final allowed = await showSensitiveConsentDialog(context);
    if (allowed == null || !mounted) return false;
    await store.write(_id, allowed: allowed);
    return allowed;
  }

  Future<void> _menu(Conversation conv) async {
    final repo = ref.read(aiRepositoryProvider);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PickerRow(
              key: const Key('chat-menu-rename'),
              title: 'Переименовать',
              leading: LucideIcons.pencil,
              onTap: () => Navigator.of(context).pop('rename'),
            ),
            PickerRow(
              key: const Key('chat-menu-pin'),
              title: conv.pinned ? 'Открепить' : 'Закрепить',
              leading: LucideIcons.pin,
              onTap: () => Navigator.of(context).pop('pin'),
            ),
            PickerRow(
              key: const Key('chat-menu-archive'),
              title: conv.archived ? 'Вернуть из архива' : 'В архив',
              leading: LucideIcons.archive,
              onTap: () => Navigator.of(context).pop('archive'),
            ),
            PickerRow(
              key: const Key('chat-menu-delete'),
              title: 'Удалить',
              leading: LucideIcons.trash2,
              onTap: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'rename':
        final title = await showRenameDialog(context, conv.title);
        if (title != null) await repo.rename(_id, title);
      case 'pin':
        await repo.setPinned(_id, pinned: !conv.pinned);
      case 'archive':
        await repo.setArchived(_id, archived: !conv.archived);
      case 'delete':
        final ok = await showConfirmDialog(
          context,
          title: 'Удалить чат?',
          message: 'Чат уйдёт в корзину на 30 дней.',
          confirmLabel: 'Удалить',
          danger: true,
        );
        if (!ok || !mounted) return;
        await repo.deleteConversation(_id);
        if (mounted) _close();
    }
  }

  void _close() => context.canPop() ? context.pop() : context.go('/ai');

  @override
  Widget build(BuildContext context) {
    final row = ref.watch(conversationProvider(_id)).value;
    final favorites = ref.watch(favoritesProvider).value ?? const [];
    final agents = ref.watch(agentsProvider).value ?? const [];
    final conv = _effective(row, favorites, agents);
    final persisted = row != null;
    final messages = ref.watch(messagesProvider(_id)).value ?? const [];
    final proposals = ref.watch(proposalsProvider(_id)).value ?? const {};
    final session = ref.watch(chatSessionProvider(_id));
    final online = ref.watch(syncStatusProvider.select((s) => s.online));
    final usage = ref.watch(usageProvider(null)).value;
    final preview = ref.watch(contextPreviewProvider(_id)).value;
    final selection = ref.watch(chatContextProvider(_id));
    final c = context.colors;
    final t = context.text;
    final windowClass = context.windowClass;
    final liveVisible =
        session.hasLive &&
        !messages.any((m) => m.id == session.assistantMessageId);
    final showTopics = !persisted && messages.isEmpty && !liveVisible;
    final agent = agents.where((a) => a.id == conv.agentId).firstOrNull;

    final items = <Widget>[
      for (var i = 0; i < messages.length; i++)
        _messageView(
          messages[i],
          proposals,
          isLast: i == messages.length - 1 && !liveVisible,
          conv: conv,
        ),
      if (liveVisible) _liveView(session, conv),
    ];

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Column(
              children: [
                _Header(
                  title: conv.title.isEmpty ? 'Новый чат' : conv.title,
                  topic: conv.topic,
                  gutter: windowClass.gutter,
                  onBack: _close,
                  onMenu: persisted ? () => _menu(conv) : null,
                  pills: [
                    _Pill(
                      key: const Key('chat-model-pill'),
                      icon: online ? LucideIcons.cloud : LucideIcons.cloudOff,
                      label: online
                          ? shortModelName(conv.model, favorites)
                          : 'Нет сети',
                      muted: !online,
                      onTap: () => _pickModel(conv, persisted: persisted),
                    ),
                    _Pill(
                      key: const Key('chat-agent-pill'),
                      icon: conv.topic.icon,
                      label: agent?.name ?? conv.topic.label,
                      onTap: () => _pickAgent(conv, persisted: persisted),
                    ),
                    _Pill(
                      key: const Key('chat-context-pill'),
                      icon: LucideIcons.layers,
                      label: 'Контекст: ${selection.sources.length}',
                      onTap: () =>
                          showContextSheet(context, conversationId: _id),
                    ),
                  ],
                ),
                Expanded(
                  child: items.isEmpty
                      ? _EmptyChat(
                          topic: conv.topic,
                          showTopics: showTopics,
                          gutter: windowClass.gutter,
                          onTopic: (topic) {
                            final agent = _agentFor(topic, agents);
                            setState(() {
                              _draft = _draft.copyWith(topic: topic);
                              _agentChosen = false;
                            });
                            if (agent != null) {
                              unawaited(_selectAgent(agent, persisted: false));
                            }
                          },
                          onSuggestion: (text) => _input.text = text,
                        )
                      : ListView(
                          key: const Key('chat-list'),
                          reverse: true,
                          padding: EdgeInsets.symmetric(
                            horizontal: windowClass.gutter,
                            vertical: AppSpacing.s3,
                          ),
                          children: [
                            for (final w in items.reversed) ...[
                              w,
                              const SizedBox(height: AppSpacing.s4),
                            ],
                          ],
                        ),
                ),
                if (usage != null && usage.nearLimit)
                  _Notice(
                    key: const Key('usage-warning'),
                    text: usage.exceeded
                        ? 'Месячный лимит исчерпан: '
                              '${formatCost(usage.spentKopecks)} из '
                              '${formatCost(usage.limitKopecks!)}.'
                        : 'Расход приближается к лимиту: '
                              '${formatCost(usage.spentKopecks)} из '
                              '${formatCost(usage.limitKopecks!)}.',
                    critical: usage.exceeded,
                    gutter: windowClass.gutter,
                  ),
                if (session.failure != null && !session.hasLive)
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: windowClass.gutter,
                      vertical: AppSpacing.s2,
                    ),
                    child: FailureLine(
                      failure: session.failure!,
                      onRetry: messages.isEmpty ? null : () => _retry(conv),
                    ),
                  ),
                if (preview != null && (preview.tokens > 0 || preview.withheld))
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: windowClass.gutter,
                    ),
                    child: InkWell(
                      key: const Key('context-caption'),
                      onTap: () =>
                          showContextPreview(context, conversationId: _id),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.s1,
                        ),
                        child: Text(
                          preview.withheld
                              ? 'Контекст «Финансы» скрыт: раздел закрыт · '
                                    'Открыть'
                              : preview.containsSensitive
                              ? 'Локальной модели уйдёт контекст '
                                    '${formatTokens(preview.tokens)}'
                                    ' · Посмотреть'
                              : 'В запрос уйдёт контекст '
                                    '${formatTokens(preview.tokens)}'
                                    ' · Посмотреть',
                          style: t.caption.copyWith(color: c.textSecondary),
                        ),
                      ),
                    ),
                  ),
                _Composer(
                  controller: _input,
                  busy: session.busy,
                  gutter: windowClass.gutter,
                  onSend: () => _send(conv, persisted: persisted),
                  onStop: () =>
                      ref.read(chatSessionProvider(_id).notifier).cancel(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _messageView(
    ChatMessage m,
    Map<String, ToolProposal> proposals, {
    required bool isLast,
    required Conversation conv,
  }) {
    if (m.isUser) return UserBubble(key: ValueKey(m.id), text: m.text);
    if (m.role != MessageRole.assistant) return const SizedBox.shrink();
    final calls = m.parts.whereType<ToolCallPart>();
    final results = {
      for (final r in m.parts.whereType<ToolResultPart>()) r.toolCallId: r,
    };
    final failure = m.status == MessageStatus.error
        ? ChatFailure.forCode(m.errorCode ?? 'internal_error')
        : null;
    return AssistantMessageView(
      key: ValueKey(m.id),
      text: m.text,
      steps: [
        for (final call in calls)
          if (call.name != 'create_task')
            ToolStepRow(
              name: call.name,
              isError: results[call.id]?.isError ?? false,
            ),
      ],
      proposals: [
        for (final p in m.parts.whereType<ProposalPart>())
          ?proposals[p.proposalId],
      ],
      statusLabel: m.status == MessageStatus.cancelled ? 'Остановлено' : null,
      failure: failure,
      onRetry: isLast && failure != null ? () => _retry(conv) : null,
      meta: messageMeta(m).isEmpty ? null : messageMeta(m),
      copyable: m.text.isNotEmpty && m.status != MessageStatus.error,
    );
  }

  Widget _liveView(ChatSessionState s, Conversation conv) {
    final streaming = s.phase == StreamPhase.streaming;
    return AssistantMessageView(
      key: const Key('live-message'),
      text: s.text,
      streaming: streaming,
      thinking: s.busy,
      steps: [
        for (final step in s.steps)
          if (step.name != 'create_task')
            ToolStepRow(
              name: step.name,
              running: step.running,
              isError: step.isError,
            ),
        if (s.proposalCount > 0) const ToolStepRow(name: 'create_task'),
      ],
      statusLabel: s.phase == StreamPhase.cancelled ? 'Остановлено' : null,
      failure: s.failure,
      onRetry: () => _retry(conv),
      meta: liveMeta(s).isEmpty ? null : liveMeta(s),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.topic,
    required this.gutter,
    required this.onBack,
    required this.pills,
    this.onMenu,
  });

  final String title;
  final AiTopic topic;
  final double gutter;
  final VoidCallback onBack;
  final VoidCallback? onMenu;
  final List<Widget> pills;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter - 8, AppSpacing.s2, gutter - 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                key: const Key('chat-back'),
                tooltip: 'Назад',
                onPressed: onBack,
                icon: const Icon(LucideIcons.arrowLeft, size: 24),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      key: const Key('chat-title'),
                      style: t.h2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      topic.label,
                      style: t.caption.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
              if (onMenu != null)
                IconButton(
                  key: const Key('chat-menu'),
                  tooltip: 'Действия с чатом',
                  onPressed: onMenu,
                  icon: const Icon(LucideIcons.ellipsis, size: 22),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              8,
              AppSpacing.s2,
              8,
              AppSpacing.s2,
            ),
            child: Wrap(
              spacing: AppSpacing.s2,
              runSpacing: AppSpacing.s2,
              children: pills,
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.icon,
    required this.label,
    required this.onTap,
    this.muted = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = muted ? c.textSecondary : c.textPrimary;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadii.borderFull,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s3),
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: AppRadii.borderFull,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.bodyS.copyWith(color: color),
              ),
            ),
            const SizedBox(width: 4),
            Icon(LucideIcons.chevronDown, size: 14, color: c.textTertiary),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.text,
    required this.critical,
    required this.gutter,
    super.key,
  });

  final String text;
  final bool critical;
  final double gutter;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: gutter,
        vertical: AppSpacing.s1,
      ),
      child: Row(
        children: [
          Icon(
            LucideIcons.circleAlert,
            size: 16,
            color: critical ? c.danger : c.textSecondary,
          ),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text(
              text,
              style: context.text.bodyS.copyWith(
                color: critical ? c.danger : c.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({
    required this.topic,
    required this.showTopics,
    required this.gutter,
    required this.onTopic,
    required this.onSuggestion,
  });

  final AiTopic topic;
  final bool showTopics;
  final double gutter;
  final ValueChanged<AiTopic> onTopic;
  final ValueChanged<String> onSuggestion;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final suggestions = topicSuggestions[topic] ?? const [];
    return SingleChildScrollView(
      key: const Key('chat-empty'),
      padding: EdgeInsets.symmetric(
        horizontal: gutter,
        vertical: AppSpacing.s4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('О чём поговорим?', style: t.h1),
          const SizedBox(height: AppSpacing.s4),
          if (showTopics)
            LayoutBuilder(
              builder: (context, box) {
                final columns = box.maxWidth > 560 ? 3 : 2;
                final width =
                    (box.maxWidth - (columns - 1) * AppSpacing.s3) / columns;
                return Wrap(
                  spacing: AppSpacing.s3,
                  runSpacing: AppSpacing.s3,
                  children: [
                    for (final tp in AiTopic.selectable)
                      SizedBox(
                        width: width,
                        child: InkWell(
                          key: Key('topic-${tp.wire}'),
                          borderRadius: AppRadii.borderM,
                          onTap: () => onTopic(tp),
                          child: Container(
                            padding: const EdgeInsets.all(AppSpacing.s3),
                            decoration: BoxDecoration(
                              color: c.surface1,
                              borderRadius: AppRadii.borderM,
                              border: Border.all(
                                color: tp == topic
                                    ? c.textPrimary
                                    : c.borderDefault,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(tp.icon, size: 20, color: c.textSecondary),
                                const SizedBox(height: AppSpacing.s2),
                                Text(tp.label, style: t.bodyStrong),
                                Text(
                                  tp.hint,
                                  style: t.bodyS.copyWith(
                                    color: c.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          const SizedBox(height: AppSpacing.s4),
          for (final s in suggestions)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s2),
              child: InkWell(
                key: Key('suggestion-${suggestions.indexOf(s)}'),
                borderRadius: AppRadii.borderFull,
                onTap: () => onSuggestion(s),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s4,
                    vertical: AppSpacing.s2,
                  ),
                  decoration: BoxDecoration(
                    color: c.surface3,
                    borderRadius: AppRadii.borderFull,
                  ),
                  child: Text(s, style: t.bodyS),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.busy,
    required this.gutter,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool busy;
  final double gutter;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final canSend = controller.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        gutter - 4,
        AppSpacing.s2,
        gutter,
        AppSpacing.s3,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: AppTextField(
              key: const Key('chat-input'),
              controller: controller,
              minLines: 1,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(hintText: 'Сообщение'),
            ),
          ),
          const SizedBox(width: AppSpacing.s2),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: busy
                ? Tooltip(
                    message: 'Остановить',
                    child: InkResponse(
                      key: const Key('chat-stop'),
                      onTap: onStop,
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: c.surface4,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          LucideIcons.square,
                          size: 16,
                          color: c.textPrimary,
                        ),
                      ),
                    ),
                  )
                : Tooltip(
                    message: 'Отправить',
                    child: InkResponse(
                      key: const Key('chat-send'),
                      onTap: canSend ? onSend : null,
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: canSend ? c.surfaceInverse : c.surface3,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          LucideIcons.arrowUp,
                          size: 20,
                          color: canSend ? c.textOnInverse : c.textDisabled,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Диалог переименования чата; `null` — отмена.
Future<String?> showRenameDialog(BuildContext context, String current) =>
    showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(current: current),
    );

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.current});

  final String current;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.current,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Название чата', style: context.text.h3),
    content: FormTextField(
      key: const Key('rename-field'),
      controller: _controller,
      autofocus: true,
      decoration: const InputDecoration(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Отмена'),
      ),
      ElevatedButton(
        key: const Key('rename-save'),
        onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
        child: const Text('Сохранить'),
      ),
    ],
  );
}
