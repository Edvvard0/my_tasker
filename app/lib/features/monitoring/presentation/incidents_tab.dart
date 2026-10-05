import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/monitoring/application/monitoring_providers.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_format.dart';
import 'package:my_tasker/features/monitoring/presentation/incident_widgets.dart';
import 'package:my_tasker/features/monitoring/presentation/pulse_widgets.dart';

/// Вкладка «Инциденты»: лента, новые первыми; страницы подгружаются по
/// составному курсору (`before` + `before_id`), фильтр по сервису.
class IncidentsTab extends ConsumerStatefulWidget {
  const IncidentsTab({super.key});

  @override
  ConsumerState<IncidentsTab> createState() => _IncidentsTabState();
}

class _IncidentsTabState extends ConsumerState<IncidentsTab> {
  String? _serviceId;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(incidentsProvider(_serviceId));
    final services = ref.watch(monitorServicesProvider).value ?? const [];
    final now = ref.watch(clockProvider)();
    final t = context.text;
    final c = context.colors;
    final controller = ref.read(incidentsProvider(_serviceId).notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (services.length > 1) ...[
          ChipRow(
            children: [
              FilterPill(
                key: const Key('incidents-filter-all'),
                label: 'Все сервисы',
                selected: _serviceId == null,
                onTap: () => setState(() => _serviceId = null),
              ),
              for (final s in services)
                FilterPill(
                  key: Key('incidents-filter-${s.id}'),
                  label: s.name,
                  selected: _serviceId == s.id,
                  onTap: () => setState(() => _serviceId = s.id),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
        ],
        if (state.offline && state.asOf != null) ...[
          PulseBanner(
            key: const Key('incidents-stale'),
            icon: LucideIcons.cloudOff,
            text: staleLabel(state.asOf!),
          ),
          const SizedBox(height: AppSpacing.s2),
        ],
        if (state.loading && state.items.isEmpty)
          const ListSkeleton()
        else if (state.items.isEmpty && state.error != null)
          NoticeCard(
            key: const Key('incidents-error'),
            label: 'Не загрузилось',
            tone: StatusTone.danger,
            text: state.error!,
            actions: [
              FilledButton(
                key: const Key('incidents-retry'),
                onPressed: controller.reload,
                child: const Text('Повторить'),
              ),
            ],
          )
        else if (state.items.isEmpty && state.offline)
          EmptyState(
            key: const Key('incidents-offline-empty'),
            icon: LucideIcons.cloudOff,
            title: 'Нет связи с сервером',
            message: 'Журнал инцидентов хранится на сервере.',
            action: ElevatedButton(
              key: const Key('incidents-retry'),
              onPressed: controller.reload,
              child: const Text('Повторить'),
            ),
          )
        else if (state.items.isEmpty)
          const EmptyState(
            key: Key('incidents-empty'),
            icon: LucideIcons.circleCheck,
            title: 'Инцидентов не было',
            message: 'Когда сервис упадёт, запись появится здесь.',
          )
        else ...[
          for (final i in state.items) ...[
            IncidentTile(key: Key('incident-${i.id}'), incident: i, now: now),
            const SizedBox(height: AppSpacing.s2),
          ],
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s2),
              child: Text(
                state.error!,
                key: const Key('incidents-more-error'),
                style: t.bodyS.copyWith(color: c.danger),
              ),
            ),
          if (state.hasMore)
            Align(
              child: ElevatedButton(
                key: const Key('incidents-more'),
                onPressed: state.loadingMore || state.offline
                    ? null
                    : controller.loadMore,
                child: state.loadingMore
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Показать ещё'),
              ),
            ),
        ],
      ],
    );
  }
}
