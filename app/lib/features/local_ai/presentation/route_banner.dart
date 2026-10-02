import 'package:flutter/material.dart';
import 'package:my_tasker/core/local_llm/chat_routing.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';

/// Плашка над полем ввода чата по решению маршрутизации (`decideRoute`):
/// «нет сети — ответить локально?», «сообщение сохранено, отправим в облако,
/// когда появится сеть», «модель не скачана». Для `sendCloud`/`sendLocal`
/// ничего не рисует.
class LocalRouteBanner extends StatelessWidget {
  const LocalRouteBanner({
    required this.decision,
    this.onContinueLocally,
    this.onSendToCloud,
    this.onOpenModels,
    super.key,
  });

  final RouteDecision decision;

  /// «Ответить на устройстве» (при `offerLocal`).
  final VoidCallback? onContinueLocally;

  /// «Отправить в облако» (при `holdForNetwork`, когда сеть вернулась, и
  /// при `localUnavailable` с `cloudPossible`).
  final VoidCallback? onSendToCloud;

  /// Открыть экран моделей (при `localUnavailable`).
  final VoidCallback? onOpenModels;

  @override
  Widget build(BuildContext context) {
    if (decision.action == ChatRouteAction.sendCloud ||
        decision.action == ChatRouteAction.sendLocal) {
      return const SizedBox.shrink();
    }
    final buttons = <Widget>[
      if (decision.action == ChatRouteAction.offerLocal &&
          onContinueLocally != null)
        FilledButton(
          key: const Key('route-continue-local'),
          onPressed: onContinueLocally,
          child: const Text('Ответить на устройстве'),
        ),
      if (decision.action == ChatRouteAction.holdForNetwork &&
          onSendToCloud != null)
        ElevatedButton(
          key: const Key('route-send-cloud'),
          onPressed: onSendToCloud,
          child: const Text('Отправить в облако'),
        ),
      if (decision.action == ChatRouteAction.localUnavailable) ...[
        if (onOpenModels != null)
          ElevatedButton(
            key: const Key('route-open-models'),
            onPressed: onOpenModels,
            child: const Text('Офлайн-модель'),
          ),
        if (decision.cloudPossible && onSendToCloud != null)
          FilledButton(
            key: const Key('route-send-cloud'),
            onPressed: onSendToCloud,
            child: const Text('Отправить в облако'),
          ),
      ],
    ];
    return AppCard(
      key: const Key('route-banner'),
      padding: const EdgeInsets.all(AppSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(decision.message, style: context.text.bodyS),
          if (buttons.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s3),
            Wrap(
              spacing: AppSpacing.s3,
              runSpacing: AppSpacing.s2,
              children: buttons,
            ),
          ],
        ],
      ),
    );
  }
}
