import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/ai_chat/application/chat_session.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_errors.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_format.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/presentation/markdown_text.dart';
import 'package:my_tasker/features/ai_chat/presentation/proposal_card.dart';

/// Подпись шага ответа по имени инструмента.
String toolLabel(String name) => switch (name) {
  'get_tasks' => 'Читаю задачи',
  'get_events' => 'Читаю расписание',
  'create_task' => 'Готовлю задачу',
  _ => 'Инструмент $name',
};

/// Сообщение пользователя: справа, «пузырь» `surface/3`, радиус `l`
/// (правый нижний угол 6), не шире 85 % (02, 5.2.4).
class UserBubble extends StatelessWidget {
  const UserBubble({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.85,
        ),
        child: Container(
          key: const Key('user-bubble'),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s4,
            vertical: AppSpacing.s3,
          ),
          decoration: BoxDecoration(
            color: c.surface3,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(AppRadii.l),
              topRight: Radius.circular(AppRadii.l),
              bottomLeft: Radius.circular(AppRadii.l),
              bottomRight: Radius.circular(6),
            ),
          ),
          child: SelectableText(text, style: context.text.body),
        ),
      ),
    );
  }
}

/// Шаг ответа: вызов инструмента и его итог.
class ToolStepRow extends StatelessWidget {
  const ToolStepRow({
    required this.name,
    this.running = false,
    this.isError = false,
    super.key,
  });

  final String name;
  final bool running;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final suffix = running ? '…' : (isError ? ' · не удалось' : ' · готово');
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            running ? LucideIcons.loader : LucideIcons.wrench,
            size: 14,
            color: c.textTertiary,
          ),
          const SizedBox(width: AppSpacing.s2),
          Text(
            '${toolLabel(name)}$suffix',
            style: t.caption.copyWith(color: c.textTertiary),
          ),
        ],
      ),
    );
  }
}

/// Строка сбоя под ответом: иконка, русский текст, «Повторить».
/// Красным — только критичные ошибки.
class FailureLine extends StatelessWidget {
  const FailureLine({required this.failure, this.onRetry, super.key});

  final ChatFailure failure;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final color = failure.critical ? c.danger : c.textSecondary;
    return Row(
      key: const Key('failure-line'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          failure.isOffline ? LucideIcons.cloudOff : LucideIcons.circleAlert,
          size: 16,
          color: color,
        ),
        const SizedBox(width: AppSpacing.s2),
        Expanded(
          child: Text.rich(
            TextSpan(
              style: t.bodyS.copyWith(color: color),
              children: [
                TextSpan(text: failure.message),
                if (failure.retryable && onRetry != null) ...[
                  const TextSpan(text: '  '),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.baseline,
                    baseline: TextBaseline.alphabetic,
                    child: InkWell(
                      key: const Key('failure-retry'),
                      onTap: onRetry,
                      child: Text(
                        'Повторить',
                        style: t.bodyS.copyWith(
                          color: c.textPrimary,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Ответ ИИ: без пузыря, во всю ширину, слева иконка `sparkles`; под
/// текстом — карточки предложений и строка метаданных (02, 5.2.4).
class AssistantMessageView extends StatelessWidget {
  const AssistantMessageView({
    required this.text,
    this.steps = const [],
    this.proposals = const [],
    this.streaming = false,
    this.thinking = false,
    this.statusLabel,
    this.failure,
    this.onRetry,
    this.meta,
    this.copyable = false,
    super.key,
  });

  final String text;
  final List<Widget> steps;
  final List<ToolProposal> proposals;
  final bool streaming;

  /// Идёт ожидание первого токена («Думаю…»).
  final bool thinking;

  /// «Остановлено» и т. п.
  final String? statusLabel;
  final ChatFailure? failure;
  final VoidCallback? onRetry;

  /// Строка метаданных: модель, токены, стоимость.
  final String? meta;
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3, right: AppSpacing.s2),
          child: Icon(LucideIcons.sparkles, size: 16, color: c.textSecondary),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ...steps,
              if (thinking && text.isEmpty)
                Text(
                  'Думаю…',
                  key: const Key('thinking'),
                  style: t.body.copyWith(color: c.textSecondary),
                ),
              if (text.isNotEmpty) MarkdownText(text, cursor: streaming),
              for (final p in proposals) ...[
                const SizedBox(height: AppSpacing.s3),
                ProposalCard(proposal: p),
              ],
              if (statusLabel != null) ...[
                const SizedBox(height: AppSpacing.s1),
                Text(
                  statusLabel!,
                  key: const Key('message-status'),
                  style: t.caption.copyWith(color: c.textTertiary),
                ),
              ],
              if (failure != null) ...[
                const SizedBox(height: AppSpacing.s2),
                FailureLine(failure: failure!, onRetry: onRetry),
              ],
              if (meta != null || copyable) ...[
                const SizedBox(height: AppSpacing.s1),
                Row(
                  children: [
                    if (meta != null)
                      Flexible(
                        child: Text(
                          meta!,
                          key: const Key('message-meta'),
                          style: t.caption.copyWith(color: c.textTertiary),
                        ),
                      ),
                    if (copyable)
                      InkResponse(
                        key: const Key('message-copy'),
                        onTap: () =>
                            Clipboard.setData(ClipboardData(text: text)),
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.s2),
                          child: Icon(
                            LucideIcons.copy,
                            size: 14,
                            color: c.textTertiary,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Метаданные сохранённого ответа: «модель · 1 234 ток. · 0,12 ₽».
String messageMeta(ChatMessage m) {
  final parts = <String>[
    if (m.model != null) m.model!,
    if (m.promptTokens != null || m.completionTokens != null)
      '${formatCount((m.promptTokens ?? 0) + (m.completionTokens ?? 0))} ток.',
    if (m.costKopecks != null) formatCost(m.costKopecks!),
  ];
  return parts.join(' · ');
}

/// Метаданные живого ответа.
String liveMeta(ChatSessionState s) {
  final tokens = s.promptTokens + s.completionTokens;
  if (tokens == 0) return '';
  return '${formatCount(tokens)} ток. · ${formatCost(s.costKopecks)}';
}
