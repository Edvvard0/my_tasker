import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/network/api_client.dart';
import 'package:my_tasker/features/banks/data/statements_api.dart';

import '../../support/banks_env.dart';

class _Recording implements HttpClientAdapter {
  _Recording(this.respond);

  final ResponseBody Function(RequestOptions o) respond;
  final List<RequestOptions> seen = [];
  final List<List<int>> bodies = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    final bytes = <int>[];
    if (requestStream != null) {
      await requestStream.forEach(bytes.addAll);
    }
    bodies.add(bytes);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Object? body) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

ApiClient _client(HttpClientAdapter adapter) => ApiClient(
  dio: ApiClient.createDio(baseUrl: Uri.parse('http://x'), adapter: adapter),
  schemaVersion: 1,
);

/// `POST /banks/statements/parse`: сырые байты в теле, параметры в query,
/// разбор ответа и ошибок по кодам контракта.
void main() {
  test('файл уходит сырыми байтами, ответ разбирается в кандидатов', () async {
    final adapter = _Recording(
      (o) => _json(200, {
        'format': 'csv',
        'bank': 'tbank',
        'period': {'from': '2026-09-01', 'to': '2026-09-30'},
        'closing_balance': {'amount': 100, 'at': '2026-09-30T20:59:59Z'},
        'cards': ['1234'],
        'candidates': [
          serverLine(
            index: 0,
            occurredAt: '2026-09-10T09:00:00Z',
            kind: 'expense',
            amount: 50000,
            merchant: 'Кофе',
            card: '1234',
          ),
        ],
        'skipped': <Object?>[],
      }),
    );
    final api = HttpStatementsApi(() async => _client(adapter));
    final result = await api.parse(
      Uint8List.fromList([1, 2, 3, 4]),
      format: 'csv',
      bank: 'tbank',
    );
    expect(result.bank, 'tbank');
    expect(result.lines.single.amount, 50000);
    expect(result.cards, ['1234']);
    expect(result.closingBalance!.amount, 100);

    final request = adapter.seen.single;
    expect(request.method, 'POST');
    expect(request.path, '/banks/statements/parse');
    expect(request.queryParameters, {'format': 'csv', 'bank': 'tbank'});
    expect(request.headers['content-type'], 'application/octet-stream');
    expect(request.headers['X-Client-Schema-Version'], '1');
    expect(adapter.bodies.single, [1, 2, 3, 4]);
    // Разбор на сервере долгий: таймауты больше обычных.
    expect(request.receiveTimeout, const Duration(seconds: 60));
    expect(request.sendTimeout, const Duration(seconds: 60));
  });

  test('без параметров: bank=auto, формат определяет сервер', () async {
    final adapter = _Recording(
      (o) => _json(200, {
        'format': 'xlsx',
        'bank': 'generic',
        'candidates': <Object?>[],
      }),
    );
    final api = HttpStatementsApi(() async => _client(adapter));
    await api.parse(Uint8List(1));
    expect(adapter.seen.single.queryParameters, {'bank': 'auto'});
  });

  test('ошибки сервера: код и понятный русский текст', () async {
    for (final (code, status, text) in [
      ('empty_file', 400, 'Файл пустой.'),
      ('payload_too_large', 413, 'Файл больше 10 МБ'),
      ('statement_unrecognized', 422, 'таблицы с датами'),
      ('statement_unreadable', 422, 'повреждён'),
      ('statement_format_mismatch', 422, 'Формат файла'),
      ('statement_too_large', 422, 'слишком большая'),
      ('weird', 500, 'Повторите позже'),
    ]) {
      final adapter = _Recording(
        (o) => _json(status, {
          'error': {'code': code, 'message': code},
        }),
      );
      final api = HttpStatementsApi(() async => _client(adapter));
      Object? caught;
      try {
        await api.parse(Uint8List(1));
      } on ApiException catch (e) {
        caught = e;
        expect(e.code, code);
      }
      expect(caught, isNotNull, reason: code);
      expect(statementErrorText(caught!), contains(text), reason: code);
    }
  });

  test('413 без кода в JSON (отказ прокси) — то же сообщение о размере', () {
    expect(
      statementErrorText(
        const ApiException(kind: ApiErrorKind.http, status: 413),
      ),
      statementTooBigText,
    );
    expect(statementTooBigText, contains('10 МБ'));
    expect(maxStatementBytes, 10000000);
  });

  test('нет сети, сервер не настроен, ответ не по контракту', () async {
    final offline = HttpStatementsApi(
      () async => throw const ApiException.network(),
    );
    await expectLater(
      offline.parse(Uint8List(1)),
      throwsA(isA<ApiException>()),
    );
    expect(
      statementErrorText(const ApiException.network()),
      contains('Нет соединения'),
    );
    final unconfigured = HttpStatementsApi(() async => null);
    Object? notConfigured;
    try {
      await unconfigured.parse(Uint8List(1));
    } on ApiException catch (e) {
      notConfigured = e;
    }
    expect(statementErrorText(notConfigured!), contains('Сервер не настроен'));

    final adapter = _Recording(
      (o) => _json(200, {
        'candidates': [
          {'index': 'не число', 'amount': 'x'},
        ],
      }),
    );
    final api = HttpStatementsApi(() async => _client(adapter));
    Object? malformed;
    try {
      await api.parse(Uint8List(1));
    } on ApiException catch (e) {
      malformed = e;
      expect(e.kind, ApiErrorKind.malformed);
    }
    expect(malformed, isNotNull);
    expect(statementErrorText(StateError('x')), contains('Повторите позже'));
  });
}
