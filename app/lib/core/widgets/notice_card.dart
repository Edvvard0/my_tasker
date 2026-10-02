import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';

/// Карточка состояния: пилюля статуса, пояснение и (необязательно) действия.
/// Для сбоев (`StatusTone.danger`) карточка красная (02, `emphasis/danger`).
class NoticeCard extends StatelessWidget {
  const NoticeCard({
    required this.label,
    required this.tone,
    required this.text,
    this.actions = const [],
    this.details,
    super.key,
  });

  final String label;
  final StatusTone tone;
  final String text;

  /// Технические подробности («код для отладки»): скрыты за «Подробнее».
  final String? details;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: StatusPill(label: label, tone: tone),
          ),
          const SizedBox(height: AppSpacing.s3),
          Text(text, style: t.body),
          if (details != null && details!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s1),
            DetailsDisclosure(details!),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s4),
            Wrap(
              spacing: AppSpacing.s3,
              runSpacing: AppSpacing.s2,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }
}

/// «Подробнее»: технический код (`invalid_credentials`, `op_failed`, …)
/// прячется под раскрывашку — человек видит понятный текст, а код остаётся
/// для сообщения об ошибке.
class DetailsDisclosure extends StatefulWidget {
  const DetailsDisclosure(this.details, {super.key});

  final String details;

  @override
  State<DetailsDisclosure> createState() => _DetailsDisclosureState();
}

class _DetailsDisclosureState extends State<DetailsDisclosure> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: const Key('details-toggle'),
          onTap: () => setState(() => _open = !_open),
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _open ? 'Скрыть подробности' : 'Подробнее',
                  style: t.caption.copyWith(color: c.textSecondary),
                ),
                Icon(
                  _open ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                  size: 16,
                  color: c.textSecondary,
                ),
              ],
            ),
          ),
        ),
        if (_open)
          SelectableText(
            widget.details,
            key: const Key('details-text'),
            style: t.caption.copyWith(color: c.textTertiary),
          ),
      ],
    );
  }
}

/// Скелетон списка для сетевых данных: плашки `surface/3` по форме строки.
class ListSkeleton extends StatelessWidget {
  const ListSkeleton({this.rows = 3, super.key});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      key: const Key('list-skeleton'),
      children: [
        for (var i = 0; i < rows; i++) ...[
          Container(
            height: 76,
            decoration: BoxDecoration(
              color: c.surface1,
              borderRadius: const BorderRadius.all(Radius.circular(24)),
            ),
            padding: const EdgeInsets.all(AppSpacing.s4),
            child: Row(
              children: [
                _block(c.surface3, 40, 40, 20),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _block(c.surface3, 140, 12, 6),
                      const SizedBox(height: AppSpacing.s2),
                      _block(c.surface3, 90, 10, 5),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
        ],
      ],
    );
  }

  Widget _block(Color color, double w, double h, double r) => Container(
    width: w,
    height: h,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(r),
    ),
  );
}
