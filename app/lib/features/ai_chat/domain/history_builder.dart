import 'dart:convert';

import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/context_builder.dart';

typedef OpenAiMessage = Map<String, Object?>;

/// Результат предложения для модели (spec Этапа 3, 2, п. 7).
String proposalResultText(ToolProposal p) => switch (p.status) {
  ProposalStatus.pending => 'awaiting user approval',
  ProposalStatus.approved => 'task created: ${p.entityId}',
  ProposalStatus.editedApproved =>
    'task created: ${p.entityId}; final arguments: ${jsonEncode(p.arguments)}',
  ProposalStatus.rejected =>
    'user rejected${(p.rejectReason ?? '').isEmpty ? '' : ': ${p.rejectReason}'}',
};

/// Ответ сгенерирован локальной моделью (`ai_messages.model = local/…`).
bool isLocalReply(ChatMessage m) =>
    m.role == MessageRole.assistant && (m.model ?? '').startsWith('local/');

/// История чата в формате OpenAI без `system` (spec 5.1).
///
/// * `user` — как есть; `assistant` — текст и `tool_calls`, за которыми
///   идут сообщения `tool` с результатами;
/// * результат читающего инструмента берётся из части `tool_result`,
///   результат пишущего — из предложения (его решение пользователя);
/// * ответы со статусом `error` и пустые ответы пропускаются, частичный
///   текст отменённого ответа остаётся;
/// * [forCloud]: для запроса в облако ответы **локальной модели** опускаются.
///   Локальный чат может работать с чувствительным контекстом (финансы), и
///   её ответы содержат эти цифры; после переключения беседы `local` -> `cloud`
///   они не должны уходить в polza.ai через историю. Сообщения пользователя
///   остаются.
List<OpenAiMessage> buildHistory(
  List<ChatMessage> messages,
  Map<String, ToolProposal> proposals, {
  bool forCloud = false,
}) {
  final result = <OpenAiMessage>[];
  for (final m in messages) {
    if (forCloud && isLocalReply(m)) continue;
    if (m.role == MessageRole.user) {
      if (m.text.trim().isEmpty) continue;
      result.add({'role': 'user', 'content': m.text});
      continue;
    }
    if (m.role != MessageRole.assistant) continue;
    if (m.status == MessageStatus.error ||
        m.status == MessageStatus.streaming) {
      continue;
    }
    final calls = m.parts.whereType<ToolCallPart>().toList();
    if (m.text.trim().isEmpty && calls.isEmpty) continue;
    result.add({
      'role': 'assistant',
      'content': m.text.isEmpty ? null : m.text,
      if (calls.isNotEmpty)
        'tool_calls': [
          for (final c in calls)
            {
              'id': c.id,
              'type': 'function',
              'function': {
                'name': c.name,
                'arguments': c.arguments != null
                    ? jsonEncode(c.arguments)
                    : (c.rawArguments ?? '{}'),
              },
            },
        ],
    });
    for (final c in calls) {
      result.add({
        'role': 'tool',
        'tool_call_id': c.id,
        'content': _toolResult(c, m, proposals),
      });
    }
  }
  return result;
}

String _toolResult(
  ToolCallPart call,
  ChatMessage message,
  Map<String, ToolProposal> proposals,
) {
  for (final p in message.parts) {
    if (p is ToolResultPart && p.toolCallId == call.id) return p.content;
  }
  for (final p in message.parts) {
    if (p is ProposalPart && p.toolCallId == call.id) {
      final proposal = proposals[p.proposalId];
      if (proposal != null) return proposalResultText(proposal);
    }
  }
  return 'no result';
}

int _messageTokens(OpenAiMessage m) =>
    4 +
    estimateTokens('${m['content'] ?? ''}') +
    (m['tool_calls'] == null ? 0 : estimateTokens(jsonEncode(m['tool_calls'])));

/// Обрезает историю по бюджету токенов, отбрасывая самые старые сообщения.
/// Вызов инструмента и его результаты не разрываются; последний ход
/// остаётся всегда; история начинается с сообщения пользователя и не длиннее
/// [maxMessages] (spec 5.1: не более 400).
List<OpenAiMessage> trimHistory(
  List<OpenAiMessage> history,
  int budgetTokens, {
  int maxMessages = 400,
}) {
  final units = <List<OpenAiMessage>>[];
  for (final m in history) {
    if (m['role'] == 'tool' && units.isNotEmpty) {
      units.last.add(m);
    } else {
      units.add([m]);
    }
  }
  final kept = <List<OpenAiMessage>>[];
  var used = 0;
  var count = 0;
  for (final unit in units.reversed) {
    final cost = unit.fold<int>(0, (sum, m) => sum + _messageTokens(m));
    if (kept.isNotEmpty &&
        (used + cost > budgetTokens || count + unit.length > maxMessages)) {
      break;
    }
    kept.insert(0, unit);
    used += cost;
    count += unit.length;
  }
  while (kept.length > 1 && kept.first.first['role'] != 'user') {
    kept.removeAt(0);
  }
  return [for (final u in kept) ...u];
}
