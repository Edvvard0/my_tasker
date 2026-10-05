import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/core/network/api_providers.dart';
import 'package:my_tasker/features/banks/domain/statement_models.dart';

/// `POST /banks/statements/parse` глазами клиента (spec `stage6_banks.md`,
/// раздел 6). Сервер разбирает файл в памяти и не хранит его; операций на
/// сервере не создаётся — возвращаются кандидаты.
abstract interface class StatementsApi {
  /// Разбирает [bytes] выписки. [format] (`csv|xlsx|pdf`) и [bank]
  /// (`auto|tbank|vtb|generic`) необязательны.
  Future<ParsedStatement> parse(
    Uint8List bytes, {
    String? format,
    String bank = 'auto',
  });
}

/// [StatementsApi] поверх [ApiClient]: закреплённый сертификат, токен
/// доступа и его обновление — как у остальных запросов.
class HttpStatementsApi implements StatementsApi {
  HttpStatementsApi(this._client);

  final Future<ApiClient?> Function() _client;

  @override
  Future<ParsedStatement> parse(
    Uint8List bytes, {
    String? format,
    String bank = 'auto',
  }) async {
    final client = await _client();
    if (client == null) throw const ApiException.notConfigured();
    final json = await client.postBytes(
      '/banks/statements/parse',
      bytes,
      query: {'format': ?format, 'bank': bank},
    );
    try {
      return ParsedStatement.fromJson(json);
    } on Object {
      throw const ApiException(kind: ApiErrorKind.malformed);
    }
  }
}

final Provider<StatementsApi> statementsApiProvider = Provider<StatementsApi>(
  (ref) => HttpStatementsApi(ref.read(apiClientResolverProvider)),
);

/// Предел размера файла выписки: 10 МБ в СИ (10 000 000 байт), как в Caddy и
/// на сервере (`BANKS_STATEMENT_MAX_BYTES`).
const int maxStatementBytes = 10000000;

/// Сообщение о слишком большом файле (до загрузки и при `413`).
const String statementTooBigText =
    'Файл больше 10 МБ: выберите выписку поменьше.';

/// Понятное сообщение об ошибке разбора выписки (коды раздела 6).
String statementErrorText(Object error) {
  if (error is ApiException) {
    if (error.isNetwork) {
      return 'Нет соединения с сервером. Разбор выписки идёт на сервере: '
          'подключитесь к сети и повторите.';
    }
    // 413 может прийти и без JSON-кода (отказ прокси раньше приложения).
    if (error.status == 413) return statementTooBigText;
    return switch (error.code) {
      'empty_file' => 'Файл пустой.',
      'payload_too_large' => statementTooBigText,
      'statement_unrecognized' =>
        'В файле не нашлось таблицы с датами и суммами. Нужна выписка '
            'в CSV, XLSX или PDF.',
      'statement_unreadable' => 'Файл повреждён или не читается.',
      'statement_format_mismatch' => 'Формат файла не совпал с заявленным.',
      'statement_too_large' => 'Выписка слишком большая для разбора.',
      'not_configured' => 'Сервер не настроен: укажите адрес в настройках.',
      _ => 'Не удалось разобрать выписку. Повторите позже.',
    };
  }
  return 'Не удалось разобрать выписку. Повторите позже.';
}
