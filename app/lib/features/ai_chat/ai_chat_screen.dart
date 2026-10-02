import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/calendar_time/ru_dates.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/ai_chat/application/ai_providers.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/presentation/chat_screen.dart';
import 'package:my_tasker/features/ai_chat/presentation/chat_sheets.dart';

/// Строка списка чатов.
class ChatListEntry {
  const ChatListEntry(this.conversation, this.lastMessage);

  final Conversation conversation;
  final ChatMessage? lastMessage;

  /// Время последней активности: сообщение или правка чата.
  DateTime get activity {
    final times = <DateTime>[
      ?conversation.updatedAt,
      ?conversation.createdAt,
      ?(lastMessage == null ? null : uuid7Time(lastMessage!.id)),
    ];
    return times.isEmpty
        ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
        : times.reduce((a, b) => a.isAfter(b) ? a : b);
  }
}

/// Раздел списка (02, 5.2.1).
enum ChatGroup {
  pinned('Закреплённые'),
  today('Сегодня'),
  week('На этой неделе'),
  earlier('Ранее');

  const ChatGroup(this.label);

  final String label;
}

/// Группа чата по времени последней активности.
ChatGroup groupOf(ChatListEntry e, DateTime now) {
  if (e.conversation.pinned) return ChatGroup.pinned;
  final t = e.activity.toLocal();
  final n = now.toLocal();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(t.year, t.month, t.day);
  final days = today.difference(day).inDays;
  if (days <= 0) return ChatGroup.today;
  if (days < 7) return ChatGroup.week;
  return ChatGroup.earlier;
}

/// Отбор и порядок списка: архив отдельно, тема, поиск по названию и
/// тексту последнего сообщения; закреплённые вверху, затем новые.
List<ChatListEntry> filterEntries(
  List<ChatListEntry> all, {
  required bool archived,
  AiTopic? topic,
  String query = '',
}) {
  final q = query.trim().toLowerCase();
  final result = [
    for (final e in all)
      if (e.conversation.archived == archived &&
          (topic == null || e.conversation.topic == topic) &&
          (q.isEmpty ||
              e.conversation.title.toLowerCase().contains(q) ||
              (e.lastMessage?.text.toLowerCase().contains(q) ?? false)))
        e,
  ];
  return result..sort((a, b) {
    if (a.conversation.pinned != b.conversation.pinned) {
      return a.conversation.pinned ? -1 : 1;
    }
    return b.activity.compareTo(a.activity);
  });
}

/// «ИИ»: список чатов (02, 5.2.1): поиск, чипы тем, группы по времени,
/// закреплённые сверху, свайп влево — архив, меню — переименовать,
/// закрепить, удалить.
class AiChatScreen extends ConsumerStatefulWidget {
  const AiChatScreen({super.key});

