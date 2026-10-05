import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/widgets/app_chips.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/monitoring/presentation/incidents_tab.dart';
import 'package:my_tasker/features/monitoring/presentation/monitoring_editors.dart';
import 'package:my_tasker/features/monitoring/presentation/pulse_dashboard.dart';
import 'package:my_tasker/features/monitoring/presentation/self_check_tab.dart';
import 'package:my_tasker/features/monitoring/presentation/servers_tab.dart';

/// Вкладки экрана «Серверы» (02, 5.5). «Бэкапы» не входят в Этап 9.
enum PulseTab {
  dashboard('Дашборд'),
  servers('Серверы'),
  incidents('Инциденты'),
  selfCheck('Самопроверка');

  const PulseTab(this.label);

  final String label;
}

/// «Работа › Серверы»: дашборд «Пульс» (статус, доступность, отклик,
/// инциденты), серверы заказчика и самопроверка мониторинга с Telegram.
/// Приложение серверами **не управляет**, только наблюдает: кнопки
/// «Выключить» нет.
class PulseScreen extends StatefulWidget {
  const PulseScreen({super.key});

  @override
  State<PulseScreen> createState() => _PulseScreenState();
}

class _PulseScreenState extends State<PulseScreen> {
  PulseTab _tab = PulseTab.dashboard;

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      key: const Key('pulse-screen'),
      title: 'Серверы',
      parentLabel: 'Работа',
      onBack: () => context.go('/work'),
      actions: [
        IconButton(
          key: const Key('pulse-add-server'),
          tooltip: 'Добавить сервер',
          onPressed: () => showServerEditor(context),
          icon: const Icon(LucideIcons.plus, size: 22),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChipRow(
            children: [
              for (final tab in PulseTab.values)
                FilterPill(
                  key: Key('pulse-tab-${tab.name}'),
                  label: tab.label,
                  selected: _tab == tab,
                  onTap: () => setState(() => _tab = tab),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          switch (_tab) {
            PulseTab.dashboard => const PulseDashboard(),
            PulseTab.servers => const ServersManageTab(),
            PulseTab.incidents => const IncidentsTab(),
            PulseTab.selfCheck => const SelfCheckTab(),
          },
        ],
      ),
    );
  }
}
