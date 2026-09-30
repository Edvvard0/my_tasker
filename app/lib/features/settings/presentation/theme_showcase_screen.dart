import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_colors.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';

/// «Настройки › Внешний вид»: справочник дизайн-токенов (цвета, шрифты,
/// радиусы, кнопки, статусы). Служит и витриной для golden-тестов темы.
class ThemeShowcaseScreen extends StatelessWidget {
  const ThemeShowcaseScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      title: 'Внешний вид',
      parentLabel: 'Настройки',
      onBack: () => context.go('/settings'),
      child: const ThemeShowcase(),
    );
  }
}

/// Содержимое справочника (без каркаса экрана).
class ThemeShowcase extends StatelessWidget {
  const ThemeShowcase({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Column(
      key: const Key('theme-showcase'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Section(
          title: 'Поверхности',
          child: Wrap(
            spacing: AppSpacing.s2,
            runSpacing: AppSpacing.s2,
            children: [
              _Swatch('bg/base', c.bgBase),
              _Swatch('surface/1', c.surface1),
              _Swatch('surface/2', c.surface2),
              _Swatch('surface/3', c.surface3),
              _Swatch('surface/4', c.surface4),
              _Swatch('inverse', c.surfaceInverse, dark: false),
            ],
          ),
        ),
        _Section(
          title: 'Акцент и исключение',
          child: Wrap(
            spacing: AppSpacing.s2,
            runSpacing: AppSpacing.s2,
            children: [
              _Swatch('accent', c.accent),
              _Swatch('danger', c.danger, dark: false),
            ],
          ),
        ),
        _Section(
          title: 'Серые ряды и heatmap',
          child: Wrap(
            spacing: AppSpacing.s2,
            runSpacing: AppSpacing.s2,
            children: [
              for (final color in AppColors.heat)
                Container(
                  width: 44,
                  height: 24,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: AppRadii.borderFull,
                  ),
                ),
              Container(
                width: 44,
                height: 24,
                decoration: BoxDecoration(
                  borderRadius: AppRadii.borderFull,
                  border: Border.all(color: c.accent, width: 2),
                ),
              ),
            ],
          ),
        ),
        _Section(
          title: 'Типографика',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('359,7к', style: t.display),
              Text('205 000 ₽', style: t.kpi),
              Text('Заголовок экрана', style: t.h1),
              Text('Заголовок секции', style: t.h2),
              Text('Заголовок карточки', style: t.h3),
              Text('Основной текст задачи или сообщения', style: t.body),
              Text(
                'Метаданные и подписи',
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
              Text(
                'ДОСТУПНОСТЬ',
                style: t.overline.copyWith(color: c.textTertiary),
              ),
              Text('1 249,90 ₽  ·  01:12:43  ·  178 мс', style: t.numL),
              Text('https://203.0.113.10:443', style: t.numS),
            ],
          ),
        ),
        _Section(
          title: 'Кнопки',
          child: Wrap(
            spacing: AppSpacing.s3,
            runSpacing: AppSpacing.s3,
            children: [
              FilledButton(onPressed: () {}, child: const Text('Сохранить')),
              ElevatedButton(onPressed: () {}, child: const Text('Проверить')),
              OutlinedButton(onPressed: () {}, child: const Text('Импорт')),
              TextButton(onPressed: () {}, child: const Text('Все 8 →')),
              const FilledButton(onPressed: null, child: Text('Недоступно')),
            ],
          ),
        ),
        const _Section(
          title: 'Статусы',
          child: Wrap(
            spacing: AppSpacing.s2,
            runSpacing: AppSpacing.s2,
            children: [
              StatusPill(label: 'Работает', tone: StatusTone.success),
              StatusPill(label: 'Частично 30%', tone: StatusTone.warning),
              StatusPill(label: 'Лежит', tone: StatusTone.danger),
              StatusPill(label: 'ИИ предлагает', tone: StatusTone.info),
            ],
          ),
        ),
        _Section(
          title: 'Радиусы и иконки',
          child: Wrap(
            spacing: AppSpacing.s3,
            runSpacing: AppSpacing.s3,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final r in const [
                AppRadii.xs,
                AppRadii.s,
                AppRadii.m,
                AppRadii.l,
                AppRadii.xl,
              ])
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: c.surface3,
                    borderRadius: BorderRadius.circular(r),
                  ),
                ),
              Icon(LucideIcons.sun, color: c.textSecondary),
              Icon(LucideIcons.wallet, color: c.textSecondary),
              Icon(LucideIcons.moon, color: c.textSecondary),
              Icon(LucideIcons.sparkles, color: c.textSecondary),
            ],
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: context.text.overline.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: AppSpacing.s2),
          child,
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch(this.label, this.color, {this.dark = true});

  final String label;
  final Color color;

  /// Светлый ли текст подписи (для тёмных плашек).
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 96,
      height: 56,
      padding: const EdgeInsets.all(AppSpacing.s2),
      alignment: Alignment.bottomLeft,
      decoration: BoxDecoration(
        color: color,
        borderRadius: AppRadii.borderM,
        border: Border.all(color: c.borderStrong),
      ),
      child: Text(
        label,
        style: context.text.numS.copyWith(
          color: dark ? c.textPrimary : c.textOnInverse,
        ),
      ),
    );
  }
}
