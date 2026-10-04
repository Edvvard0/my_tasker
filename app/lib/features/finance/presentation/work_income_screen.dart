import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/core/theme/app_radii.dart';
import 'package:my_tasker/core/theme/app_spacing.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/core/widgets/adaptive_sheet.dart';
import 'package:my_tasker/core/widgets/app_card.dart';
import 'package:my_tasker/core/widgets/empty_state.dart';
import 'package:my_tasker/core/widgets/screen_scaffold.dart';
import 'package:my_tasker/features/calendar/domain/calendar_validation.dart';
import 'package:my_tasker/features/finance/application/finance_providers.dart';
import 'package:my_tasker/features/finance/data/finance_repository.dart';
import 'package:my_tasker/features/finance/domain/finance_calc.dart';
import 'package:my_tasker/features/finance/presentation/finance_forms.dart';
import 'package:my_tasker/features/finance/presentation/finance_widgets.dart';
import 'package:my_tasker/features/work/domain/work_format.dart';
import 'package:my_tasker/features/work/domain/work_models.dart' show Payment;
import 'package:my_tasker/features/work/presentation/work_forms.dart'
    show FormError, MoneyTextField, moneyFieldText, parseMoneyField;
import 'package:my_tasker/features/work/presentation/work_widgets.dart'
    show PersonAvatar;

/// «Ожидаемые поступления из Работы»: дебиторка по заказчикам (Этап 4) и
/// платежи Работы, ещё не отражённые доходами на счетах. Платёж Работы —
/// запись о факте оплаты; деньги на счёте появляются операцией-доходом со
/// ссылкой на платёж, и этот доход считается один раз (spec 7.1).
class WorkIncomeScreen extends ConsumerWidget {
  const WorkIncomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ScreenScaffold(
      key: const Key('work-income-screen'),
      title: 'Из «Работы»',
      parentLabel: 'Финансы',
      onBack: () => financeBack(context),
      child: FinanceBuilder(builder: (context, data) => _Body(data: data)),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.data});

  final FinanceData data;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final owed = data.receivables;
    final payments = {for (final p in data.work.payments) p.id: p};
    final pending = [
      for (final line in data.paymentCoverage)
        if (line.unlinked > 0 && payments.containsKey(line.paymentId)) line,
    ];
    final over = [
      for (final line in data.paymentCoverage)
        if (line.unlinked < 0) line,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ОЖИДАЕТСЯ',
                style: t.overline.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s1),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: AmountText(
                  owed.total,
                  style: t.display,
                  textKey: const Key('work-income-total'),
                ),
              ),
              Text(
                owed.clients.isEmpty
                    ? 'Все проекты оплачены'
                    : '${owed.clients.length} ${plural(owed.clients.length, 'заказчик', 'заказчика', 'заказчиков')}',
                style: t.bodyS.copyWith(color: c.textSecondary),
              ),
            ],
          ),
        ),
        if (owed.clients.isEmpty)
          const EmptyState(
            key: Key('work-income-empty'),
            icon: LucideIcons.briefcase,
            title: 'Ожидаемых поступлений нет',
            message:
                'Остатки появятся, когда у проектов «в работе», «пауза» или '
                '«завершён» будет неоплаченная сумма.',
          )
        else
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final g in owed.clients)
                  InkWell(
                    key: Key('work-income-client-${g.clientId ?? 'none'}'),
                    borderRadius: AppRadii.borderL,
                    onTap: () => context.push('/work/receivables'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.s4,
                        vertical: AppSpacing.s3,
                      ),
                      child: Row(
                        children: [
                          PersonAvatar(
                            name: data.work.personById[g.clientId]?.name ?? '?',
                          ),
                          const SizedBox(width: AppSpacing.s3),
                          Expanded(
                            child: Text(
                              data.work.personById[g.clientId]?.name ??
                                  'Заказчик не указан',
                              style: t.bodyStrong,
                            ),
                          ),
                          AmountText(g.remaining, style: t.numL),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        const FinanceSection(title: 'Не отражено на счетах'),
        if (pending.isEmpty)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s2),
            child: Text(
              'Все платежи Работы отражены на счетах.',
              key: const Key('work-income-no-pending'),
              style: t.bodyS.copyWith(color: c.textSecondary),
            ),
          )
        else
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final line in pending)
                  _PendingRow(
                    data: data,
                    payment: payments[line.paymentId]!,
                    coverage: line,
                  ),
              ],
            ),
          ),
        for (final line in over)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s2),
            child: FinanceWarning(
              key: Key('work-income-over-${line.paymentId}'),
              text:
                  'К платежу привязано доходов больше его суммы: проверьте '
                  'операции с этим платежом.',
            ),
          ),
      ],
    );
  }
}

