import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/monitoring/application/monitoring_providers.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_format.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_models.dart';
import 'package:my_tasker/features/monitoring/presentation/monitoring_editors.dart';
import 'package:my_tasker/features/work/presentation/work_widgets.dart'
    show WorkSectionHeader;

/// Вкладка «Серверы»: то, что вносит заказчик (серверы -> сервисы ->
/// проверки). Работает офлайн: это обычные синхронизируемые данные, правки
/// уходят при синхронизации и попадают в мониторинг в течение минуты.
class ServersManageTab extends ConsumerWidget {
  const ServersManageTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(monitorDataProvider);
    return data.when(
      loading: () => const ListSkeleton(),
      error: (e, _) => NoticeCard(
        key: const Key('servers-error'),
        label: 'Не загрузилось',
        tone: StatusTone.danger,
        text: 'Не удалось прочитать серверы с устройства.',
        actions: [
          FilledButton(
            key: const Key('servers-retry'),
            onPressed: () {
              ref
                ..invalidate(monitorServersProvider)
                ..invalidate(monitorServicesProvider)
                ..invalidate(monitorChecksProvider);
            },
            child: const Text('Повторить'),
          ),
        ],
      ),
      data: (d) {
        if (d.isEmpty) {
          return EmptyState(
            key: const Key('servers-empty'),
            icon: LucideIcons.server,
            title: 'Серверов пока нет',
            message:
                'Добавьте сервер, затем сервис на нём (сайт, бота, базу) и '
                'проверки для него.',
            action: FilledButton(
              key: const Key('servers-empty-add'),
              onPressed: () => showServerEditor(context),
              child: const Text('Добавить сервер'),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            WorkSectionHeader(
              title: 'Серверы',
              trailing: TextButton.icon(
                key: const Key('server-add'),
                onPressed: () => showServerEditor(context),
                icon: const Icon(LucideIcons.plus, size: 18),
                label: const Text('Сервер'),
              ),
            ),
            for (final s in d.servers) ...[
              _ServerCard(server: s, data: d),
              const SizedBox(height: AppSpacing.s3),
            ],
          ],
        );
      },
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({required this.server, required this.data});

  final MonitorServer server;
  final MonitorData data;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final services = data.servicesOf(server.id);
    final provider = server.provider;
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: Key('server-edit-${server.id}'),
            borderRadius: AppRadii.borderL,
            onTap: () => showServerEditor(context, serverId: server.id),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.s4),
              child: Row(
                children: [
                  Icon(LucideIcons.server, size: 20, color: c.textSecondary),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(server.name, style: t.bodyStrong),
                        Text(
                          provider == null
                              ? server.host
                              : '${server.host} · $provider',
                          style: t.numS.copyWith(color: c.textTertiary),
                        ),
                      ],
                    ),
                  ),
                  Icon(LucideIcons.pencil, size: 16, color: c.textTertiary),
                ],
              ),
            ),
          ),
          for (final s in services)
            _ServiceBlock(service: s, checks: data.checksOf(s.id)),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.s2,
                0,
                AppSpacing.s2,
                AppSpacing.s2,
              ),
              child: TextButton.icon(
                key: Key('service-add-${server.id}'),
                onPressed: () =>
                    showServiceEditor(context, serverId: server.id),
                icon: const Icon(LucideIcons.plus, size: 18),
                label: const Text('Сервис'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceBlock extends StatelessWidget {
  const _ServiceBlock({required this.service, required this.checks});

  final MonitorService service;
  final List<MonitorCheck> checks;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: Key('service-edit-${service.id}'),
            onTap: () => showServiceEditor(
              context,
              serverId: service.serverId,
              serviceId: service.id,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s4,
                vertical: AppSpacing.s3,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(service.name, style: t.bodyStrong),
                        ),
                        if (service.critical) ...[
                          const SizedBox(width: AppSpacing.s2),
                          Icon(
                            LucideIcons.bellRing,
                            size: 14,
                            color: c.textSecondary,
                          ),
                        ],
                      ],
                    ),
                  ),
                  Text(
                    checks.isEmpty ? 'без проверок' : '${checks.length} шт.',
                    style: t.caption.copyWith(color: c.textTertiary),
                  ),
                ],
              ),
            ),
          ),
          for (final check in checks)
            InkWell(
              key: Key('check-edit-${check.id}'),
              onTap: () => showCheckEditor(
                context,
                serviceId: service.id,
                checkId: check.id,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.s6,
                  AppSpacing.s1,
                  AppSpacing.s4,
                  AppSpacing.s1,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(check.name, style: t.bodyS),
                          Text(
                            '${checkSummary(check)} · '
                            '${intervalText(check.intervalSeconds)}',
                            style: t.caption.copyWith(color: c.textTertiary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: AppSpacing.s4),
              child: TextButton.icon(
                key: Key('check-add-${service.id}'),
                onPressed: () =>
                    showCheckEditor(context, serviceId: service.id),
                icon: const Icon(LucideIcons.plus, size: 16),
                label: const Text('Проверка'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
