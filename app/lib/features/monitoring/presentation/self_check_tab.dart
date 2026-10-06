import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/format/ru_format.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/sync/sync_providers.dart'
    show syncStatusProvider;
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/monitoring/application/monitoring_providers.dart';
import 'package:my_tasker/features/monitoring/data/monitoring_api.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_format.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_models.dart';
import 'package:my_tasker/features/monitoring/presentation/pulse_widgets.dart';
import 'package:my_tasker/features/work/presentation/work_widgets.dart'
    show WorkSectionHeader;

/// Вкладка «Самопроверка»: жив ли движок, какие проверки приняты и какие
/// нет (и почему), настроен ли Telegram, очередь сообщений и кнопка
/// «Отправить тест». Токен и chat id клиенту не известны: он видит только
/// «настроено / нет» и коды ошибок.
class SelfCheckTab extends ConsumerStatefulWidget {
  const SelfCheckTab({super.key});

  @override
  ConsumerState<SelfCheckTab> createState() => _SelfCheckTabState();
}

class _SelfCheckTabState extends ConsumerState<SelfCheckTab> {
  String? _notice;
  ActionOutcome _noticeOutcome = ActionOutcome.done;

  Future<void> _test() async {
    final result = await ref.read(telegramTestProvider.notifier).send();
    if (!mounted) return;
    setState(() {
      _noticeOutcome = result.outcome;
      _notice = result.ok
          ? 'Тестовое сообщение отправлено: проверьте Telegram.'
          : result.message;
    });
    if (result.ok) ref.invalidate(selfCheckProvider);
  }

  @override
  Widget build(BuildContext context) {
    final check = ref.watch(selfCheckProvider);
    return check.when(
      loading: () => const ListSkeleton(),
      error: (e, _) {
        final offline = e is ApiException && e.isNetwork;
        return offline
            ? NoticeCard(
                key: const Key('self-offline'),
                label: 'Нет связи',
                tone: StatusTone.neutral,
                text:
                    'Самопроверку делает сервер: без связи с ним её не '
                    'показать.',
                actions: [
                  ElevatedButton(
                    key: const Key('self-retry'),
                    onPressed: () => ref.invalidate(selfCheckProvider),
                    child: const Text('Повторить'),
                  ),
                ],
              )
            : NoticeCard(
                key: const Key('self-error'),
                label: 'Не загрузилось',
                tone: StatusTone.danger,
                text: monitoringErrorText(e),
                actions: [
                  FilledButton(
                    key: const Key('self-retry'),
                    onPressed: () => ref.invalidate(selfCheckProvider),
                    child: const Text('Повторить'),
                  ),
                ],
              );
      },
      data: _body,
    );
  }