class _PendingRow extends StatelessWidget {
  const _PendingRow({
    required this.data,
    required this.payment,
    required this.coverage,
  });

  final FinanceData data;
  final Payment payment;
  final PaymentCoverage coverage;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final payer = data.work.personById[payment.payerId]?.name ?? 'Платёж';
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s3,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(payer, style: t.bodyStrong),
                Text(
                  formatDateText(moscowDay(payment.paidAt), data.now),
                  style: t.caption.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
          AmountText(
            coverage.unlinked,
            style: t.numL,
            textKey: Key('work-income-unlinked-${payment.id}'),
          ),
          const SizedBox(width: AppSpacing.s2),
          OutlinedButton(
            key: Key('work-income-reflect-${payment.id}'),
            onPressed: () => showReflectSheet(context, payment.id),
            child: const Text('На счёт'),
          ),
        ],
      ),
    );
  }
}

/// «Деньги по проекту пришли на карту»: доход на выбранный счёт со ссылкой
/// на платёж Работы.
Future<void> showReflectSheet(BuildContext context, String paymentId) =>
    showEditorSheet<void>(
      context,
      builder: (_) => ReflectSheet(paymentId: paymentId),
    );

class ReflectSheet extends ConsumerStatefulWidget {
  const ReflectSheet({required this.paymentId, super.key});

  final String paymentId;

  @override
  ConsumerState<ReflectSheet> createState() => _ReflectSheetState();
}

class _ReflectSheetState extends ConsumerState<ReflectSheet> {
  final _amount = TextEditingController();
  String? _accountId;
  String? _error;
  bool _saving = false;
  bool _initialized = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save(FinanceData data, Payment payment, int unlinked) async {
    if (_saving) return;
    final amount = parseMoneyField(_amount.text, 'Сумма');
    if (amount.error != null || amount.kopecks == null || amount.kopecks == 0) {
      setState(() => _error = amount.error ?? 'Укажите сумму');
      return;
    }
    if (_accountId == null) {
      setState(() => _error = 'Выберите счёт');
      return;
    }
    if (amount.kopecks! > unlinked) {
      setState(() => _error = 'Больше, чем ещё не отражено на счетах');
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      await ref
          .read(financeRepositoryProvider)
          .reflectWorkPayment(
            paymentId: payment.id,
            accountId: _accountId!,
            amount: amount.kopecks!,
            occurredAt: payment.paidAt,
            merchant: data.work.personById[payment.payerId]?.name,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
    } on ValidationError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final data = ref.watch(financeDataProvider).value;
    if (data == null) return const EditorLoading();
    final payment = data.work.payments
        .where((p) => p.id == widget.paymentId)
        .firstOrNull;
    final coverage = data.coverageOf(widget.paymentId);
    if (payment == null || coverage == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHeader(title: 'Платёж'),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Text(
              'Платёж не найден.',
              style: t.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      );
    }
    final unlinked = coverage.unlinked < 0 ? 0 : coverage.unlinked;
    final accounts = [
      for (final a in data.accounts)
        if (!a.archived) a,
    ];
    if (!_initialized) {
      _initialized = true;
      _amount.text = moneyFieldText(unlinked == 0 ? null : unlinked);
      _accountId = accounts.isEmpty ? null : accounts.first.id;
    }
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader(title: 'Деньги пришли на счёт'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Создастся подтверждённый доход со ссылкой на платёж '
                    'Работы; в аналитике он считается один раз.',
                    style: t.bodyS.copyWith(color: c.textSecondary),
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  FormBlock(
                    label: 'Сумма (ещё не отражено)',
                    child: MoneyTextField(
                      key: const Key('reflect-amount'),
                      controller: _amount,
                    ),
                  ),
                  FormBlock(
                    label: 'На какой счёт',
                    child: accounts.isEmpty
                        ? Text(
                            'Сначала добавьте счёт.',
                            style: t.bodyS.copyWith(color: c.textSecondary),
                          )
                        : AccountChips(
                            keyPrefix: 'reflect-account',
                            accounts: accounts,
                            selectedId: _accountId,
                            onSelect: (id) => setState(() => _accountId = id),
                          ),
                  ),
                  if (_error != null)
                    FormError(_error!, key: const Key('reflect-error')),
                ],
              ),
            ),
          ),
          EditorActions(
            saveKey: const Key('reflect-save'),
            onSave: () => _save(data, payment, unlinked),
            saving: _saving,
            saveLabel: 'Отразить',
          ),
        ],
      ),
    );
  }
}
