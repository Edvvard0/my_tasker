import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';

/// Инструменты сервера, читающие приватные данные раздела «Финансы»
/// (`ToolSpec.sensitive = true`, spec Этапа 3, 5.1 и 6.1). В облачном чате
/// они доступны модели только с явным согласием пользователя.
const Set<String> sensitiveToolNames = {
  'get_accounts',
  'get_finance_summary',
  'get_goals',
  'get_debts',
};

/// У агента есть чувствительные инструменты: предустановленный «Финансы»
/// (его список сервер берёт из кода) или пользовательский профиль с такими
/// инструментами в `enabled_tools`.
bool agentUsesSensitiveTools(AgentProfile? agent) {
  if (agent == null) return false;
  if (agent.seedKey == 'finance') return true;
  return agent.enabledTools.any(sensitiveToolNames.contains);
}
