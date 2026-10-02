import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/local_llm/chat_routing.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart' show ChatMode;
import 'package:my_tasker/features/local_ai/application/local_ai_providers.dart';

/// Переключатель режима беседы «Облако / На устройстве».
///
/// Виджет для чата этапа 3 (подключается одной строкой в шапке беседы):
///
/// ```dart
/// ChatModeSwitch(conversationId: conversation.id, mode: conversation.mode)
/// ```
///
/// Переключение пишет `ai_conversations.mode` (и модель беседы) через
/// движок синхронизации. Перейти на `local` можно только когда офлайн-модель
/// скачана: иначе предлагается открыть загрузку (или объясняется, что
/// платформа её не поддерживает). Во время генерации переключатель заблокирован.
class ChatModeSwitch extends ConsumerWidget {
  const ChatModeSwitch({
    required this.conversationId,
    required this.mode,
    this.onSwitched,
    super.key,
  });

  final String conversationId;
  final ChatMode mode;

  /// Вызывается после успешного переключения.
  final ValueChanged<ChatMode>? onSwitched;

  Future<void> _select(
    BuildContext context,
    WidgetRef ref,
    ChatMode target,
  ) async {
    if (target == mode) return;
    final service = ref.read(localChatServiceProvider);
    if (target == ChatMode.local) {
      switch (ref.read(localAvailabilityProvider)) {
        case LocalAvailability.ready:
          break;
        case LocalAvailability.unsupportedPlatform:
          final reason = ref.read(localLlmEngineProvider).unsupportedReason;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(reason ?? 'Офлайн-модель недоступна')),
          );
          return;
        case LocalAvailability.modelNotReady:
          final go = await showConfirmDialog(
            context,
            title: 'Офлайн-модель не скачана',
            message:
                'Чтобы отвечать без сети, скачайте модель (около 2,5 ГБ, по '
                'Wi-Fi). Открыть загрузку?',
            confirmLabel: 'Открыть',
          );
          if (go && context.mounted) context.go('/ai/settings/local');
          return;
      }
    }
    await service.switchMode(conversationId, target);
    onSwitched?.call(target);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(localChatServiceProvider).isGenerating;
    return SegmentedButton<ChatMode>(
      key: const Key('chat-mode-switch'),
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(
          value: ChatMode.cloud,
          icon: Icon(LucideIcons.cloud, size: 16),
          label: Text('Облако'),
        ),
        ButtonSegment(
          value: ChatMode.local,
          icon: Icon(LucideIcons.smartphone, size: 16),
          label: Text('На устройстве'),
        ),
      ],
      selected: {mode},
      onSelectionChanged: busy ? null : (s) => _select(context, ref, s.first),
    );
  }
}
