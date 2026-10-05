import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/format/ru_format.dart' as ru;
import 'package:my_tasker/core/theme/app_colors.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/core/widgets/status_pill.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/application/privacy_providers.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart'
    show moscowDay;
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_icons.dart';
import 'package:my_tasker/features/work/domain/work_format.dart';

/// Назад из экрана «Финансов»: на шаг назад, а при прямом входе — в
/// «Финансы».
void financeBack(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go('/finance');
  }
}

/// Строит содержимое экрана по снимку «Финансов»: скелетон при загрузке и
/// понятная ошибка вместо падения.
class FinanceBuilder extends ConsumerWidget {
  const FinanceBuilder({required this.builder, super.key});

  final Widget Function(BuildContext context, FinanceData data) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(financeDataProvider)
        .when(
          loading: () => const ListSkeleton(rows: 4),
          error: (error, _) => NoticeCard(
            key: const Key('finance-error'),
            label: 'Не загрузилось',
            tone: StatusTone.danger,
            text: 'Не удалось прочитать данные «Финансов» на устройстве.',
            actions: [
              FilledButton(
                key: const Key('finance-retry'),
                onPressed: () => retryFailedFinanceStreams(ref),
                child: const Text('Повторить'),
              ),
            ],
          ),
          data: (data) => builder(context, data),
        );
  }
}

/// Сумма с учётом режима «скрыть суммы».
class AmountText extends ConsumerWidget {
  const AmountText(
    this.kopecks, {
    this.style,
    this.signed = false,
    this.short = false,
    this.textKey,
    super.key,
  });

  final int kopecks;
  final TextStyle? style;

  /// Со знаком «+» у положительных.
  final bool signed;

  /// Компактно (`80,5к ₽`).
  final bool short;
  final Key? textKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = ref.watch(amountFormatProvider);
    final text = short
        ? f.short(kopecks)
        : (signed ? f.signed(kopecks) : f.full(kopecks));
    return Text(text, key: textKey, style: style ?? context.text.numM);
  }
}

/// Форма слова по числу.
String plural(int n, String one, String few, String many) =>
    ru.pluralRu(n, one, few, many);

/// Круглая иконка в `surface/3`.
class IconBadge extends StatelessWidget {
  const IconBadge({required this.icon, this.size = 40, super.key});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: c.surface3, shape: BoxShape.circle),
      child: Icon(icon, size: size * 0.5, color: c.textPrimary),
    );
  }
}

/// Строка счёта: иконка вида, название, банк и последние цифры, баланс.
class AccountTile extends ConsumerWidget {
  const AccountTile({
    required this.account,
    required this.balance,
    this.onTap,
    super.key,
  });

