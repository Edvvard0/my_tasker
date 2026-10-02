import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/local_llm/model_catalog.dart';
import 'package:my_tasker/core/local_llm/model_manager.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/local_ai/application/local_ai_providers.dart';

/// Подпись и тон статуса модели.
(String, StatusTone) modelStatus(LocalModelState state) =>
    switch (state.phase) {
      LocalModelPhase.ready => ('Скачана', StatusTone.success),
      LocalModelPhase.downloading => (
        state.progress == null
            ? 'Скачивание'
            : 'Скачивание ${(state.progress! * 100).floor()}%',
        StatusTone.info,
      ),
      LocalModelPhase.verifying => ('Проверка', StatusTone.info),
      LocalModelPhase.waitingForNetwork => ('Ждёт Wi-Fi', StatusTone.warning),
      LocalModelPhase.partial => ('Недокачана', StatusTone.warning),
      LocalModelPhase.failed => ('Ошибка', StatusTone.danger),
      LocalModelPhase.notDownloaded => ('Не скачана', StatusTone.neutral),
    };

/// Данные экрана моделей (чистые значения: экран из провайдеров их
/// собирает, golden-тест подставляет напрямую).
class LocalModelsViewData {
  const LocalModelsViewData({
    required this.supported,
    required this.states,
    required this.wifiOnly,
    this.unsupportedReason,
    this.usedBytes = 0,
    this.freeBytes,
    this.totalRamBytes,
    this.availableRamBytes,
  });

  final bool supported;
  final String? unsupportedReason;
  final Map<String, LocalModelState> states;
  final bool wifiOnly;
  final int usedBytes;
  final int? freeBytes;
  final int? totalRamBytes;
  final int? availableRamBytes;
}

/// Действия экрана моделей.
class LocalModelsActions {
  const LocalModelsActions({
    required this.onWifiOnly,
    required this.onDownload,
    required this.onDownloadCellular,
    required this.onPause,
    required this.onDiscardPartial,
    required this.onDelete,
    required this.onBenchmark,
  });

  final ValueChanged<bool> onWifiOnly;
  final ValueChanged<LocalModelSpec> onDownload;
  final ValueChanged<LocalModelSpec> onDownloadCellular;
  final ValueChanged<LocalModelSpec> onPause;
  final ValueChanged<LocalModelSpec> onDiscardPartial;
  final ValueChanged<LocalModelSpec> onDelete;
  final VoidCallback onBenchmark;
}

/// Тело экрана «Офлайн-модель»: платформа, Wi-Fi, место, модели каталога.
class LocalModelsBody extends StatelessWidget {
  const LocalModelsBody({
    required this.data,
    required this.actions,
    this.catalog = localModelCatalog,
    super.key,
  });

