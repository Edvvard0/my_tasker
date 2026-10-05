import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/format/ru_format.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/monitoring/application/monitoring_providers.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_format.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_models.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_stats.dart';
import 'package:my_tasker/features/monitoring/presentation/incident_widgets.dart';
import 'package:my_tasker/features/monitoring/presentation/monitoring_editors.dart';
import 'package:my_tasker/features/monitoring/presentation/pulse_widgets.dart';

/// Вкладка «Дашборд»: итог, «Проверить все», карточки сервисов по серверам,
/// упавшие первыми. Без связи показывает кэш с подписью «Данные на 14:32 ·
/// нет сети» (spec 8).
class PulseDashboard extends ConsumerStatefulWidget {
  const PulseDashboard({super.key});

  @override
  ConsumerState<PulseDashboard> createState() => _PulseDashboardState();
}

class _PulseDashboardState extends ConsumerState<PulseDashboard> {
  String? _notice;

  Future<void> _refresh() async {
    final result = await ref.read(pulseProvider.notifier).refreshNow();
    if (!mounted) return;
    setState(() => _notice = result.ok ? null : result.message);
  }

  @override
  Widget build(BuildContext context) {
    final pulse = ref.watch(pulseProvider);
    final data = ref.watch(monitorDataProvider).value;
    final now = ref.watch(clockProvider)();
    final snapshot = pulse.snapshot;
    if (snapshot == null) {
      if (pulse.loading) return const ListSkeleton();
      if (pulse.offline) {
        return EmptyState(
          key: const Key('pulse-offline-empty'),
          icon: LucideIcons.cloudOff,
          title: 'Нет связи с сервером',
          message:
              'Дашборд появится, как только сервер ответит; последний снимок '
              'здесь будет сохраняться.',
          action: ElevatedButton(
            key: const Key('pulse-retry'),
            onPressed: () => ref.read(pulseProvider.notifier).load(),
            child: const Text('Повторить'),
          ),
        );
      }
      return NoticeCard(
        key: const Key('pulse-error'),
        label: 'Не загрузилось',
        tone: StatusTone.danger,
        text: pulse.error ?? 'Не удалось получить данные.',
        actions: [
          FilledButton(
            key: const Key('pulse-retry'),
            onPressed: () => ref.read(pulseProvider.notifier).load(),
            child: const Text('Повторить'),
          ),
        ],
      );
    }
    final asOf = pulse.asOf;
    final engine = snapshot.engine;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pulse.offline && asOf != null) ...[
          PulseBanner(
            key: const Key('pulse-stale'),
            icon: LucideIcons.cloudOff,
            text: staleLabel(asOf),
          ),
          const SizedBox(height: AppSpacing.s2),
        ] else if (pulse.error != null) ...[
          PulseBanner(
            key: const Key('pulse-fetch-error'),
            icon: LucideIcons.circleAlert,
            text: pulse.error!,
            danger: true,
          ),
          const SizedBox(height: AppSpacing.s2),
        ],
        if (!engine.configured) ...[
          const PulseBanner(
            key: Key('pulse-engine-missing'),
            icon: LucideIcons.triangleAlert,
            text:
                'Движок проверок на сервере не подключён: данных не будет, '
                'пока его не настроят.',
          ),
          const SizedBox(height: AppSpacing.s2),
        ] else if (!engine.healthy) ...[
          PulseBanner(
            key: const Key('pulse-engine-stale'),
            icon: LucideIcons.triangleAlert,
            text:
                'Данные устарели: ${engineErrorText(engine.error)}. '
                'Тревоги по сервисам не отправляются, пока движок молчит.',
            danger: true,
          ),
          const SizedBox(height: AppSpacing.s2),
        ],
        _Header(
          snapshot: snapshot,
          refreshing: pulse.refreshing,
          offline: pulse.offline,
          onRefresh: _refresh,
        ),
        if (_notice != null) ...[
          const SizedBox(height: AppSpacing.s2),
          PulseBanner(
            key: const Key('pulse-notice'),
            icon: LucideIcons.info,
            text: _notice!,
          ),
        ],
        const SizedBox(height: AppSpacing.s3),
        if (snapshot.services.isEmpty)
          _EmptyDashboard(hasServers: !(data?.isEmpty ?? true))
        else
          for (final group in _groups(snapshot.services, data)) ...[
            _ServerGroup(group: group, now: now),
            const SizedBox(height: AppSpacing.s3),
          ],
      ],
    );
  }
}

class _Group {
  _Group(this.serverId, this.name, this.host, this.services);

  final String serverId;
  final String name;
  final String? host;
  final List<PulseService> services;
}