  final Account account;
  final int balance;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    // Банк и последние цифры карты; без них — вид счёта.
    final details = [
      if (account.bank != null) account.bank!,
      if (account.cardLast4 != null) '•••• ${account.cardLast4}',
    ];
    final meta = details.isEmpty ? account.kind.label : details.join(' · ');
    return InkWell(
      borderRadius: AppRadii.borderL,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4,
          vertical: AppSpacing.s3,
        ),
        child: Row(
          children: [
            IconBadge(icon: accountIcon(account.kind)),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    account.name,
                    style: t.bodyStrong,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    meta,
                    style: t.caption.copyWith(color: c.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (!account.includeInTotal)
                    Text(
                      'Не в общем балансе',
                      style: t.caption.copyWith(color: c.textTertiary),
                    ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.s2),
            AmountText(
              balance,
              style: t.numL,
              textKey: Key('balance-${account.id}'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка операции: иконка вида, название, счёт и категория, сумма со
/// знаком (доход — «+»; перевод — без знака, серым).
class TransactionTile extends ConsumerWidget {
  const TransactionTile({
    required this.data,
    required this.tx,
    this.onTap,
    this.perspective,
    this.showDate = true,
    super.key,
  });

  final FinanceData data;
  final FinTransaction tx;
  final VoidCallback? onTap;

  /// Дату в подписи не показывают там, где есть заголовок дня.
  final bool showDate;

  /// Счёт, с точки зрения которого показывается перевод (`+`/`-`).
  final String? perspective;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    final incoming =
        tx.kind == TxKind.transfer && perspective == tx.toAccountId;
    final meta = [
      if (tx.kind == TxKind.transfer)
        'Перевод'
      else
        data.accountName(tx.accountId),
      if (tx.kind != TxKind.transfer && tx.categoryId != null)
        data.categoryTitle(tx.categoryId),
      if (showDate) formatDateText(moscowDay(tx.occurredAt), data.now),
    ].join(' · ');
    final amount = switch (tx.kind) {
      TxKind.income => tx.amount,
      TxKind.expense => -tx.amount,
      TxKind.transfer =>
        perspective == null ? tx.amount : (incoming ? tx.amount : -tx.amount),
    };
    final muted = !tx.isConfirmed || tx.kind == TxKind.transfer;
    final category = tx.categoryId == null
        ? null
        : data.categoryById[tx.categoryId];
    return InkWell(
      key: Key('tx-${tx.id}'),
      borderRadius: AppRadii.borderL,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4,
          vertical: AppSpacing.s3,
        ),
        child: Row(
          children: [
            IconBadge(
              icon: tx.kind == TxKind.transfer
                  ? LucideIcons.arrowLeftRight
                  : (category != null
                        ? categoryIcon(category.icon)
                        : txKindIcon(tx.kind)),
            ),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data.transactionTitle(tx),
                    style: t.bodyStrong,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    meta,
                    style: t.caption.copyWith(color: c.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (!tx.isConfirmed)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: StatusPill(
                        label: tx.status.label,
                        tone: StatusTone.warning,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.s2),
            AmountText(
              amount,
              // Перевод в общей ленте — без знака: он не доход и не расход.
              signed: tx.kind != TxKind.transfer || perspective != null,
              textKey: Key('tx-amount-${tx.id}'),
              style: t.numL.copyWith(
                color: muted ? c.textSecondary : c.textPrimary,
                decoration: tx.isConfirmed ? null : TextDecoration.lineThrough,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Горизонтальный бар «подпись — полоса — сумма и доля» (02, 5.3.2):
/// все бары одного серого тона.
class BarRow extends ConsumerWidget {
  const BarRow({
    required this.label,
    required this.amount,
    required this.fraction,
    this.percent,
    this.onTap,
    this.indent = false,
    super.key,
  });

  final String label;
  final int amount;

  /// 0…1: длина бара.
  final double fraction;

  /// Целые проценты справа.
  final int? percent;
  final VoidCallback? onTap;
  final bool indent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.text;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadii.borderM,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          indent ? AppSpacing.s6 : 0,
          AppSpacing.s1,
          0,
          AppSpacing.s1,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: t.bodyS.copyWith(color: c.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                AmountText(amount, style: t.numM),
                if (percent != null) ...[
                  const SizedBox(width: AppSpacing.s2),
                  SizedBox(
                    width: 40,
                    child: Text(
                      '$percent%',
                      textAlign: TextAlign.right,
                      style: t.caption.copyWith(color: c.textSecondary),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: AppRadii.borderFull,
              child: SizedBox(
                height: 6,
                child: LayoutBuilder(
                  builder: (context, box) => Stack(
                    children: [
                      Positioned.fill(child: ColoredBox(color: c.surface3)),
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: box.maxWidth * fraction.clamp(0, 1),
                        child: const ColoredBox(color: AppColors.chartOther),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Полоса прогресса к цели: синяя заливка «есть», серая дорожка. Доля в
/// сотых долях процента; перевыполнение заполняет полосу целиком.
class GoalBar extends StatelessWidget {
  const GoalBar({required this.basisPoints, this.height = 12, super.key});

  final int basisPoints;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fraction = basisPoints.clamp(0, 10000) / 10000;
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
                child: ColoredBox(color: c.accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Сгруппированные вертикальные столбики «доход / расход» по месяцам
/// (02, 5.3.2): доход светлый, расход средне-серый, текущий месяц —
/// с синей подписью.
class MonthBars extends StatelessWidget {
  const MonthBars({
    required this.months,
    required this.currentMonth,
    this.selected,
    this.onSelect,
    this.height = 120,
    super.key,
  });

  final List<MonthBar> months;
  final String currentMonth;
  final String? selected;
  final ValueChanged<String>? onSelect;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    var peak = 1;
    for (final m in months) {
      peak = math.max(peak, math.max(m.income, m.expense));
    }
    return SizedBox(
      height: height + 26,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final m in months)
            Expanded(
              child: Semantics(
                button: onSelect != null,
                label: 'Месяц ${m.month}',
                child: InkWell(
                  key: Key('month-bar-${m.month}'),
                  onTap: onSelect == null ? null : () => onSelect!(m.month),
                  borderRadius: AppRadii.borderS,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      SizedBox(
                        height: height,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _bar(m.income, peak, AppColors.chartSeries[1]),
                            const SizedBox(width: 2),
                            _bar(m.expense, peak, AppColors.chartSeries[3]),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        height: 18,
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: m.month == currentMonth
                            ? BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(color: c.accent, width: 2),
                                ),
                              )
                            : null,
                        // Подпись сжимается по ширине (12 месяцев на телефоне),
                        // а не переносится.
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            monthShortLabel(m.month),
                            maxLines: 1,
                            style: t.caption.copyWith(
                              color: m.month == selected
                                  ? c.textPrimary
                                  : (m.month == currentMonth
                                        ? c.accent
                                        : c.textSecondary),
                              fontWeight: m.month == selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bar(int value, int peak, Color color) {
    final h = value <= 0 ? 0.0 : (height * value / peak).clamp(2.0, height);
    return Container(
      width: months.length > 8 ? 6 : 10,
      height: h,
      decoration: BoxDecoration(
        color: color,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
      ),
    );
  }
}

/// Один месяц столбиков.
class MonthBar {
  const MonthBar({
    required this.month,
    required this.income,
    required this.expense,
  });

  final String month;
  final int income;
  final int expense;
}

const List<String> _shortMonths = [
  'янв',
  'фев',
  'мар',
  'апр',
  'май',
  'июн',
  'июл',
  'авг',
  'сен',
  'окт',
  'ноя',
  'дек',
];

/// «сен» для `2026-09`.
String monthShortLabel(String month) =>
    _shortMonths[int.parse(month.substring(5, 7)) - 1];

/// Линия динамики общего баланса (02, 5.3.2): одна серия, area снизу,
/// ноль (если в диапазоне) — пунктиром. Подписи значений — рядом, а не
/// на графике.
class BalanceLine extends StatelessWidget {
  const BalanceLine({required this.values, this.height = 64, super.key});

  final List<int> values;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _LinePainter(
          values: values,
          line: AppColors.chartSeries[1],
          fill: c.surface3,
          axis: c.borderStrong,
        ),
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.values,
    required this.line,
    required this.fill,
    required this.axis,
  });

  final List<int> values;
  final Color line;
  final Color fill;
  final Color axis;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    var low = values.reduce(math.min);
    var high = values.reduce(math.max);
    if (low > 0) low = 0;
    if (high < 0) high = 0;
    if (high == low) high = low + 1;
    double y(int v) => size.height - (v - low) / (high - low) * size.height;
    double x(int i) => size.width * i / (values.length - 1);
    final path = Path()..moveTo(x(0), y(values.first));
    for (var i = 1; i < values.length; i++) {
      path.lineTo(x(i), y(values[i]));
    }
    final area = Path.from(path)
      ..lineTo(size.width, y(0))
      ..lineTo(0, y(0))
      ..close();
    canvas
      ..drawPath(area, Paint()..color = fill.withValues(alpha: 0.6))
      ..drawLine(
        Offset(0, y(0)),
        Offset(size.width, y(0)),
        Paint()
          ..color = axis
          ..strokeWidth = 1,
      )
      ..drawPath(
        path,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round,
      );
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.values != values || old.line != line;
}

/// Карточка со списком строк (`ListTile`): прозрачный `Material` внутри,
/// чтобы заливка и разводы строк рисовались поверх фона карточки.
class ListCard extends StatelessWidget {
  const ListCard({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: Column(children: children),
      ),
    );
  }
}

/// Заголовок блока с необязательным действием справа (как в «Работе»).
class FinanceSection extends StatelessWidget {
  const FinanceSection({required this.title, this.trailing, super.key});

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

/// Предупреждение внутри карточки.
class FinanceWarning extends StatelessWidget {
  const FinanceWarning({
    required this.text,
    this.actions = const [],
    super.key,
  });

  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.triangleAlert, size: 18, color: c.textPrimary),
              const SizedBox(width: AppSpacing.s2),
              Expanded(child: Text(text, style: context.text.bodyS)),
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

/// Название месяца по `YYYY-MM` для заголовков: «сентябрь 2026».
String monthYearTitle(String month) {
  const names = [
    'январь',
    'февраль',
    'март',
    'апрель',
    'май',
    'июнь',
    'июль',
    'август',
    'сентябрь',
    'октябрь',
    'ноябрь',
    'декабрь',
  ];
  return '${names[int.parse(month.substring(5, 7)) - 1]} ${month.substring(0, 4)}';
}
