import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/context_builder.dart';

/// Лёгкий пресет офлайн-чата (решение этапа 10, п. 5): задачи на сегодня и
/// неделю вместе с просроченными (источник `tasks`, фильтр `week`) и
/// расписание на 3 дня. Лимиты токенов источников дают в сумме ≈ 1500.
const List<ContextSourceRef> lightLocalPreset = [
  ContextSourceRef(source: 'tasks', filter: {'range': 'week'}, tokenLimit: 900),
  ContextSourceRef(source: 'events', filter: {'days': '3'}, tokenLimit: 600),
];

/// Собирает контекст для локального ответа.
///
/// Чувствительные пресеты здесь **разрешены**: данные не покидают телефон
/// (в облаке они запрещены, spec Этапа 3, 5.2). Если у чата есть свой
/// [preset] — берутся его источники (лимит каждого ограничен [maxSourceTokens]),
/// иначе — [lightLocalPreset]. Итоговую подгонку под окно модели делает
/// `TokenBudget`.
Future<ContextPackage> buildLocalContext(
  ContextBuilder builder,
  ContextEnv env, {
  ContextPreset? preset,
  int maxSourceTokens = 900,
}) {
  final selection = preset == null || preset.sources.isEmpty
      ? lightLocalPreset
      : [
          for (final s in preset.sources)
            s.copyWith(
              tokenLimit: s.tokenLimit > maxSourceTokens
                  ? maxSourceTokens
                  : s.tokenLimit,
            ),
        ];
  return builder.build(selection, env);
}
