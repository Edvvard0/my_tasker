import 'package:flutter/material.dart';
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

  /// Мелкая строка под текстом («код для отладки»).
  final String? details;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
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
          if (details != null) ...[
            const SizedBox(height: AppSpacing.s1),
            Text(details!, style: t.caption.copyWith(color: c.textTertiary)),
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
