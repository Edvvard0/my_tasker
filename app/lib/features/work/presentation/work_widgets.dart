import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/work/application/work_providers.dart';
import 'package:my_tasker/features/work/domain/work_models.dart';

/// Назад из экрана «Работы»: на шаг назад, а при прямом входе — в «Работу».
void workBack(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go('/work');
  }
}

/// Красная карточка «Не загрузилось» с кнопкой «Повторить», которая
/// пересоздаёт все потоки «Работы».
class WorkErrorCard extends ConsumerWidget {
  const WorkErrorCard({
    required this.text,
    this.retryKey = const Key('work-retry'),
    super.key,
  });

  final String text;
  final Key retryKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) => NoticeCard(
    label: 'Не загрузилось',
    tone: StatusTone.danger,
    text: text,
    actions: [
      FilledButton(
        key: retryKey,
        onPressed: () => retryWorkData(ref),
        child: const Text('Повторить'),
      ),
    ],
  );
}

/// Тон статус-пилюли проекта (02, 4.6): монохром, без цветов статусов.
StatusTone projectTone(ProjectStatus status) => switch (status) {
  ProjectStatus.active => StatusTone.success,
  ProjectStatus.paused => StatusTone.warning,
  ProjectStatus.lead => StatusTone.neutral,
  ProjectStatus.completed => StatusTone.neutral,
  ProjectStatus.cancelled => StatusTone.neutral,
};

StatusTone changeRequestTone(ChangeRequestStatus status) => switch (status) {
  ChangeRequestStatus.inProgress => StatusTone.success,
  ChangeRequestStatus.closed => StatusTone.neutral,
  ChangeRequestStatus.cancelled => StatusTone.neutral,
};

/// Карточка-метрика (02, 4.1): подпись `overline`, крупная цифра, пояснение.
/// Цифра сжимается по ширине, а не обрезается.
class KpiTile extends StatelessWidget {
  const KpiTile({
    required this.label,
    required this.value,
    this.caption,
    this.onTap,
    super.key,
  });

  final String label;
  final String value;
  final String? caption;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final tile = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s3,
      ),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: AppRadii.borderL,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            style: t.overline.copyWith(color: c.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.s1),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: t.kpi),
          ),
          if (caption != null) ...[
            const SizedBox(height: 2),
            Text(
              caption!,
              style: t.caption.copyWith(color: c.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return tile;
    return Semantics(
      button: true,
      label: '$label: $value',
      excludeSemantics: true,
      child: InkWell(borderRadius: AppRadii.borderL, onTap: onTap, child: tile),
    );
  }
}

/// Ряд карточек-метрик одинаковой ширины.
class KpiRow extends StatelessWidget {
  const KpiRow({required this.tiles, super.key});

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const SizedBox(width: AppSpacing.s2),
            Expanded(child: tiles[i]),
          ],
        ],
      ),
    );
  }
}

/// Мини-прогресс оплаты: серая дорожка и белая заливка (02, 5.4.1). Доля
/// в сотых долях процента; переплата заполняет дорожку целиком.
class PaidBar extends StatelessWidget {
  const PaidBar({required this.basisPoints, this.height = 6, super.key});

  final int basisPoints;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fraction = (basisPoints.clamp(0, 10000)) / 10000;
    return ClipRRect(
      borderRadius: AppRadii.borderFull,
      child: SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (context, box) => Stack(
            children: [
              Positioned.fill(child: ColoredBox(color: c.surface3)),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: box.maxWidth * fraction,
                child: ColoredBox(color: c.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Заголовок раздела: `overline` слева и необязательное действие справа.
class WorkSectionHeader extends StatelessWidget {
  const WorkSectionHeader({required this.title, this.trailing, super.key});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s5, bottom: AppSpacing.s2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: context.text.overline.copyWith(color: c.textSecondary),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Аватар-инициалы в круге `surface/3`.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({required this.name, this.size = 40, super.key});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final trimmed = name.trim();
    final initial = trimmed.isEmpty ? '?' : trimmed.characters.first;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.surface3, shape: BoxShape.circle),
      child: Text(
        initial.toUpperCase(),
        style: context.text.bodyStrong.copyWith(color: c.textPrimary),
      ),
    );
  }
}

/// Строка-ссылка внутри карточки (иконка, подпись, шеврон).
class WorkLinkRow extends StatelessWidget {
  const WorkLinkRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailingText,
    super.key,
  });

  final IconData icon;
  final String label;
  final String? trailingText;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadii.borderL,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4,
          vertical: AppSpacing.s3,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: c.textSecondary),
            const SizedBox(width: AppSpacing.s3),
            Expanded(child: Text(label, style: t.body)),
            if (trailingText != null)
              Text(
                trailingText!,
                style: t.caption.copyWith(color: c.textTertiary),
              ),
            const SizedBox(width: AppSpacing.s2),
            Icon(LucideIcons.chevronRight, size: 18, color: c.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// Предупреждение внутри карточки (нарушение целостности, два таймера).
class WorkWarning extends StatelessWidget {
  const WorkWarning({required this.text, this.actions = const [], super.key});

  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.triangleAlert, size: 18, color: c.textPrimary),
              const SizedBox(width: AppSpacing.s2),
              Expanded(child: Text(text, style: t.bodyS)),
            ],
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s3),
            Wrap(
              spacing: AppSpacing.s2,
              runSpacing: AppSpacing.s2,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }
}
