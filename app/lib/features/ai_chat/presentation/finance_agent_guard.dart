import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/widgets/confirm_dialog.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/finance/application/finance_lock.dart';
import 'package:my_tasker/features/finance/presentation/privacy/finance_gate.dart';

/// Инструменты серверного агента «Финансов» (`backend/src/tasker/ai/agents.py`,
/// `FINANCE_TOOLS`): их результаты уходят облачной модели.
const Set<String> financeAgentTools = {
  'get_accounts',
  'get_finance_summary',
  'get_goals',
  'get_debts',
};

/// Чат читает данные «Финансов» сам, через сервер: тема чата или агента —
/// «Финансы», либо у агента включены инструменты финансов (так бывает и у
/// своего агента). Охранники контекста ИИ на клиенте этого не видят, поэтому
/// отправку в такой чат закрывает [ensureFinanceAgentAllowed].
bool isFinanceAgentChat(Conversation conv, AgentProfile? agent) =>
    conv.topic == AiTopic.finance ||
    (agent != null &&
        (agent.topic == AiTopic.finance ||
            agent.seedKey == 'finance' ||
            agent.enabledTools.any(financeAgentTools.contains)));

/// Можно ли отправлять сообщение в чат [conv] с агентом [agent].
///
/// В обычном чате — всегда. В чате с агентом «Финансов»:
///  * замок закрыт — сначала PIN (отмена отменяет отправку);
///  * включено «скрыть суммы» — один раз за сессию чата подтверждение:
///    агент увидит суммы и данные счетов. Согласие только в памяти и
///    сбрасывается блокировкой и переключением режима.
Future<bool> ensureFinanceAgentAllowed(
  BuildContext context,
  WidgetRef ref, {
  required Conversation conv,
  required AgentProfile? agent,
}) async {
  if (!isFinanceAgentChat(conv, agent)) return true;
  if (!await ensureFinanceUnlocked(context)) return false;
  await ref.read(hideAmountsProvider.notifier).ready;
  if (!context.mounted) return false;
  if (!ref.read(hideAmountsProvider).hidden) return true;
  if (ref.read(financeAgentConsentProvider).contains(conv.id)) return true;
  final ok = await showConfirmDialog(
    context,
    title: 'Суммы скрыты',
    message: 'Агент «Финансы» увидит суммы и данные ваших счетов. Отправить?',
    confirmLabel: 'Отправить',
  );
  if (!ok || !context.mounted) return false;
  ref.read(financeAgentConsentProvider.notifier).grant(conv.id);
  return true;
}