  Widget _body(SelfCheck s) {
    final now = ref.watch(clockProvider)();
    final data = ref.watch(monitorDataProvider).value;
    final sending = ref.watch(telegramTestProvider);
    // Без сети тест уйти не может: как «Проверить сейчас» на дашборде.
    final online = ref.watch(syncStatusProvider.select((st) => st.online));
    final c = context.colors;
    final t = context.text;
    final polled = parseMoment(s.lastPollAt);
    final (engineLabel, engineTone) = !s.engineConfigured
        ? ('Не подключён', StatusTone.warning)
        : (s.engineError != null || (s.lagSeconds ?? 0) > 60 || polled == null)
        ? ('Не отвечает', StatusTone.danger)
        : ('Работает', StatusTone.success);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const WorkSectionHeader(title: 'Движок проверок'),
        AppCard(
          key: const Key('self-engine'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StatusPill(label: engineLabel, tone: engineTone),
              const SizedBox(height: AppSpacing.s2),
              Text(
                !s.engineConfigured
                    ? 'На сервере не задан адрес движка: проверки не '
                          'запускаются.'
                    : polled == null
                    ? 'Опросов движка ещё не было.'
                    : 'Последний опрос: ${formatMoment(polled, now)}.',
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
              if (s.engineError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Ошибка: ${s.engineError}',
                    key: const Key('self-engine-error'),
                    style: t.caption.copyWith(color: c.textTertiary),
                  ),
                ),
            ],
          ),
        ),
        const WorkSectionHeader(title: 'Конфигурация'),
        AppCard(
          key: const Key('self-config'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Проверок в работе: ${s.checksActive}', style: t.bodyStrong),
              if (s.configSyncedAt != null)
                Text(
                  'Конфигурация обновлена: '
                  '${_moment(s.configSyncedAt, now)}.',
                  style: t.bodyS.copyWith(color: c.textSecondary),
                ),
              if (s.rejected.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s1),
                  child: Text(
                    'Отклонённых проверок нет.',
                    style: t.bodyS.copyWith(color: c.textSecondary),
                  ),
                )
              else ...[
                const SizedBox(height: AppSpacing.s2),
                Text(
                  'Не запускаются: ${s.rejected.length}',
                  style: t.bodyStrong,
                ),
                for (final r in s.rejected)
                  Padding(
                    key: Key('self-rejected-${r.checkId}'),
                    padding: const EdgeInsets.only(top: AppSpacing.s1),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          LucideIcons.triangleAlert,
                          size: 14,
                          color: c.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${_checkName(data, r.checkId)}: '
                            '${problemText(r.reason)}',
                            style: t.caption.copyWith(color: c.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
        const WorkSectionHeader(title: 'Telegram'),
        AppCard(
          key: const Key('self-telegram'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StatusPill(
                label: s.telegramConfigured ? 'Настроен' : 'Не настроен',
                tone: s.telegramConfigured
                    ? StatusTone.success
                    : StatusTone.warning,
              ),
              const SizedBox(height: AppSpacing.s2),
              Text(
                s.telegramLastSuccessAt == null
                    ? 'Сообщений ещё не отправлялось.'
                    : 'Последнее сообщение: '
                          '${_moment(s.telegramLastSuccessAt, now)}.',
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
              Text(
                s.queued == 0
                    ? 'Очередь пуста.'
                    : 'В очереди: ${s.queued} '
                          '${pluralRu(s.queued, 'сообщение', 'сообщения', 'сообщений')}.',
                key: const Key('self-queue'),
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
              if (s.telegramLastError != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s1),
                  child: Text(
                    telegramErrorText(s.telegramLastError),
                    key: const Key('self-telegram-error'),
                    style: t.bodyS.copyWith(color: c.danger),
                  ),
                ),
              const SizedBox(height: AppSpacing.s3),
              ElevatedButton.icon(
                key: const Key('telegram-test'),
                onPressed: s.telegramConfigured && !sending && online
                    ? _test
                    : null,
                icon: sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(LucideIcons.send, size: 16),
                label: const Text('Отправить тестовое сообщение'),
              ),
              if (s.telegramConfigured && !online)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s2),
                  child: Text(
                    'Нет связи с сервером: тест недоступен.',
                    key: const Key('self-telegram-offline'),
                    style: t.caption.copyWith(color: c.textTertiary),
                  ),
                ),
              if (!s.telegramConfigured)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s2),
                  child: Text(
                    telegramErrorText('not_configured'),
                    key: const Key('self-telegram-not-configured'),
                    style: t.caption.copyWith(color: c.textTertiary),
                  ),
                ),
              if (_notice != null) ...[
                const SizedBox(height: AppSpacing.s2),
                PulseBanner(
                  key: const Key('telegram-notice'),
                  icon: _noticeOutcome == ActionOutcome.done
                      ? LucideIcons.check
                      : LucideIcons.info,
                  text: _notice!,
                  // Красный — только сбой; лимит и «подождите» — обычная
                  // подсказка.
                  danger:
                      _noticeOutcome == ActionOutcome.failed ||
                      _noticeOutcome == ActionOutcome.offline,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  static String _moment(String? iso, DateTime now) {
    final t = parseMoment(iso);
    return t == null ? '—' : formatMoment(t, now);
  }

  static String _checkName(MonitorData? data, String checkId) {
    final check = data?.checkById[checkId];
    if (check == null) return 'Проверка';
    final service = data?.serviceById[check.serviceId];
    return service == null ? check.name : '${service.name} · ${check.name}';
  }
}
