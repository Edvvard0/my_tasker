import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/features/ai_chat/presentation/settings/ai_settings_screen.dart'
    show AiSettingsTile;

/// Строка «Офлайн-модель» для экрана «Настройки ИИ» (этап 3 вставляет её
/// одной строкой рядом с остальными):
///
/// ```dart
/// const LocalAiSettingsTile()
/// ```
///
/// Ведёт на экран моделей `/ai/settings/local`, откуда доступен «Тест
/// локальной модели».
class LocalAiSettingsTile extends StatelessWidget {
  const LocalAiSettingsTile({super.key});

  @override
  Widget build(BuildContext context) => AiSettingsTile(
    key: const Key('ai-settings-local'),
    icon: LucideIcons.smartphone,
    title: 'Офлайн-модель',
    subtitle: 'Ответы без сети на телефоне, загрузка и тест модели',
    onTap: () => context.go('/ai/settings/local'),
  );
}
