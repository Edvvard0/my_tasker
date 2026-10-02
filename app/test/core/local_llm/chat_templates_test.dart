import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/local_llm/chat_templates.dart';
import 'package:my_tasker/core/local_llm/local_llm_engine.dart';

void main() {
  group('GemmaChatTemplate', () {
    const template = GemmaChatTemplate();

    test('система вливается в первую реплику пользователя', () {
      final text = template.render(const [
        LlmTurn.system('Ты помощник.'),
        LlmTurn.user('Привет'),
      ]);
      expect(
        text,
        '<bos><start_of_turn>user\nТы помощник.\n\nПривет<end_of_turn>\n'
        '<start_of_turn>model\n',
      );
    });

    test('чередование ролей и заголовок хода модели', () {
      final text = template.render(const [
        LlmTurn.user('Привет'),
        LlmTurn.model('Здравствуйте'),
        LlmTurn.user('Дела?'),
      ]);
      expect(
        text,
        '<bos><start_of_turn>user\nПривет<end_of_turn>\n'
        '<start_of_turn>model\nЗдравствуйте<end_of_turn>\n'
        '<start_of_turn>user\nДела?<end_of_turn>\n<start_of_turn>model\n',
      );
    });

    test('подряд идущие реплики одной роли склеиваются', () {
      final text = template.render(const [
        LlmTurn.user('а'),
        LlmTurn.user('б'),
      ]);
      expect(text, contains('а\n\nб<end_of_turn>'));
      expect(RegExp('<start_of_turn>user').allMatches(text).length, 1);
    });

    test('без заголовка генерации и только система', () {
      final text = template.render(const [
        LlmTurn.system('Только система'),
      ], addGenerationPrompt: false);
      expect(text, '<bos><start_of_turn>user\nТолько система<end_of_turn>\n');
      expect(template.stopSequences, ['<end_of_turn>']);
    });

    test('пустые реплики пропускаются', () {
      final text = template.render(const [
        LlmTurn.user('  '),
        LlmTurn.user('Вопрос'),
      ]);
      expect(text, contains('Вопрос'));
      expect(RegExp('<start_of_turn>user').allMatches(text).length, 1);
    });
  });

  group('ChatMlTemplate', () {
    test('система отдельной репликой, роль assistant', () {
      final text = const ChatMlTemplate().render(const [
        LlmTurn.system('S'),
        LlmTurn.user('U'),
        LlmTurn.model('M'),
        LlmTurn.user('U2'),
      ]);
      expect(
        text,
        '<|im_start|>system\nS<|im_end|>\n<|im_start|>user\nU<|im_end|>\n'
        '<|im_start|>assistant\nM<|im_end|>\n<|im_start|>user\nU2<|im_end|>\n'
        '<|im_start|>assistant\n',
      );
    });
  });
}
