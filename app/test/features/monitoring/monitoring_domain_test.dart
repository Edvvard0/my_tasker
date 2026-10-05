import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_format.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_models.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_stats.dart';
import 'package:my_tasker/features/monitoring/domain/monitoring_validation.dart';

MonitorCheck _check({
  CheckKind kind = CheckKind.http,
  String name = 'Главная',
  String? url,
  String? host,
  int? port,
  String? record,
  String? expected,
  int? status,
  String? keyword,
  int? days,
  int interval = 20,
  int timeout = 5,
}) => MonitorCheck(
  id: 'c1',
  serviceId: 's1',
  kind: kind,
  name: name,
  url: url,
  host: host,
  port: port,
  dnsRecordType: record,
  expectedValue: expected,
  expectedStatus: status,
  keyword: keyword,
  sslMinDays: days,
  intervalSeconds: interval,
  timeoutSeconds: timeout,
);

void main() {
  group('валидация проверок (те же правила, что на сервере)', () {
    test('корректные проверки всех видов', () {
      expect(checkProblem(_check(url: 'https://example.com')), isNull);
      expect(
        checkProblem(
          _check(url: 'https://example.com/health', status: 200, keyword: 'ok'),
        ),
        isNull,
      );
      expect(
        checkProblem(
          _check(kind: CheckKind.tcp, host: 'db.example.com', port: 5432),
        ),
        isNull,
      );
      expect(
        checkProblem(
          _check(
            kind: CheckKind.dns,
            host: 'example.com',
            record: 'MX',
            expected: 'mail.example.com',
          ),
        ),
        isNull,
      );
      expect(
        checkProblem(
          _check(
            kind: CheckKind.ssl,
            host: 'example.com',
            port: 8443,
            days: 30,
          ),
        ),
        isNull,
      );
      expect(
        checkProblem(_check(kind: CheckKind.ssl, host: '8.8.8.8')),
        isNull,
      );
    });

    test('цель с SSRF-отказом называет причину по-русски', () {
      expect(
        checkProblem(_check(url: 'http://localhost')),
        contains('Имя без точки'),
      );
      expect(
        checkProblem(_check(url: 'http://169.254.169.254/latest')),
        contains('внутренней сети'),
      );
      expect(
        checkProblem(_check(url: 'https://user:pw@example.com')),
        contains('Логин и пароль'),
      );
      expect(
        checkProblem(_check(kind: CheckKind.tcp, host: '10.0.0.5', port: 22)),
        contains('внутренней сети'),
      );
      expect(
        checkProblem(_check(kind: CheckKind.ssl, host: 'nas.lan')),
        contains('Внутренняя зона'),
      );
      expect(checkProblem(_check(url: 'example.com')), contains('http://'));
      expect(checkProblem(_check(url: '')), 'Укажите адрес');
    });

    test('обязательные поля вида и чужие колонки', () {
      expect(
        checkProblem(_check(kind: CheckKind.tcp, host: 'example.com')),
        'Укажите порт',
      );
      expect(
        checkProblem(
          _check(kind: CheckKind.tcp, host: 'example.com', port: 70000),
        ),
        contains('от 1 до 65535'),
      );
      expect(
        checkProblem(_check(kind: CheckKind.dns, host: 'example.com')),
        'Выберите тип записи',
      );
      expect(
        checkProblem(
          _check(kind: CheckKind.dns, host: 'example.com', record: 'SRV'),
        ),
        'Неизвестный тип записи',
      );
      // `url` не годится проверке TCP; `keyword` — проверке SSL.
      expect(
        checkProblem(
          _check(
            kind: CheckKind.tcp,
            host: 'example.com',
            port: 22,
            url: 'https://example.com',
          ),
        ),
        contains('не подходит к проверке TCP'),
      );
      expect(
        checkProblem(
          _check(kind: CheckKind.ssl, host: 'example.com', keyword: 'x'),
        ),
        contains('не подходит к проверке SSL'),
      );
    });

    test('ключевое слово, ожидаемое значение, коды и дни', () {
      expect(
        checkProblem(_check(url: 'https://example.com', keyword: 'two words')),
        contains('Ключевое слово'),
      );
      expect(
        checkProblem(_check(url: 'https://example.com', keyword: 'a*b')),
        contains('Ключевое слово'),
      );
      expect(
        checkProblem(_check(url: 'https://example.com', status: 99)),
        contains('от 100 до 599'),
      );
      expect(
        checkProblem(
          _check(
            kind: CheckKind.dns,
            host: 'example.com',
            record: 'A',
            expected: 'bad value',
          ),
        ),
        contains('Ожидаемое значение'),
      );
      expect(
        checkProblem(
          _check(kind: CheckKind.ssl, host: 'example.com', days: 400),
        ),
        contains('от 1 до 365'),
      );
    });

    test('интервал, таймаут (строго меньше интервала) и название', () {
      const url = 'https://example.com';
      expect(
        checkProblem(_check(url: url, interval: 9)),
        contains('от 10 до 3600'),
      );
      expect(
        checkProblem(_check(url: url, interval: 3601)),
        contains('от 10 до 3600'),
      );
      expect(
        checkProblem(_check(url: url, timeout: 0)),
        contains('от 1 до 30'),
      );
      expect(
        checkProblem(_check(url: url, interval: 40, timeout: 31)),
        contains('от 1 до 30'),
      );
      expect(
        checkProblem(_check(url: url, interval: 10, timeout: 10)),
        'Таймаут должен быть меньше интервала',
      );
      expect(checkProblem(_check(url: url, interval: 10, timeout: 9)), isNull);
      expect(checkProblem(_check(url: url, name: '  ')), contains('название'));
      expect(
        checkProblem(_check(url: url, name: 'я' * 101)),
        contains('не длиннее 100'),
      );
    });

    test('сервер и сервис', () {
      MonitorServer server({
        String name = 'VPS',
        String host = 'example.com',
      }) => MonitorServer(id: 's', name: name, host: host);
      expect(serverProblem(server()), isNull);
      expect(serverProblem(server(name: '')), contains('название'));
      expect(
        serverProblem(server(host: 'localhost')),
        contains('Имя без точки'),
      );
      expect(
        serverProblem(server(host: '192.168.1.1')),
        contains('внутренней'),
      );
      expect(serverProblem(server(host: '')), 'Укажите адрес');
      expect(
        serverProblem(
          MonitorServer(
            id: 's',
            name: 'a',
            host: 'example.com',
            provider: 'p' * 101,
          ),
        ),
        contains('Провайдер'),
      );
      expect(
        serverProblem(
          MonitorServer(
            id: 's',
            name: 'a',
            host: 'example.com',
            note: 'n' * 2001,
          ),
        ),
        'Заметка слишком длинная',
      );
      expect(
        serviceProblem(const MonitorService(id: 'x', serverId: 's', name: ' ')),
        contains('название'),
      );
      expect(
        serviceProblem(
          const MonitorService(id: 'x', serverId: 's', name: 'Сайт'),
        ),
        isNull,
      );
    });

    test('все причины цели имеют русский текст', () {
      for (final r in [
        'empty',
        'too_long',
        'bad_chars',
        'non_global_ip',
        'single_label',
        'bad_label',
        'bad_tld',
        'reserved_name',
        'scheme',
        'userinfo',
        'fragment',
        'bad_port',
        'bad_url',
        'no_host',
      ]) {
        expect(targetReasonText(r), isNot(targetReasonText('новая_причина')));
      }
      expect(targetReasonText(null), 'Адрес не подходит для проверки');
    });
  });

  group('модели', () {
    test('строки читаются мягко, а toFields даёт колонки для записи', () {
      final check = MonitorCheck.fromRow(const {
        'id': 'c1',
        'service_id': 's1',
        'kind': 'новый_вид',
        'name': 'x',
        'interval_seconds': null,
        'timeout_seconds': null,
      });
      expect(check.kind, CheckKind.http);
      expect(check.intervalSeconds, MonitorCheck.defaultInterval);
      expect(check.timeoutSeconds, MonitorCheck.defaultTimeout);
      final c = _check(kind: CheckKind.tcp, host: 'example.com', port: 22);
      expect(
        c.toFields().keys,
        containsAll(['name', 'host', 'port', 'interval_seconds']),
      );
      expect(c.toFields().containsKey('kind'), isFalse);
      expect(c.toFields().containsKey('service_id'), isFalse);
      expect(
        const MonitorService(
          id: 'a',
          serverId: 's',
          name: 'n',
        ).toFields().containsKey('server_id'),
        isFalse,
      );
      final s = MonitorService.fromRow(const {
        'id': 'a',
        'server_id': 's',
        'name': 'n',
        'critical': true,
      });
      expect(s.critical, isTrue);
      expect(
        s.copyWith(critical: false, workProjectId: 'p').workProjectId,
        'p',
      );
      expect(
        const MonitorServer(
          id: 'a',
          name: 'n',
          host: 'h',
        ).copyWith(provider: 'p', note: 'q', name: 'm', host: 'g').toFields(),
        {'name': 'm', 'host': 'g', 'provider': 'p', 'note': 'q'},
      );
    });

    test('цель проверки одной строкой', () {
      expect(_check(url: 'https://a.ru').target, 'https://a.ru');
      expect(
        _check(kind: CheckKind.tcp, host: 'a.ru', port: 22).target,
        'a.ru:22',
      );
      expect(
        _check(kind: CheckKind.dns, host: 'a.ru', record: 'MX').target,
        'MX a.ru',
      );
      expect(_check(kind: CheckKind.ssl, host: 'a.ru').target, 'a.ru');
      expect(
        _check(kind: CheckKind.ssl, host: 'a.ru', port: 443).target,
        'a.ru',
      );
      expect(
        _check(kind: CheckKind.ssl, host: 'a.ru', port: 8443).target,
        'a.ru:8443',
      );
      expect(checkSummary(_check(url: 'https://a.ru')), 'HTTP · https://a.ru');
    });

    test('снимок «Пульса» разбирается: сервисы, проверки, spark, итоги', () {
      final snap = PulseSnapshot.fromJson(const {
        'generated_at': '2026-10-05T10:00:00Z',
        'engine': {
          'configured': true,
          'last_poll_at': '2026-10-05T09:59:55Z',
          'healthy': true,
          'error': null,
          'telegram_configured': true,
        },
        'summary': {'services': 2, 'down': 1, 'up': 1, 'unknown': 0},
        'services': [
          {
            'id': 's1',
            'server_id': 'v1',
            'name': 'Сайт',
            'server': 'VPS',
            'critical': true,
            'status': 'down',
            'down_since': '2026-10-05T09:48:00Z',
            'availability': {'h24': 9884, 'd7': null, 'd30': 10000},
            'response_ms': 178,
            'open_incident': 'i1',
            'checks': [
              {
                'id': 'c1',
                'kind': 'http',
                'name': 'Главная',
                'status': 'down',
                'problem': 'resolve_failed',
                'last_at': '2026-10-05T09:59:50Z',
                'response_ms': null,
                'availability': {'h24': 9000},
                'spark': [100, -1, 120, 'мусор'],
              },
              {
                'id': 'c2',
                'kind': 'ssl',
                'name': 'SSL',
                'status': 'странный',
                'spark': 'нет',
              },
            ],
          },
          'не сервис',
        ],
      });
      expect(snap.total, 1);
      expect(snap.down, 1);
      expect(snap.engine.healthy, isTrue);
      final s = snap.services.single;
      expect(s.status, PulseStatus.down);
      expect(s.critical, isTrue);
      expect(s.availability.h24, 9884);
      expect(s.availability.d7, isNull);
      expect(s.problems.single.id, 'c1');
      expect(s.checks.first.spark, [100, -1, 120]);
      expect(s.checks.last.status, PulseStatus.unknown);
      expect(s.spark, [100, -1, 120]);
      expect(s.checks.last.spark, isEmpty);
    });

    test('итоги считаются по сервисам, если сервер их не прислал', () {
      final snap = PulseSnapshot.fromJson(const {
        'services': [
          {'id': 'a', 'status': 'up'},
          {'id': 'b', 'status': 'unknown'},
        ],
      });
      expect((snap.up, snap.down, snap.unknown), (1, 0, 1));
      expect(snap.engine.configured, isFalse);
      expect(snap.generatedAt, isNull);
    });

    test('страница инцидентов: курсор — пара, туда и обратно', () {
      final page = IncidentPage.fromJson(const {
        'incidents': [
          {
            'id': 'i1',
            'service_id': 's1',
            'service_name': null,
            'started_at': '2026-10-05T09:48:00Z',
            'ended_at': null,
            'duration_seconds': null,
            'reason': 'HTTP 502',
            'check_ids': ['c1'],
          },
        ],
        'next_before': '2026-10-05T09:48:00Z',
        'next_before_id': 'i1',
      });
      expect(page.incidents.single.isOpen, isTrue);
      expect(page.incidents.single.serviceName, isNull);
      expect(page.next, const IncidentCursor('2026-10-05T09:48:00Z', 'i1'));
      expect(
        page.next.hashCode,
        const IncidentCursor('2026-10-05T09:48:00Z', 'i1').hashCode,
      );
      final again = IncidentPage.fromJson(page.toJson());
      expect(again.next, page.next);
      expect(again.incidents.single.checkIds, ['c1']);
      // Без второй половины курсора следующей страницы нет.
      expect(
        IncidentPage.fromJson(const {'incidents': [], 'next_before': 'x'}).next,
        isNull,
      );
    });

    test('самопроверка и результат теста Telegram', () {
      final s = SelfCheck.fromJson(const {
        'engine': {
          'configured': true,
          'last_poll_at': 'x',
          'lag_seconds': 3,
          'error': null,
        },
        'config': {
          'synced_at': 'y',
          'checks_active': 4,
          'checks_rejected': [
            {'check_id': 'c9', 'reason': 'resolve_failed'},
          ],
        },
        'telegram': {
          'configured': false,
          'last_success_at': null,
          'last_error': 'not_configured',
          'queued': 2,
        },
      });
      expect(s.checksActive, 4);
      expect(s.rejected.single.checkId, 'c9');
      expect(s.queued, 2);
      expect(s.telegramConfigured, isFalse);
      final empty = SelfCheck.fromJson(const {});
      expect(empty.engineConfigured, isFalse);
      expect(empty.rejected, isEmpty);
      expect(
        TelegramTestResult.fromJson(const {
          'ok': false,
          'error': 'rate_limited',
        }).error,
        'rate_limited',
      );
      expect(TelegramTestResult.fromJson(const {'ok': true}).ok, isTrue);
    });
  });

  group('доступность и отклик', () {
    test('формат в процентах: сотые доли, без хвостовых нулей', () {
      expect(formatAvailability(null), '—');
      expect(formatAvailability(10000), '100 %');
      expect(formatAvailability(9884), '98,84 %');
      expect(formatAvailability(9990), '99,9 %');
      expect(formatAvailability(9905), '99,05 %');
      expect(formatAvailability(9900), '99 %');
      expect(formatAvailability(0), '0 %');
      expect(formatAvailability(7), '0,07 %');
    });

    test('формат отклика', () {
      expect(formatResponse(null), '—');
      expect(formatResponse(178), '178 мс');
      expect(formatResponse(999), '999 мс');
      expect(formatResponse(1000), '1 с');
      expect(formatResponse(1234), '1,2 с');
    });

    test('пороги подсветки: < 99 % и > 500 мс', () {
      expect(availabilityWarns(9899), isTrue);
      expect(availabilityWarns(9900), isFalse);
      expect(availabilityWarns(null), isFalse);
      expect(responseWarns(501), isTrue);
      expect(responseWarns(500), isFalse);
      expect(responseWarns(null), isFalse);
    });
  });

  group('тексты', () {
    test('причина проверки, которая не запускается', () {
      expect(problemText('resolve_failed'), contains('не разрешается'));
      expect(problemText('resolves_to_non_global'), contains('внутренний'));
      expect(problemText('no_address'), contains('нет адреса'));
      expect(problemText('target_single_label'), contains('Имя без точки'));
      expect(problemText('что-то новое'), contains('что-то новое'));
    });

    test('длительности', () {
      expect(durationShort(45), '45 с');
      expect(durationShort(720), '12 мин');
      expect(durationShort(3900), '1 ч 5 мин');
      expect(durationShort(7200), '2 ч');
      expect(durationShort(90000), '1 дн. 1 ч');
      expect(durationShort(172800), '2 дн.');
      expect(intervalText(20), 'каждые 20 с');
    });

    test('статусы, ошибки Telegram и движка', () {
      expect(statusLabel(PulseStatus.up), 'Работает');
      expect(statusLabel(PulseStatus.down), 'Лежит');
      expect(statusLabel(PulseStatus.unknown), 'Нет данных');
      expect(telegramErrorText(null), '');
      expect(telegramErrorText('rate_limited'), contains('раз в 10 секунд'));
      expect(telegramErrorText('unauthorized'), contains('токен'));
      expect(telegramErrorText('chat_not_found'), contains('TELEGRAM_CHAT_ID'));
      expect(telegramErrorText('network'), contains('Telegram'));
      expect(telegramErrorText('server_error'), contains('Telegram'));
      expect(telegramErrorText('bad_request'), contains('отклонил'));
      expect(telegramErrorText('bad_response'), contains('непонятно'));
      expect(telegramErrorText('dunno'), contains('dunno'));
      expect(engineErrorText(null), 'движок не отвечает');
      expect(engineErrorText('timeout'), 'движок не отвечает: timeout');
      expect(incidentReason(null), 'без причины');
      expect(incidentReason(' HTTP 502 '), 'HTTP 502');
    });

    test('момент ответа сервера', () {
      expect(parseMoment(null), isNull);
      expect(
        parseMoment('2026-10-05T10:00:00Z'),
        DateTime.utc(2026, 10, 5, 10),
      );
      expect(parseMoment('вчера'), isNull);
      expect(incidentMoment('вчера', DateTime.utc(2026, 10, 5)), 'вчера');
    });
  });
}
