import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/banks/application/setup_providers.dart';
import 'package:my_tasker/features/banks/domain/bank_data.dart';
import 'package:my_tasker/features/banks/platform/bank_platform.dart';
import 'package:my_tasker/features/banks/presentation/banks_widgets.dart';
import 'package:my_tasker/features/finance/presentation/finance_widgets.dart';

/// Онбординг уведомлений банков (только Android): доступ к уведомлениям
/// и исключение из оптимизации батареи (с инструкцией для Samsung One UI —
/// без него система «усыпляет» слушатель, и часть уведомлений теряется).
class BankSetupScreen extends ConsumerStatefulWidget {
  const BankSetupScreen({super.key});

  @override
  ConsumerState<BankSetupScreen> createState() => _BankSetupScreenState();
}

class _BankSetupScreenState extends ConsumerState<BankSetupScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Вернулись из системных настроек: перечитываем статусы.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  void _refresh() => ref
    ..invalidate(listenerEnabledProvider)
    ..invalidate(batteryExemptProvider);

  @override
  Widget build(BuildContext context) {
    final platform = ref.watch(bankPlatformProvider);
    final rules = ref.watch(bankDataProvider).value?.notifications;
    return ScreenScaffold(
      key: const Key('bank-setup-screen'),
      title: 'Уведомления банков',
      parentLabel: 'Банки',
      onBack: () => financeBack(context),
      child: !platform.isSupported
          ? const NoticeCard(
              key: Key('setup-unsupported'),
              label: 'Только Android',
              tone: StatusTone.neutral,
              text:
                  'Читать уведомления банков умеет только приложение на '
                  'Android. На этом устройстве доступны импорт выписки, '
                  'черновики и сверка баланса.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _AccessStep(platform: platform),
                const SizedBox(height: AppSpacing.s3),
                _BatteryStep(platform: platform),
                const SizedBox(height: AppSpacing.s3),
                _PrivacyStep(rules: rules),
              ],
            ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.number,
    required this.title,
    required this.ok,
    required this.okLabel,
    required this.todoLabel,
    required this.children,
    super.key,
  });

  final int number;
  final String title;
  final bool? ok;
  final String okLabel;
  final String todoLabel;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('$number. $title', style: t.h3)),
              if (ok != null)
                StatusPill(
                  label: ok! ? okLabel : todoLabel,
                  tone: ok! ? StatusTone.success : StatusTone.warning,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          ...children,
        ],
      ),
    );
  }
}

class _AccessStep extends ConsumerWidget {
  const _AccessStep({required this.platform});

  final BankPlatform platform;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(listenerEnabledProvider).value;
    return _StepCard(
      key: const Key('setup-access'),
      number: 1,
      title: 'Доступ к уведомлениям',
      ok: enabled,
      okLabel: 'Выдан',
      todoLabel: 'Не выдан',
      children: [
        Text(
          'Приложение читает только уведомления банков из списка ниже. '
          'Остальные уведомления не читаются и не сохраняются.',
          style: context.text.bodyS,
        ),
        const SizedBox(height: AppSpacing.s3),
        const StepNote(
          icon: LucideIcons.settings,
          text:
              'Откройте экран доступа и включите переключатель «My Tasker». '
              'Android предупредит, что приложение сможет читать '
              'уведомления: это нужно для распознавания операций.',
        ),
        const StepNote(
          icon: LucideIcons.smartphone,
          text:
              'Если переключатель недоступен (Android 13+, приложение '
              'установлено не из магазина): Настройки → Приложения → '
              'My Tasker → меню ⋮ → «Разрешить ограниченные настройки», '
              'затем повторите.',
        ),
        Wrap(
          spacing: AppSpacing.s2,
          children: [
            FilledButton(
              key: const Key('setup-open-access'),
              onPressed: () => unawaited(platform.openListenerSettings()),
              child: const Text('Открыть настройки доступа'),
            ),
            OutlinedButton(
              key: const Key('setup-recheck'),
              onPressed: () => ref.invalidate(listenerEnabledProvider),
              child: const Text('Проверить'),
            ),
          ],
        ),
      ],
    );
  }
}

class _BatteryStep extends ConsumerWidget {
  const _BatteryStep({required this.platform});

  final BankPlatform platform;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exempt = ref.watch(batteryExemptProvider).value;
    return _StepCard(
      key: const Key('setup-battery'),
      number: 2,
      title: 'Батарея: без ограничений',
      ok: exempt,
      okLabel: 'Без ограничений',
      todoLabel: 'Ограничено',
      children: [
        Text(
          'Samsung One UI усыпляет фоновые службы: тогда уведомления банков '
          'приходят, а приложение их не видит. Снимите ограничения:',
          style: context.text.bodyS,
        ),
        const SizedBox(height: AppSpacing.s3),
        const StepNote(
          icon: LucideIcons.battery,
          text:
              'Настройки → Приложения → My Tasker → Батарея → выберите '
              '«Без ограничений».',
        ),
        const StepNote(
          icon: LucideIcons.batteryCharging,
          text:
              'Настройки → Обслуживание устройства (или «Аккумулятор») → '
              'Батарея → «Фоновые ограничения» → «Никогда не спящие '
              'приложения» → добавьте My Tasker.',
        ),
        const StepNote(
          icon: LucideIcons.ban,
          text:
              'Там же отключите «Переводить неиспользуемые приложения в '
              'спящий режим» и «Автоматическая оптимизация», если они '
              'включены.',
        ),
        Wrap(
          spacing: AppSpacing.s2,
          children: [
            FilledButton(
              key: const Key('setup-open-battery'),
              onPressed: () => unawaited(platform.openBatterySettings()),
              child: const Text('Открыть настройки батареи'),
            ),
            OutlinedButton(
              key: const Key('setup-recheck-battery'),
              onPressed: () => ref.invalidate(batteryExemptProvider),
              child: const Text('Проверить'),
            ),
          ],
        ),
      ],
    );
  }
}

class _PrivacyStep extends StatelessWidget {
  const _PrivacyStep({required this.rules});

  final NotificationRules? rules;

  @override
  Widget build(BuildContext context) {
    final banks = rules?.banks ?? const <BankRules>[];
    return _StepCard(
      key: const Key('setup-privacy'),
      number: 3,
      title: 'Что читается и где хранится',
      ok: null,
      okLabel: '',
      todoLabel: '',
      children: [
        for (final b in banks)
          StepNote(
            icon: LucideIcons.landmark,
            text: '${b.name}: ${b.packages.join(', ')}',
          ),
        const StepNote(
          icon: LucideIcons.lock,
          text:
              'Исходный текст уведомления хранится только на этом '
              'устройстве 30 дней и не отправляется на сервер. На сервер '
              'попадает лишь распознанная операция.',
        ),
        const StepNote(
          icon: LucideIcons.fileSearch,
          text:
              'Имена пакетов приложений банков в стартовом наборе '
              'предварительные: если уведомления не приходят в «Черновики», '
              'сообщите — список обновится вместе с правилами.',
        ),
      ],
    );
  }
}
