import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/local_llm/chat_routing.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/local_ai/application/local_ai_providers.dart';

/// «Тест локальной модели» (настройки ИИ): прогон 20 фиксированных русских
/// фраз (10 на создание задачи) и метрики (решение этапа 10, п. 9). Отчёт
/// копируется текстом. Запускается на Galaxy A55 в фазе сборки.
class LocalBenchmarkScreen extends ConsumerWidget {
  const LocalBenchmarkScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.text;
    final c = context.colors;
    final state = ref.watch(benchmarkControllerProvider);
    final availability = ref.watch(localAvailabilityProvider);
    final controller = ref.read(benchmarkControllerProvider.notifier);
    final canRun = availability == LocalAvailability.ready && !state.running;
    final report = state.report;

    return ScreenScaffold(
      title: 'Тест локальной модели',
      parentLabel: 'Офлайн-модель',
      onBack: () =>
          context.canPop() ? context.pop() : context.go('/ai/settings/local'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '20 фиксированных фраз: 10 просьб создать задачу и 10 '
                  'обычных вопросов. Считаем время до первого токена, '
                  'скорость, память, долю корректного JSON и температуру '
                  '(если телефон её отдаёт).',
                  style: t.body,
                ),
                const SizedBox(height: AppSpacing.s2),
                Text(
                  'Тест идёт несколько минут. Подключите зарядку, не '
                  'сворачивайте приложение и не греите телефон заранее.',
                  style: t.bodyS.copyWith(color: c.textSecondary),
                ),
                const SizedBox(height: AppSpacing.s4),
                Wrap(
                  spacing: AppSpacing.s3,
                  runSpacing: AppSpacing.s2,
                  children: [
                    FilledButton(
                      key: const Key('bench-start'),
                      onPressed: canRun ? controller.start : null,
                      child: const Text('Запустить тест'),
                    ),
                    if (state.running && !state.loadingModel)
                      ElevatedButton(
                        key: const Key('bench-stop'),
                        onPressed: controller.stop,
                        child: const Text('Остановить'),
                      ),
                  ],
                ),
                if (availability != LocalAvailability.ready)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.s3),
                    child: Text(
                      availability == LocalAvailability.unsupportedPlatform
                          ? 'Офлайн-модель недоступна на этой платформе.'
                          : 'Сначала скачайте модель в «Офлайн-модель».',
                      key: const Key('bench-unavailable'),
                      style: t.bodyS,
                    ),
                  ),
              ],
            ),
          ),
          if (state.running) ...[
            const SizedBox(height: AppSpacing.s4),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    state.loadingModel
                        ? 'Загружаем модель в память…'
                        : 'Фраза ${state.done + 1} из ${state.total}',
                    key: const Key('bench-progress-text'),
                    style: t.body,
                  ),
                  const SizedBox(height: AppSpacing.s2),
                  LinearProgressIndicator(
                    key: const Key('bench-progress'),
                    value: state.loadingModel || state.total == 0
                        ? null
                        : state.done / state.total,
                  ),
                ],
              ),
            ),
          ],
          if (state.error != null) ...[
            const SizedBox(height: AppSpacing.s4),
            NoticeCard(
              key: const Key('bench-error'),
              label: 'Ошибка',
              tone: StatusTone.danger,
              text: state.error!,
            ),
          ],
          if (report != null) ...[
            const SizedBox(height: AppSpacing.s4),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text('Результат', style: t.h3)),
                      FilledButton.icon(
                        key: const Key('bench-copy'),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: report.toText()),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Отчёт скопирован')),
                            );
                          }
                        },
                        icon: const Icon(LucideIcons.copy, size: 16),
                        label: const Text('Скопировать'),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.s3),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpacing.s3),
                    decoration: BoxDecoration(
                      color: c.surface2,
                      borderRadius: AppRadii.borderM,
                    ),
                    child: SelectableText(
                      report.toText(),
                      key: const Key('bench-report'),
                      style: t.caption,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
