import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/money/money.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/form_text_field.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/ai_chat/application/ai_providers.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_format.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_protocol.dart';
import 'package:my_tasker/features/settings/data/user_settings_repository.dart';

/// «Расход и лимит»: траты за месяц в рублях, по моделям, месячный лимит.
class UsageScreen extends ConsumerStatefulWidget {
  const UsageScreen({super.key});

  @override
  ConsumerState<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends ConsumerState<UsageScreen> {
  final TextEditingController _limit = TextEditingController();
  String? _month;
  String? _error;
  bool _limitLoaded = false;

  @override
  void dispose() {
    _limit.dispose();
    super.dispose();
  }

  Future<void> _saveLimit(String month) async {
    final kopecks = tryParseAmount(_limit.text);
    if (kopecks == null || kopecks < 0) {
      setState(() => _error = 'Введите сумму в рублях, например 500');
      return;
    }
    setState(() => _error = null);
    await ref
        .read(userSettingsRepositoryProvider)
        .set(monthlyLimitKey, kopecks);
    await _refreshAfterSync(month);
  }

  Future<void> _removeLimit(String month) async {
    _limit.clear();
    setState(() => _error = null);
    await ref.read(userSettingsRepositoryProvider).remove(monthlyLimitKey);
    await _refreshAfterSync(month);
  }

  /// Сервер проверяет лимит по своим данным: отправляем настройку и
  /// перечитываем расход.
  Future<void> _refreshAfterSync(String month) async {
    try {
      await ref.read(syncEngineProvider).runCycle();
    } on Object {
      // Лимит сохранён локально и уйдёт при следующей синхронизации.
    }
    if (mounted) ref.invalidate(usageProvider(month));
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(billingMonthProvider);
    final month = _month ?? current;
    final usage = ref.watch(usageProvider(month));
    final limit = ref.watch(monthlyLimitProvider).value;
    final c = context.colors;
    final t = context.text;
    if (!_limitLoaded && ref.watch(monthlyLimitProvider).hasValue) {
      _limitLoaded = true;
      if (limit != null) _limit.text = rublesInput(limit);
    }
    return ScreenScaffold(
      title: 'Расход и лимит',
      parentLabel: 'Настройки ИИ',
      onBack: () => context.go('/ai/settings'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                key: const Key('usage-prev'),
                tooltip: 'Предыдущий месяц',
                onPressed: () => setState(() => _month = shiftMonth(month, -1)),
                icon: const Icon(LucideIcons.chevronLeft, size: 22),
              ),
              Text(
                monthLabel(month),
                key: const Key('usage-month'),
                style: t.h3,
              ),
              IconButton(
                key: const Key('usage-next'),
                tooltip: 'Следующий месяц',
                onPressed: month == current
                    ? null
                    : () => setState(() => _month = shiftMonth(month, 1)),
                icon: const Icon(LucideIcons.chevronRight, size: 22),
              ),
            ],
          ),
          usage.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(AppSpacing.s8),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, _) => AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Не удалось загрузить расход: нет связи с сервером.',
                    key: const Key('usage-error'),
                    style: t.body,
                  ),
                  const SizedBox(height: AppSpacing.s3),
                  OutlinedButton(
                    key: const Key('usage-retry'),
                    onPressed: () => ref.invalidate(usageProvider(month)),
                    child: const Text('Повторить'),
                  ),
                ],
              ),
            ),
            data: (u) => _Summary(usage: u, limit: limit),
          ),
          const SizedBox(height: AppSpacing.s6),
          Text(
            'МЕСЯЧНЫЙ ЛИМИТ',
            style: t.overline.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: AppSpacing.s2),
          Row(
            children: [
              Expanded(
                child: FormTextField(
                  key: const Key('limit-field'),
                  controller: _limit,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Без лимита',
                    suffixText: '₽',
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              ElevatedButton(
                key: const Key('limit-save'),
                onPressed: () => _saveLimit(month),
                child: const Text('Сохранить'),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s2),
              child: Text(
                _error!,
                key: const Key('limit-error'),
                style: t.bodyS.copyWith(color: c.danger),
              ),
            ),
          if (limit != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('limit-remove'),
                onPressed: () => _removeLimit(month),
                child: const Text('Снять лимит'),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s2),
            child: Text(
              'Сервер блокирует запрос, когда расход за месяц дошёл до лимита. '
              '0 ₽ блокирует всё.',
              style: t.caption.copyWith(color: c.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.usage, required this.limit});

  final UsageSummary usage;

  /// Лимит из настроек (локальный); при гонке с сервером главнее он.
  final int? limit;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final effective = limit ?? usage.limitKopecks;
    final share = effective == null
        ? null
        : (effective == 0 ? 1.0 : usage.spentKopecks / effective);
    final warn = share != null && share >= 0.8;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatCost(usage.spentKopecks),
            key: const Key('usage-total'),
            style: t.display,
          ),
          Text(
            effective == null
                ? 'потрачено за месяц · лимита нет'
                : 'потрачено из ${formatCost(effective)}',
            style: t.bodyS.copyWith(color: c.textSecondary),
          ),
          if (share != null) ...[
            const SizedBox(height: AppSpacing.s3),
            ClipRRect(
              borderRadius: AppRadii.borderFull,
              child: LinearProgressIndicator(
                key: const Key('usage-bar'),
                value: share.clamp(0, 1),
                minHeight: 6,
                backgroundColor: c.surface3,
                color: warn ? c.surfaceInverse : c.accent,
              ),
            ),
            if (warn)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.s2),
                child: Text(
                  share >= 1
                      ? 'Лимит исчерпан: новые запросы блокируются.'
                      : 'Израсходовано более 80 % лимита.',
                  key: const Key('usage-warning-text'),
                  style: t.bodyS.copyWith(
                    color: share >= 1 ? c.danger : c.textSecondary,
                  ),
                ),
              ),
          ],
          const SizedBox(height: AppSpacing.s3),
          Text(
            '${formatCount(usage.requests)} '
            '${_requests(usage.requests)} · '
            '${formatCount(usage.promptTokens + usage.completionTokens)} ток.',
            key: const Key('usage-requests'),
            style: t.bodyS.copyWith(color: c.textSecondary),
          ),
          if (usage.byModel.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s3),
            for (final m in usage.byModel)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.s1),
                child: Row(
                  key: Key('usage-model-${m.model}'),
                  children: [
                    Expanded(
                      child: Text(
                        m.model,
                        style: t.bodyS,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(formatCost(m.costKopecks), style: t.numS),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  String _requests(int n) {
    final mod100 = n % 100;
    final mod10 = n % 10;
    if (mod100 >= 11 && mod100 <= 14) return 'запросов';
    if (mod10 == 1) return 'запрос';
    if (mod10 >= 2 && mod10 <= 4) return 'запроса';
    return 'запросов';
  }
}
