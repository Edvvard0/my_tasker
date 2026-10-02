import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/local_llm/local_context.dart';
import 'package:my_tasker/core/local_llm/local_prompts.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/context_builder.dart';

class _Source extends ContextSource {
  const _Source(this._id, {this.isSensitive = false});

  final String _id;
  final bool isSensitive;

  @override
  String get id => _id;

  @override
  String get label => _id;

  @override
  String get description => '';

  @override
  bool get sensitive => isSensitive;

  @override
  List<ContextFilterField> get filters => const [];

  @override
  Map<String, Object?> get defaultFilter => const {};

  @override
  String summary(Map<String, Object?> filter) => '${filter['days'] ?? ''}';

  @override
  Future<List<String>> lines(
    ContextEnv env,
    Map<String, Object?> filter,
  ) async => ['- данные $_id ${filter['range'] ?? filter['days'] ?? ''}'];
}

void main() {
  setUpAll(ensureTimeZones);

  group('системная часть', () {
    test('блок «сейчас»: дата, день недели, время, пояс', () {
      final zone = requireLocation('Europe/Moscow');
      expect(
        nowBlock(DateTime.utc(2026, 10, 2, 11, 5), zone),
        'Сейчас: 2026-10-02, пятница, 14:05 (Europe/Moscow).',
      );
    });

    test(
      'правила create_task включаются флагом, промт агента заменяет общий',
      () {
        final zone = requireLocation('UTC');
        final now = DateTime.utc(2026, 10, 5, 7);
        final withTool = buildLocalSystemPrompt(nowUtc: now, zone: zone);
        expect(withTool, contains(defaultLocalAssistantPrompt));
        expect(withTool, contains('create_task'));
        expect(withTool, contains('2026-10-05'));

        final agent = buildLocalSystemPrompt(
          nowUtc: now,
          zone: zone,
          agentPrompt: ' Ты бухгалтер. ',
          allowCreateTask: false,
        );
        expect(agent, startsWith('Ты бухгалтер.'));
        expect(agent, isNot(contains('create_task')));
        expect(agent, isNot(contains(defaultLocalAssistantPrompt)));
      },
    );

    test('подсказка повтора перечисляет проблемы', () {
      final hint = createTaskRetryHint(['title: пусто', 'priority: 1..5']);
      expect(hint, contains('title: пусто; priority: 1..5'));
    });
  });

  group('контекст офлайн', () {
    final env = ContextEnv(
      now: DateTime.utc(2026, 10, 5),
      zone: requireLocation('UTC'),
      readRows: (_) async => const [],
    );
    const builder = ContextBuilder([
      _Source('tasks'),
      _Source('events'),
      _Source('finance', isSensitive: true),
    ]);

    test('лёгкий пресет: задачи на неделю + расписание на 3 дня', () async {
      final pkg = await buildLocalContext(builder, env);
      expect(pkg.sections.map((s) => s.source), ['tasks', 'events']);
      expect(pkg.text, contains('данные tasks week'));
      expect(pkg.text, contains('данные events 3'));
      final limits = lightLocalPreset.fold<int>(0, (s, r) => s + r.tokenLimit);
      expect(limits, 1500);
    });

    test(
      'чувствительные пресеты разрешены, лимит источника ограничен',
      () async {
        const preset = ContextPreset(
          id: 'p',
          name: 'Финансы',
          sensitive: true,
          sources: [ContextSourceRef(source: 'finance', tokenLimit: 5000)],
        );
        final pkg = await buildLocalContext(builder, env, preset: preset);
        expect(pkg.containsSensitive, isTrue);
        expect(pkg.text, contains('данные finance'));
        // Пустой пресет — лёгкий пресет по умолчанию.
        final empty = await buildLocalContext(
          builder,
          env,
          preset: const ContextPreset(
            id: 'e',
            name: 'Пустой',
            sources: [],
            sensitive: false,
          ),
        );
        expect(empty.sections.length, 2);
      },
    );
  });
}