  final LocalModelsViewData data;
  final LocalModelsActions actions;
  final List<LocalModelSpec> catalog;

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    final c = context.colors;
    final ram = data.totalRamBytes;
    final free = data.availableRamBytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!data.supported) ...[
          NoticeCard(
            key: const Key('local-unsupported'),
            label: 'Недоступно',
            tone: StatusTone.warning,
            text:
                data.unsupportedReason ??
                'Офлайн-модель работает только на Android.',
          ),
          const SizedBox(height: AppSpacing.s4),
        ],
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Качать только по Wi-Fi', style: t.body),
                        Text(
                          'Модель весит около 2,5 ГБ',
                          style: t.bodyS.copyWith(color: c.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    key: const Key('local-wifi-only'),
                    value: data.wifiOnly,
                    onChanged: actions.onWifiOnly,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s3),
              Text(
                'Занято моделями: ${formatBytes(data.usedBytes)}'
                '${data.freeBytes == null ? '' : ' · свободно: ${formatBytes(data.freeBytes!)}'}',
                key: const Key('local-storage'),
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
              if (ram != null)
                Text(
                  'ОЗУ устройства: ${formatBytes(ram)}'
                  '${free == null ? '' : ', свободно ${formatBytes(free)}'}',
                  key: const Key('local-ram'),
                  style: t.bodyS.copyWith(color: c.textSecondary),
                ),
            ],
          ),
        ),
        for (final spec in catalog) ...[
          const SizedBox(height: AppSpacing.s4),
          _ModelCard(
            spec: spec,
            state: data.states[spec.id] ?? LocalModelState.absent,
            enabled: data.supported,
            actions: actions,
          ),
        ],
      ],
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.spec,
    required this.state,
    required this.enabled,
    required this.actions,
  });

  final LocalModelSpec spec;
  final LocalModelState state;
  final bool enabled;
  final LocalModelsActions actions;

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    final c = context.colors;
    final (label, tone) = modelStatus(state);
    final failure = state.failure;
    final progress = state.progress;
    return AppCard(
      key: Key('local-model-${spec.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.cpu, size: 20, color: c.textSecondary),
              const SizedBox(width: AppSpacing.s3),
              Expanded(child: Text(spec.name, style: t.bodyStrong)),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
          Text(
            '${spec.description} Размер: ${spec.sizeLabel}.',
            style: t.bodyS.copyWith(color: c.textSecondary),
          ),
          Text(
            'Лицензия: ${spec.licenseName}',
            style: t.bodyS.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s3),
          StatusPill(label: label, tone: tone),
          if (state.phase == LocalModelPhase.downloading ||
              state.phase == LocalModelPhase.verifying ||
              state.phase == LocalModelPhase.partial ||
              state.phase == LocalModelPhase.waitingForNetwork) ...[
            const SizedBox(height: AppSpacing.s3),
            LinearProgressIndicator(
              key: const Key('local-progress'),
              value: progress,
            ),
            const SizedBox(height: AppSpacing.s1),
            Text(
              state.phase == LocalModelPhase.verifying
                  ? 'Проверяем контрольную сумму…'
                  : '${formatBytes(state.receivedBytes)}'
                        '${state.totalBytes == null ? '' : ' из ${formatBytes(state.totalBytes!)}'}',
              style: t.caption.copyWith(color: c.textSecondary),
            ),
          ],
          if (state.phase == LocalModelPhase.waitingForNetwork)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s1),
              child: Text(
                'Загрузка продолжится сама, когда появится Wi-Fi.',
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
            ),
          if (failure != null)
            Padding(
              key: const Key('local-failure'),
              padding: const EdgeInsets.only(top: AppSpacing.s3),
              child: Text(failure.message, style: t.bodyS),
            ),
          if (state.isReady) ...[
            const SizedBox(height: AppSpacing.s3),
            _Checksum(spec: spec, state: state),
          ],
          const SizedBox(height: AppSpacing.s4),
          Wrap(
            spacing: AppSpacing.s3,
            runSpacing: AppSpacing.s2,
            children: _buttons(),
          ),
        ],
      ),
    );
  }

  List<Widget> _buttons() {
    if (!enabled) return const [];
    switch (state.phase) {
      case LocalModelPhase.notDownloaded:
        return [
          FilledButton(
            key: const Key('local-download'),
            onPressed: () => actions.onDownload(spec),
            child: Text('Скачать (${spec.sizeLabel})'),
          ),
        ];
      case LocalModelPhase.partial:
      case LocalModelPhase.failed:
        return [
          FilledButton(
            key: const Key('local-resume'),
            onPressed: () => actions.onDownload(spec),
            child: Text(
              state.phase == LocalModelPhase.partial
                  ? 'Продолжить'
                  : 'Повторить',
            ),
          ),
          if (state.receivedBytes > 0)
            ElevatedButton(
              key: const Key('local-discard'),
              onPressed: () => actions.onDiscardPartial(spec),
              child: const Text('Удалить недокачанное'),
            ),
        ];
      case LocalModelPhase.waitingForNetwork:
        return [
          ElevatedButton(
            key: const Key('local-cellular'),
            onPressed: () => actions.onDownloadCellular(spec),
            child: const Text('Скачать по мобильной сети'),
          ),
          ElevatedButton(
            key: const Key('local-pause'),
            onPressed: () => actions.onPause(spec),
            child: const Text('Остановить'),
          ),
        ];
      case LocalModelPhase.downloading:
        return [
          ElevatedButton(
            key: const Key('local-pause'),
            onPressed: () => actions.onPause(spec),
            child: const Text('Пауза'),
          ),
        ];
      case LocalModelPhase.verifying:
        return const [];
      case LocalModelPhase.ready:
        return [
          FilledButton(
            key: const Key('local-benchmark'),
            onPressed: actions.onBenchmark,
            child: const Text('Тест модели'),
          ),
          ElevatedButton(
            key: const Key('local-delete'),
            onPressed: () => actions.onDelete(spec),
            child: const Text('Удалить'),
          ),
        ];
    }
  }
}

