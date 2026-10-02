import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/db/database_providers.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';

/// Выбор источников контекста в конкретном чате (spec 02, 5.2.3):
/// пресет целиком либо свой набор. Изменения действуют только на этот чат.
@immutable
class ChatContextSelection {
  const ChatContextSelection({this.presetId, this.sources = const []});

  /// Применённый пресет без изменений (его чувствительность проверяет и
  /// сервер: `preset_id` в запросе); после ручной правки — `null`.
  final String? presetId;
  final List<ContextSourceRef> sources;

  bool get isEmpty => sources.isEmpty;

  bool has(String source) => sources.any((s) => s.source == source);

  ContextSourceRef? of(String source) {
    for (final s in sources) {
      if (s.source == source) return s;
    }
    return null;
  }
}

/// Ключ локальной настройки с выбором контекста чата. Хранится на
/// устройстве: выбор — удобство, на сервер уходит собранный текст.
String chatContextKey(String conversationId) =>
    'ai.chat_context.$conversationId';

/// Выбор контекста чата. Загружается из локальных настроек; пока не
/// загружен — пустой. Правки сразу сохраняются.
class ChatContextNotifier extends Notifier<ChatContextSelection> {
  ChatContextNotifier(this.conversationId);

  final String conversationId;
  Future<void>? _loading;
  bool _touched = false;

  @override
  ChatContextSelection build() {
    // Notifier переиспользуется при пересборке провайдера: сбрасываем флаг.
    _touched = false;
    _loading = _load();
    return const ChatContextSelection();
  }

  /// Завершается, когда сохранённый выбор прочитан.
  Future<void> get ready => _loading ?? Future<void>.value();

  Future<void> _load() async {
    try {
      final raw = await ref
          .read(localSettingsRepositoryProvider)
          .read(chatContextKey(conversationId));
      if (raw == null || !ref.mounted || _touched) return;
      final json = jsonDecode(raw) as Map<String, Object?>;
      state = ChatContextSelection(
        presetId: json['preset_id'] as String?,
        sources: [
          for (final s in (json['sources'] as List<Object?>? ?? const []))
            ContextSourceRef.fromJson(s),
        ],
      );
    } on Object {
      // Выбор — удобство: без него чат начинается с пустого контекста.
    }
  }

  Future<void> _save() async {
    try {
      await ref
          .read(localSettingsRepositoryProvider)
          .write(
            chatContextKey(conversationId),
            jsonEncode({
              'preset_id': state.presetId,
              'sources': [for (final s in state.sources) s.toJson()],
            }),
          );
    } on Object {
      // Не записалось — выбор действует до закрытия приложения.
    }
  }

  void _set(ChatContextSelection next) {
    _touched = true;
    state = next;
    unawaited(_save());
  }

  /// Начальный выбор нового чата (из пресета агента); не затирает
  /// уже сохранённое.
  void seed(ContextPreset? preset) {
    if (preset == null || state.sources.isNotEmpty || _touched) return;
    state = ChatContextSelection(presetId: preset.id, sources: preset.sources);
  }

  void applyPreset(ContextPreset preset) =>
      _set(ChatContextSelection(presetId: preset.id, sources: preset.sources));

  void clear() => _set(const ChatContextSelection());

  /// Включает или выключает источник ([initial] — фильтр по умолчанию).
  void toggle(String source, ContextSourceRef initial) {
    final next = state.has(source)
        ? [
            for (final s in state.sources)
              if (s.source != source) s,
          ]
        : [...state.sources, initial];
    _set(ChatContextSelection(sources: next));
  }

  void setFilter(String source, Map<String, Object?> filter) => _set(
    ChatContextSelection(
      sources: [
        for (final s in state.sources)
          if (s.source == source) s.copyWith(filter: filter) else s,
      ],
    ),
  );
}

// Тип семейства Riverpod 3 недоступен из публичного API.
// ignore: specify_nonobvious_property_types
final chatContextProvider =
    NotifierProvider.family<ChatContextNotifier, ChatContextSelection, String>(
      ChatContextNotifier.new,
    );