  @override
  ConsumerState<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends ConsumerState<AiChatScreen> {
  final TextEditingController _search = TextEditingController();
  AiTopic? _topic;
  bool _archive = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
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
              key: const Key('row-menu-rename'),
              title: 'Переименовать',
              leading: LucideIcons.pencil,
              onTap: () => Navigator.of(context).pop('rename'),
            ),
            PickerRow(
              key: const Key('row-menu-pin'),
              title: conv.pinned ? 'Открепить' : 'Закрепить',
              leading: LucideIcons.pin,
              onTap: () => Navigator.of(context).pop('pin'),
            ),
            PickerRow(
              key: const Key('row-menu-archive'),
              title: conv.archived ? 'Вернуть из архива' : 'В архив',
              leading: LucideIcons.archive,
              onTap: () => Navigator.of(context).pop('archive'),
            ),
            PickerRow(
              key: const Key('row-menu-delete'),
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
        if (title != null) await repo.rename(conv.id, title);
      case 'pin':
        await repo.setPinned(conv.id, pinned: !conv.pinned);
      case 'archive':
        await repo.setArchived(conv.id, archived: !conv.archived);
      case 'delete':
        final ok = await showConfirmDialog(
          context,
          title: 'Удалить чат?',
          message:
              '«${conv.title.isEmpty ? 'Чат без названия' : conv.title}» '
              'уйдёт в корзину на 30 дней.',
          confirmLabel: 'Удалить',
          danger: true,
        );
        if (ok) await repo.deleteConversation(conv.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(aiBootstrapProvider);
    final conversations = ref.watch(conversationsProvider);
    final last = ref.watch(lastMessagesProvider).value ?? const {};
    final now = ref.watch(clockProvider)();
    final c = context.colors;
    final gutter = context.windowClass.gutter;
    Widget body;
    if (conversations.hasError && !conversations.hasValue) {
      body = const NoticeCard(
        label: 'Ошибка',
        tone: StatusTone.danger,
        text: 'Не удалось прочитать чаты с устройства.',
      );
    } else if (!conversations.hasValue) {
      body = const ListSkeleton();
    } else {
      final all = [
        for (final conv in conversations.requireValue)
          ChatListEntry(conv, last[conv.id]),
      ];
      final entries = filterEntries(
        all,
        archived: _archive,
        topic: _topic,
        query: _search.text,
      );
      body = entries.isEmpty
          ? EmptyState(
              icon: _archive ? LucideIcons.archive : LucideIcons.sparkles,
              title: all.isEmpty
                  ? 'Пока нет чатов'
                  : (_archive ? 'В архиве пусто' : 'Ничего не найдено'),
              message: all.isEmpty
                  ? 'Спросите ИИ о задачах, расписании или работе.'
                  : 'Измените поиск или тему.',
              action: all.isEmpty
                  ? ElevatedButton(
                      key: const Key('empty-new-chat'),
                      onPressed: () => context.push('/ai/new'),
                      child: const Text('Новый чат'),
                    )
                  : null,
            )
          : _ChatList(
              entries: entries,
              now: now,
              onOpen: (e) => context.push('/ai/chat/${e.conversation.id}'),
              onMenu: (e) => _menu(e.conversation),
              onArchive: (e) => ref
                  .read(aiRepositoryProvider)
                  .setArchived(e.conversation.id, archived: !_archive),
            );
    }
    return ScreenScaffold(
      title: 'ИИ',
      scrollable: false,
      actions: [
        IconButton(
          key: const Key('ai-new-chat'),
          tooltip: 'Новый чат',
          onPressed: () => context.push('/ai/new'),
          icon: const Icon(LucideIcons.squarePen, size: 22),
        ),
        IconButton(
          key: const Key('ai-settings'),
          tooltip: 'Настройки ИИ',
          onPressed: () => context.go('/ai/settings'),
          icon: const Icon(LucideIcons.settings2, size: 22),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormTextField(
            key: const Key('chat-search'),
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Поиск по чатам',
              prefixIcon: Icon(
                LucideIcons.search,
                size: 18,
                color: c.textTertiary,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          SizedBox(
            height: 36,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  FilterPill(
                    key: const Key('topic-all'),
                    label: 'Все',
                    selected: _topic == null && !_archive,
                    onTap: () => setState(() {
                      _topic = null;
                      _archive = false;
                    }),
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  FilterPill(
                    key: const Key('topic-archive'),
                    label: 'Архив',
                    icon: LucideIcons.archive,
                    selected: _archive,
                    onTap: () => setState(() => _archive = !_archive),
                  ),
                  for (final t in AiTopic.selectable) ...[
                    const SizedBox(width: AppSpacing.s2),
                    FilterPill(
                      key: Key('topic-chip-${t.wire}'),
                      label: t.label,
                      selected: _topic == t,
                      onTap: () =>
                          setState(() => _topic = _topic == t ? null : t),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(context).bottom + gutter,
              ),
              child: body,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatList extends StatelessWidget {
  const _ChatList({
    required this.entries,
    required this.now,
    required this.onOpen,
    required this.onMenu,
    required this.onArchive,
  });

  final List<ChatListEntry> entries;
  final DateTime now;
  final ValueChanged<ChatListEntry> onOpen;
  final ValueChanged<ChatListEntry> onMenu;
  final ValueChanged<ChatListEntry> onArchive;

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    final c = context.colors;
    final children = <Widget>[];
    ChatGroup? current;
    for (final e in entries) {
      final group = groupOf(e, now);
      if (group != current) {
        current = group;
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s1,
              AppSpacing.s3,
              0,
              AppSpacing.s1,
            ),
            child: Text(
              group.label.toUpperCase(),
              key: Key('group-${group.name}'),
              style: t.overline.copyWith(color: c.textTertiary),
            ),
          ),
        );
      }
      children.add(
        Dismissible(
          key: ValueKey(e.conversation.id),
          direction: DismissDirection.endToStart,
          onDismissed: (_) => onArchive(e),
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: AppSpacing.s6),
            color: c.surface3,
            child: Icon(
              e.conversation.archived
                  ? LucideIcons.archiveRestore
                  : LucideIcons.archive,
              color: c.textPrimary,
            ),
          ),
          child: _ChatRow(
            entry: e,
            now: now,
            onTap: () => onOpen(e),
            onMenu: () => onMenu(e),
          ),
        ),
      );
    }
    return ListView(key: const Key('chat-rows'), children: children);
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({
    required this.entry,
    required this.now,
    required this.onTap,
    required this.onMenu,
  });

  final ChatListEntry entry;
  final DateTime now;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final conv = entry.conversation;
    final c = context.colors;
    final t = context.text;
    final preview = entry.lastMessage?.text.replaceAll('\n', ' ') ?? '';
    final activity = entry.activity.toLocal();
    final n = now.toLocal();
    final isToday =
        activity.year == n.year &&
        activity.month == n.month &&
        activity.day == n.day;
    return InkWell(
      key: Key('chat-row-${conv.id}'),
      onTap: onTap,
      onLongPress: onMenu,
      borderRadius: AppRadii.borderM,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s1,
          vertical: AppSpacing.s3,
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: c.surface3,
                shape: BoxShape.circle,
              ),
              child: Icon(conv.topic.icon, size: 18, color: c.textSecondary),
            ),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (conv.pinned) ...[
                        Icon(LucideIcons.pin, size: 12, color: c.textTertiary),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          conv.title.isEmpty ? 'Чат без названия' : conv.title,
                          style: t.bodyStrong,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  if (preview.isNotEmpty)
                    Text(
                      preview,
                      style: t.bodyS.copyWith(color: c.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.s2),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  isToday ? timeOf(activity) : dayMonth(activity, now: n),
                  style: t.caption.copyWith(color: c.textTertiary),
                ),
                const SizedBox(height: 2),
                Icon(
                  conv.mode == ChatMode.local
                      ? LucideIcons.smartphone
                      : LucideIcons.cloud,
                  size: 12,
                  color: c.textTertiary,
                ),
              ],
            ),
            IconButton(
              key: Key('chat-row-menu-${conv.id}'),
              tooltip: 'Действия',
              onPressed: onMenu,
              icon: Icon(LucideIcons.ellipsis, size: 18, color: c.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
