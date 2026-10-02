import 'package:my_tasker/core/local_llm/local_llm_engine.dart';

/// Превращает реплики в строку-промт модели. Нужен адаптерам рантаймов,
/// которые не применяют шаблон сами (llama.cpp, `.bin`/`.tflite`). LiteRT-LM
/// (`flutter_gemma` с `.litertlm`) применяет шаблон модели внутри SDK и
/// получает реплики по одной, поэтому здесь не используется.
abstract interface class ChatTemplate {
  /// Строка для подачи в токенизатор. [addGenerationPrompt] — дописать
  /// заголовок хода модели, чтобы она продолжила с него.
  String render(List<LlmTurn> turns, {bool addGenerationPrompt = true});

  /// Строки, на которых генерация должна остановиться.
  List<String> get stopSequences;
}

/// Склеивает подряд идущие реплики одной роли (шаблоны требуют чередования
/// user/model) и выносит системную часть отдельно.
({String system, List<LlmTurn> dialog}) normalizeTurns(List<LlmTurn> turns) {
  final system = StringBuffer();
  final dialog = <LlmTurn>[];
  for (final turn in turns) {
    final text = turn.text.trim();
    if (text.isEmpty) continue;
    if (turn.role == LlmRole.system) {
      if (system.isNotEmpty) system.write('\n\n');
      system.write(text);
      continue;
    }
    if (dialog.isNotEmpty && dialog.last.role == turn.role) {
      dialog[dialog.length - 1] = LlmTurn(
        turn.role,
        '${dialog.last.text}\n\n$text',
      );
    } else {
      dialog.add(LlmTurn(turn.role, text));
    }
  }
  return (system: system.toString(), dialog: dialog);
}

/// Чат-формат Gemma (`<start_of_turn>`), как у Gemma 2/3 и их GGUF-сборок.
///
/// Роли `system` у этого формата нет: системная часть дописывается в начало
/// первой реплики пользователя (так делает и шаблон из карточки модели).
/// У Gemma 4 `.litertlm` формат применяет SDK — см. [ChatTemplate].
class GemmaChatTemplate implements ChatTemplate {
  const GemmaChatTemplate();

  static const String bos = '<bos>';
  static const String startOfTurn = '<start_of_turn>';
  static const String endOfTurn = '<end_of_turn>';

  @override
  List<String> get stopSequences => const [endOfTurn];

  @override
  String render(List<LlmTurn> turns, {bool addGenerationPrompt = true}) {
    final normalized = normalizeTurns(turns);
    final buffer = StringBuffer(bos);
    var systemPending = normalized.system;
    for (final turn in normalized.dialog) {
      final isUser = turn.role == LlmRole.user;
      var text = turn.text;
      if (isUser && systemPending.isNotEmpty) {
        text = '$systemPending\n\n$text';
        systemPending = '';
      }
      buffer
        ..write(startOfTurn)
        ..write(isUser ? 'user' : 'model')
        ..write('\n')
        ..write(text)
        ..write(endOfTurn)
        ..write('\n');
    }
    if (systemPending.isNotEmpty) {
      // Диалога ещё нет, есть только системная часть.
      buffer
        ..write(startOfTurn)
        ..write('user\n')
        ..write(systemPending)
        ..write(endOfTurn)
        ..write('\n');
    }
    if (addGenerationPrompt) {
      buffer.write('${startOfTurn}model\n');
    }
    return buffer.toString();
  }
}

/// Формат ChatML (Qwen и родственные GGUF) — для запасного движка llama.cpp.
class ChatMlTemplate implements ChatTemplate {
  const ChatMlTemplate();

  static const String _start = '<|im_start|>';
  static const String _end = '<|im_end|>';

  @override
  List<String> get stopSequences => const [_end];

  @override
  String render(List<LlmTurn> turns, {bool addGenerationPrompt = true}) {
    final normalized = normalizeTurns(turns);
    final buffer = StringBuffer();
    if (normalized.system.isNotEmpty) {
      buffer.write('${_start}system\n${normalized.system}$_end\n');
    }
    for (final turn in normalized.dialog) {
      final role = turn.role == LlmRole.user ? 'user' : 'assistant';
      buffer.write('$_start$role\n${turn.text}$_end\n');
    }
    if (addGenerationPrompt) buffer.write('${_start}assistant\n');
    return buffer.toString();
  }
}
