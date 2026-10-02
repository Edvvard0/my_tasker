import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/db/database_bootstrap.dart';
import 'package:my_tasker/core/layout/window_class.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';

/// Экран восстановления: локальная БД существует, но не открывается
/// (ключ шифрования потерян или не подходит). Вместо падения предлагает
/// сбросить локальные данные и загрузить их заново с сервера.
class RecoveryScreen extends ConsumerStatefulWidget {
  const RecoveryScreen({required this.failure, super.key});

  final DatabaseFailureKind failure;

  @override
  ConsumerState<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends ConsumerState<RecoveryScreen> {
  bool _resetting = false;
  bool _failed = false;

  Future<void> _reset() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Сбросить локальные данные?',
      message:
          'Всё, что не успело отправиться на сервер, будет потеряно. '
          'Остальное загрузится заново после входа.',
      confirmLabel: 'Сбросить',
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() {
      _resetting = true;
      _failed = false;
    });
    try {
      await ref.read(localDataResetProvider)();
    } on Object {
      if (mounted) {
        setState(() {
          _resetting = false;
          _failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    final c = context.colors;
    final canReset = widget.failure != DatabaseFailureKind.schemaTooNew;
    final (title, text) = switch (widget.failure) {
      DatabaseFailureKind.unreadable => (
        'Не удалось открыть локальные данные',
        'База на этом устройстве зашифрована, а ключ шифрования не найден '
            'или не подходит — так бывает после переустановки или сброса '
            'хранилища системы. Данные можно загрузить заново с сервера.',
      ),
      DatabaseFailureKind.schemaTooNew => (
        'Данные созданы более новой версией',
        'Эта версия приложения не умеет читать локальные данные. Обнови '
            'приложение — сбрасывать ничего не нужно.',
      ),
      DatabaseFailureKind.other => (
        'Не удалось открыть локальные данные',
        'Не получилось прочитать файл с данными. Повтори попытку; если '
            'ошибка не уходит, данные можно загрузить заново с сервера.',
      ),
    };
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(context.windowClass.gutter),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                key: const Key('recovery'),
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    LucideIcons.shieldAlert,
                    size: 32,
                    color: c.textTertiary,
                  ),
                  const SizedBox(height: AppSpacing.s3),
                  Text(title, style: t.h2, textAlign: TextAlign.center),
                  const SizedBox(height: AppSpacing.s2),
                  Text(
                    text,
                    style: t.body.copyWith(color: c.textSecondary),
                    textAlign: TextAlign.center,
                  ),
                  if (_failed) ...[
                    const SizedBox(height: AppSpacing.s3),
                    Text(
                      'Сбросить не получилось. Повтори попытку.',
                      key: const Key('recovery-error'),
                      style: t.bodyS.copyWith(color: c.danger),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: AppSpacing.s6),
                  if (_resetting)
                    Center(
                      child: CircularProgressIndicator(
                        key: const Key('recovery-progress'),
                        color: c.textSecondary,
                      ),
                    )
                  else ...[
                    // Сначала безобидное: повтор открытия (ключ хранилища
                    // системы бывает временно недоступен).
                    FilledButton(
                      key: const Key('recovery-retry'),
                      onPressed: ref.read(localDataRetryProvider),
                      child: const Text('Повторить'),
                    ),
                    if (canReset) ...[
                      const SizedBox(height: AppSpacing.s6),
                      Text(
                        'Если повтор не помогает',
                        style: t.bodyStrong,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: AppSpacing.s2),
                      const AppCard(
                        key: Key('recovery-warning'),
                        child: Text(
                          'Сброс удалит базу на этом устройстве вместе с '
                          'ключом шифрования и загрузит данные с сервера '
                          'заново. Изменения, которые не успели отправиться, '
                          'будут потеряны. После сброса нужно снова указать '
                          'сервер и войти.',
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s3),
                      ElevatedButton(
                        key: const Key('recovery-reset'),
                        onPressed: _reset,
                        child: const Text(
                          'Сбросить локальные данные и загрузить с сервера',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