/// Серверы в порядке появления в снимке (упавшие сервисы — первыми).
List<_Group> _groups(List<PulseService> services, MonitorData? data) {
  final groups = <String, _Group>{};
  for (final s in services) {
    groups
        .putIfAbsent(
          s.serverId,
          () => _Group(
            s.serverId,
            s.server,
            data?.serverById[s.serverId]?.host,
            [],
          ),
        )
        .services
        .add(s);
  }
  return groups.values.toList();
}

class _Header extends StatelessWidget {
  const _Header({
    required this.snapshot,
    required this.refreshing,
    required this.offline,
    required this.onRefresh,
  });

  final PulseSnapshot snapshot;
  final bool refreshing;
  final bool offline;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    final c = context.colors;
    final total = snapshot.total;
    final String summary;
    if (total == 0) {
      summary = 'Сервисов пока нет';
    } else if (snapshot.down > 0) {
      summary = '${snapshot.down} лежит из $total';
    } else if (snapshot.up == total) {
      summary = total == 1 ? 'Всё работает' : 'Все $total работают';
    } else {
      summary = 'Работает ${snapshot.up} из $total';
    }
    return Row(
      children: [
        Expanded(
          child: Text(
            summary,
            key: const Key('pulse-summary'),
            style: t.h3.copyWith(
              color: snapshot.down > 0 ? c.danger : c.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.s2),
        Tooltip(
          message: offline ? 'Нет связи с сервером' : 'Проверить сейчас',
          child: ElevatedButton.icon(
            key: const Key('pulse-refresh'),
            onPressed: offline || refreshing ? null : onRefresh,
            icon: refreshing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.refreshCw, size: 16),
            label: Text(total > 1 ? 'Проверить все' : 'Проверить'),
          ),
        ),
      ],
    );
  }
}

class _EmptyDashboard extends StatelessWidget {
  const _EmptyDashboard({required this.hasServers});

  final bool hasServers;

  @override
  Widget build(BuildContext context) {
    if (!hasServers) {
      return EmptyState(
        key: const Key('pulse-empty'),
        icon: LucideIcons.server,
        title: 'Серверов пока нет',
        message:
            'Добавьте сервер, сервис на нём и проверки: HTTP, TCP, DNS или '
            'SSL. Сервер будет проверять их сам и пришлёт тревогу в Telegram.',
        action: FilledButton(
          key: const Key('pulse-empty-add'),
          onPressed: () => showServerEditor(context),
          child: const Text('Добавить сервер'),
        ),
      );
    }
    return const EmptyState(
      key: Key('pulse-empty-nodata'),
      icon: LucideIcons.activity,
      title: 'Данных мониторинга пока нет',
      message:
          'Сервисы с проверками попадут в «Пульс» в течение минуты после '
          'синхронизации. Сервис без проверок здесь не показывается.',
    );
  }
}

/// Сервер со своими карточками; заголовок сворачивается (02, 5.5).
class _ServerGroup extends StatefulWidget {
  const _ServerGroup({required this.group, required this.now});

  final _Group group;
  final DateTime now;

  @override
  State<_ServerGroup> createState() => _ServerGroupState();
}