class _Checksum extends StatelessWidget {
  const _Checksum({required this.spec, required this.state});

  final LocalModelSpec spec;
  final LocalModelState state;

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    final c = context.colors;
    final hash = state.sha256 ?? '';
    final short = hash.length >= 16 ? hash.substring(0, 16) : hash;
    return Row(
      children: [
        Expanded(
          child: Text(
            spec.isPinned
                ? 'Контрольная сумма совпала с каталогом ($short…)'
                : 'Контрольная сумма $short… не закреплена в каталоге: '
                      'скопируйте и сообщите разработчику',
            key: const Key('local-checksum'),
            style: t.caption.copyWith(color: c.textSecondary),
          ),
        ),
        if (!spec.isPinned)
          IconButton(
            key: const Key('local-copy-sha'),
            tooltip: 'Скопировать SHA-256 и размер',
            onPressed: () => Clipboard.setData(
              ClipboardData(
                text: '${spec.id}\nsha256=$hash\nsize=${state.fileBytes ?? ''}',
              ),
            ),
            icon: const Icon(LucideIcons.copy, size: 18),
          ),
      ],
    );
  }
}

/// Экран «Офлайн-модель» (настройки ИИ): скачать, удалить, место.
class LocalModelsScreen extends ConsumerWidget {
  const LocalModelsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(localLlmEngineProvider);
    final states =
        ref.watch(localModelStatesProvider).value ??
        const <String, LocalModelState>{};
    final info = ref.watch(localDeviceInfoProvider).value;
    final wifiOnly = ref.watch(wifiOnlyProvider).value ?? true;
    final manager = ref.read(localModelManagerProvider);
    final settings = ref.read(setWifiOnlyProvider);

    final data = LocalModelsViewData(
      supported: engine.isSupported,
      unsupportedReason: engine.unsupportedReason,
      states: states,
      wifiOnly: wifiOnly,
      usedBytes: info?.usedBytes ?? 0,
      freeBytes: info?.freeBytes,
      totalRamBytes: info?.totalRamBytes,
      availableRamBytes: info?.availableRamBytes,
    );
    final actions = LocalModelsActions(
      onWifiOnly: settings,
      onDownload: (spec) => manager.start(spec.id),
      onDownloadCellular: (spec) async {
        await manager.pause(spec.id);
        await manager.start(spec.id, allowCellular: true);
      },
      onPause: (spec) => manager.pause(spec.id),
      onDiscardPartial: (spec) async {
        final ok = await showConfirmDialog(
          context,
          title: 'Удалить недокачанное?',
          message:
              'Файл модели ${spec.name} будет удалён, загрузку придётся '
              'начать заново.',
          confirmLabel: 'Удалить',
          danger: true,
        );
        if (ok) await manager.discardPartial(spec.id);
      },
      onDelete: (spec) async {
        final ok = await showConfirmDialog(
          context,
          title: 'Удалить модель?',
          message:
              '${spec.name} (${spec.sizeLabel}) будет удалена с устройства. '
              'Офлайн-чат перестанет работать, пока вы не скачаете её снова.',
          confirmLabel: 'Удалить',
          danger: true,
        );
        if (!ok) return;
        await engine.unload();
        await manager.delete(spec.id);
      },
      onBenchmark: () => context.go('/ai/settings/local/benchmark'),
    );
    return ScreenScaffold(
      title: 'Офлайн-модель',
      parentLabel: 'Настройки ИИ',
      onBack: () =>
          context.canPop() ? context.pop() : context.go('/ai/settings'),
      child: LocalModelsBody(data: data, actions: actions),
    );
  }
}
