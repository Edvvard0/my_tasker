import 'package:flutter/foundation.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:timezone/timezone.dart' as tz;

/// Оценка числа токенов: `ceil(символов / 3)` (как на сервере, spec 5.5).
int estimateTokens(String text) => (text.length / 3).ceil();

/// Окружение, в котором провайдеры собирают данные: момент «сейчас» (UTC)
/// и пояс пользователя. Чтение данных — через замыкания, чтобы провайдеры
/// не зависели от хранилища.
@immutable
class ContextEnv {
  const ContextEnv({
    required this.now,
    required this.zone,
    required this.readRows,
    this.hideAmounts = false,
  });

  final DateTime now;
  final tz.Location zone;

  /// Режим «скрыть суммы»: источники с деньгами показывают маску вместо
  /// сумм. Включается только для превью на экране, не для запроса к модели.
  final bool hideAmounts;

  ContextEnv copyWith({bool? hideAmounts}) => ContextEnv(
    now: now,
    zone: zone,
    readRows: readRows,
    hideAmounts: hideAmounts ?? this.hideAmounts,
  );

  /// Живые строки синхронизируемой таблицы (JSON-вид).
  final Future<List<Map<String, Object?>>> Function(String table) readRows;
}

/// Параметр фильтра источника с выбором из списка.
@immutable
class ContextFilterField {
  const ContextFilterField({
    required this.key,
    required this.label,
    required this.options,
  });

  final String key;
  final String label;

  /// `значение -> подпись`.
  final Map<String, String> options;
}

/// Провайдер контекста: источник данных раздела, который можно включить в
/// чат. Реестр расширяется: Этапы 4–8 добавляют свои (проекты, финансы,
/// учёба, сон) — см. `contextSourcesProvider`.
abstract class ContextSource {
  const ContextSource();

  /// Ключ в `ai_context_presets.sources[].source`.
  String get id;

  String get label;

  /// Одна строка пояснения для выбора.
  String get description;

  /// Данные источника нельзя отправлять в облако (финансы, здоровье).
  /// Такой источник блокирует облачный чат (spec 1.3 и 5.2).
  bool get sensitive => false;

  List<ContextFilterField> get filters;

  Map<String, Object?> get defaultFilter;

  /// Подпись выбранного фильтра («на 7 дней»).
  String summary(Map<String, Object?> filter);

  /// Строки данных (без заголовка), от важных к менее важным.
  Future<List<String>> lines(ContextEnv env, Map<String, Object?> filter);
}

/// Раздел собранного контекста (для превью).
@immutable
class ContextSection {
  const ContextSection({
    required this.source,
    required this.label,
    required this.summary,
    required this.text,
    required this.tokens,
    required this.omittedLines,
  });

  final String source;
  final String label;
  final String summary;
  final String text;
  final int tokens;

  /// Сколько строк не поместилось в лимит токенов источника.
  final int omittedLines;
}

/// Собранный контекст: текст для запроса, оценка токенов, чувствительность.
@immutable
class ContextPackage {
  const ContextPackage({
    required this.sections,
    required this.text,
    required this.tokens,
    required this.containsSensitive,
    this.unknownSources = const [],
    this.withheld = false,
  });

  /// Чувствительный контекст не собирался: раздел закрыт замком (превью
  /// показывает только подсказку).
  const ContextPackage.withheld()
    : sections = const [],
      text = '',
      tokens = 0,
      containsSensitive = true,
      unknownSources = const [],
      withheld = true;

  static const empty = ContextPackage(
    sections: [],
    text: '',
    tokens: 0,
    containsSensitive: false,
  );

  final List<ContextSection> sections;

  /// Текст, который уйдёт в `context.text` запроса.
  final String text;
  final int tokens;

  /// Хотя бы один источник помечен «не отправлять в облако».
  final bool containsSensitive;

  /// Источники пресета, которых нет в реестре этой версии приложения.
  final List<String> unknownSources;

  /// См. [ContextPackage.withheld].
  final bool withheld;
}

/// Заголовок блока контекста в запросе.
const String contextHeader =
    '# Данные пользователя из приложения (собраны на устройстве)';

/// Собирает контекст по выбранным источникам.
class ContextBuilder {
  const ContextBuilder(this.sources);

  final List<ContextSource> sources;

  ContextSource? sourceById(String id) {
    for (final s in sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Чувствительность выбора известна без чтения данных.
  bool isSensitive(List<ContextSourceRef> selection) =>
      selection.any((ref) => sourceById(ref.source)?.sensitive ?? false);

  Future<ContextPackage> build(
    List<ContextSourceRef> selection,
    ContextEnv env,
  ) async {
    final sections = <ContextSection>[];
    final unknown = <String>[];
    var sensitive = false;
    for (final ref in selection) {
      final source = sourceById(ref.source);
      if (source == null) {
        unknown.add(ref.source);
        continue;
      }
      sensitive = sensitive || source.sensitive;
      final filter = {...source.defaultFilter, ...ref.filter};
      final all = await source.lines(env, filter);
      final (kept, omitted) = _fit(all, ref.tokenLimit);
      final summary = source.summary(filter);
      final body = kept.isEmpty ? '(нет данных)' : kept.join('\n');
      final tail = omitted == 0 ? '' : '\n… ещё $omitted стр. не поместилось';
      final text = '## ${source.label} ($summary)\n$body$tail';
      sections.add(
        ContextSection(
          source: source.id,
          label: source.label,
          summary: summary,
          text: text,
          tokens: estimateTokens(text),
          omittedLines: omitted,
        ),
      );
    }
    if (sections.isEmpty) {
      return ContextPackage(
        sections: const [],
        text: '',
        tokens: 0,
        containsSensitive: sensitive,
        unknownSources: unknown,
      );
    }
    final text =
        '$contextHeader\n\n${sections.map((s) => s.text).join('\n\n')}';
    return ContextPackage(
      sections: sections,
      text: text,
      tokens: estimateTokens(text),
      containsSensitive: sensitive,
      unknownSources: unknown,
    );
  }

  /// Берёт строки, пока не исчерпан лимит токенов; возвращает взятые и
  /// число отброшенных.
  static (List<String>, int) _fit(List<String> lines, int tokenLimit) {
    final kept = <String>[];
    var used = 0;
    for (final line in lines) {
      final cost = estimateTokens('$line\n');
      if (used + cost > tokenLimit) break;
      kept.add(line);
      used += cost;
    }
    return (kept, lines.length - kept.length);
  }
}