class _ServerGroupState extends State<_ServerGroup> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final g = widget.group;
    final down = g.services.where((s) => s.status == PulseStatus.down).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: Key('pulse-group-${g.serverId}'),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
            child: Row(
              children: [
                Icon(
                  _open ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                  size: 16,
                  color: c.textSecondary,
                ),
                const SizedBox(width: AppSpacing.s1),
                Flexible(
                  child: Text(
                    g.name,
                    style: t.numM,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (g.host != null) ...[
                  const SizedBox(width: AppSpacing.s2),
                  Flexible(
                    child: Text(
                      g.host!,
                      style: t.numS.copyWith(color: c.textTertiary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                const Spacer(),
                if (down > 0)
                  Text(
                    '$down лежит из ${g.services.length}',
                    style: t.caption.copyWith(color: c.danger),
                  ),
              ],
            ),
          ),
        ),
        if (_open) ...[
          const SizedBox(height: AppSpacing.s2),
          CardGrid(
            children: [
              for (final s in g.services)
                PulseServiceCard(
                  service: s,
                  now: widget.now,
                  onTap: () => showServiceDetails(context, s.id),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------- детали

/// Детали сервиса: метрики за 24 часа / 7 / 30 суток, проверки и история
/// инцидентов (sheet 92 % на телефоне, правая панель на десктопе).
Future<void> showServiceDetails(BuildContext context, String serviceId) =>
    showEditorSheet<void>(
      context,
      builder: (_) => ServiceDetails(serviceId: serviceId),
    );

class ServiceDetails extends ConsumerWidget {
  const ServiceDetails({required this.serviceId, super.key});

  final String serviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final snapshot = ref.watch(pulseProvider).snapshot;
    final data = ref.watch(monitorDataProvider).value;
    final now = ref.watch(clockProvider)();
    PulseService? service;
    for (final s in snapshot?.services ?? const <PulseService>[]) {
      if (s.id == serviceId) service = s;
    }
    if (service == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHeader(title: 'Сервис'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Сервис не найден в «Пульсе»: возможно, его удалили.',
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final incidents = ref.watch(incidentsProvider(serviceId));
    final local = data?.serviceById[serviceId];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(
          title: service.name,
          trailing: local == null
              ? null
              : IconButton(
                  key: const Key('details-edit'),
                  tooltip: 'Править сервис',
                  onPressed: () => showServiceEditor(
                    context,
                    serverId: local.serverId,
                    serviceId: local.id,
                  ),
                  icon: const Icon(LucideIcons.pencil, size: 20),
                ),
        ),
        Flexible(
          child: SingleChildScrollView(
            key: const Key('service-details'),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    StatusPill(
                      label: statusLabel(service.status),
                      tone: pulseTone(service.status),
                    ),
                    const SizedBox(width: AppSpacing.s2),
                    Expanded(
                      child: Text(
                        'Сервер ${service.server}'
                        '${service.critical ? ' · критичный' : ''}',
                        style: t.bodyS.copyWith(color: c.textSecondary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.s4),
                Row(
                  children: [
                    Expanded(
                      child: PulseMetric(
                        label: '24 часа',
                        value: formatAvailability(service.availability.h24),
                        warn: availabilityWarns(service.availability.h24),
                      ),
                    ),
                    Expanded(
                      child: PulseMetric(
                        label: '7 дней',
                        value: formatAvailability(service.availability.d7),
                        warn: availabilityWarns(service.availability.d7),
                      ),
                    ),
                    Expanded(
                      child: PulseMetric(
                        label: '30 дней',
                        value: formatAvailability(service.availability.d30),
                        warn: availabilityWarns(service.availability.d30),
                      ),
                    ),
                    Expanded(
                      child: PulseMetric(
                        label: 'Отклик',
                        value: formatResponse(service.responseMs),
                        warn: responseWarns(service.responseMs),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.s4),
                Text(
                  'ПРОВЕРКИ',
                  style: t.overline.copyWith(color: c.textSecondary),
                ),
                const SizedBox(height: AppSpacing.s2),
                for (final check in service.checks)
                  _CheckRow(
                    check: check,
                    target: data?.checkById[check.id]?.target,
                    now: now,
                  ),
                const SizedBox(height: AppSpacing.s4),
                Text(
                  'ИНЦИДЕНТЫ',
                  style: t.overline.copyWith(color: c.textSecondary),
                ),
                const SizedBox(height: AppSpacing.s2),
                if (incidents.loading)
                  const LinearProgressIndicator()
                else if (incidents.items.isEmpty)
                  Text(
                    incidents.offline
                        ? 'Нет связи: история инцидентов недоступна.'
                        : 'Инцидентов не было.',
                    key: const Key('details-no-incidents'),
                    style: t.bodyS.copyWith(color: c.textSecondary),
                  )
                else
                  for (final i in incidents.items.take(5)) ...[
                    IncidentTile(incident: i, now: now, showService: false),
                    const SizedBox(height: AppSpacing.s2),
                  ],
                const SizedBox(height: AppSpacing.s4),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.check,
    required this.target,
    required this.now,
  });

  final PulseCheck check;
  final String? target;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final last = parseMoment(check.lastAt);
    return Padding(
      key: Key('details-check-${check.id}'),
      padding: const EdgeInsets.only(bottom: AppSpacing.s2),
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.s3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CheckChip(check: check),
                const SizedBox(width: AppSpacing.s2),
                Expanded(child: Text(check.name, style: t.bodyStrong)),
                StatusPill(
                  label: check.problem != null
                      ? 'Не запускается'
                      : statusLabel(check.status),
                  tone: check.problem != null
                      ? StatusTone.warning
                      : pulseTone(check.status),
                ),
              ],
            ),
            if (target != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  target!,
                  style: t.numS.copyWith(color: c.textTertiary),
                ),
              ),
            const SizedBox(height: AppSpacing.s2),
            Text(
              'Последний результат: '
              '${last == null ? 'ещё не было' : formatMoment(last, now)} · '
              'отклик ${formatResponse(check.responseMs)} · '
              '24 ч ${formatAvailability(check.availability.h24)}',
              style: t.caption.copyWith(color: c.textSecondary),
            ),
            if (check.problem != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  problemText(check.problem!),
                  style: t.caption.copyWith(color: c.textPrimary),
                ),
              ),
            const SizedBox(height: AppSpacing.s2),
            Sparkline(points: check.spark, height: 24),
          ],
        ),
      ),
    );
  }
}
