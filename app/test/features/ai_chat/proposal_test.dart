import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/calendar_time/wall_time.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/data/proposal_service.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:my_tasker/features/tasks/domain/task_models.dart';

import '../../support/ai_env.dart';
import '../../support/fake_server/fake_sync_server.dart';
import '../../support/manual_clock.dart';

const _conv = '01900000-0000-7000-8000-0000000000c1';
const _message = '01900000-0000-7000-8000-0000000000d1';
const _proposal = '01900000-0000-7000-8000-0000000000e1';
const _entity = '01900000-0000-7000-8000-0000000000f1';

const Map<String, Object> _args = {
  'title': 'Подготовить смету',
  'notes': 'Для Елены',
  'priority': 2,
  'due_date': '2026-10-07',
  'due_time': '15:00',
  'duration_minutes': 60,
  'project': 'Creora',
  'tags': ['работа', 'смета'],
};

/// Устройство с сервисом решений и репозиториями.
class _Dev {
  _Dev(this.device)
    : store = device.container.read(syncStoreProvider),
      service = device.container.read(proposalServiceProvider),
      tasks = device.container.read(taskRepositoryProvider);

  final AiDevice device;
  final SyncStore store;
  final ProposalService service;
  final TaskRepository tasks;

  Future<ToolProposal> proposal() async =>
      (await service.getProposal(_proposal))!;

  /// Все строки задач (включая надгробия) по этому id.
  Future<Map<String, Object?>?> taskRow(String id) => store.getRow('tasks', id);

  Future<int> taskCreateOps() async => (await store.outbox())
      .where((o) => o.table == 'tasks' && o.rowId == _entity)
      .length;
}

void main() {
  late ManualClock clock;
  late FakeSyncServer server;
  late _Dev phone;
  late _Dev pc;

  setUp(() async {
    ensureTimeZones();
    clock = ManualClock(DateTime.utc(2026, 10, 5, 9).millisecondsSinceEpoch);
    server = aiServer(clock);
    phone = await _newDevice(server, clock);
    pc = await _newDevice(server, clock);
    // «Сервер» создаёт чат, ответ и предложение; устройства получают их pull.
    final store = phone.store;
    await store.create('ai_conversations', _conv, {
      'title': 'Смета',
      'topic': 'work',
      'agent_id': null,
      'model': 'openai/gpt-4o',
      'context_preset_id': null,
      'pinned': false,
      'archived': false,
      'mode': 'cloud',
    });
    await store.create('ai_messages', _message, {
      'conversation_id': _conv,
      'role': 'assistant',
      'text': '',
      'parts': [
        {
          'type': 'tool_call',
          'id': 'call_2',
          'name': 'create_task',
          'arguments': _args,
        },
        {
          'type': 'proposal',
          'proposal_id': _proposal,
          'tool_call_id': 'call_2',
          'tool': 'create_task',
        },
      ],
      'status': 'done',
      'finish_reason': 'awaiting_approval',
    });
    await store.create('ai_tool_proposals', _proposal, {
      'message_id': _message,
      'tool_call_id': 'call_2',
      'tool': 'create_task',
      'entity_type': 'task',
      'entity_id': _entity,
      'original_arguments': _args,
      'arguments': _args,
      'status': 'pending',
      'reject_reason': null,
      'decided_at': null,
    });
    await phone.device.sync();
    await pc.device.sync();
  });

  tearDown(() async {
    phone.device.dispose();
    pc.device.dispose();
    await server.dispose();
  });

  test(
    'одобрение: задача с id предложения, статус и outbox по порядку',
    () async {
      await phone.tasks.createProject('Creora');
      final before = (await phone.store.outbox()).length;
      final outcome = await phone.service.approve(_proposal);
      expect(outcome, ApprovalOutcome.created);

      final task = TaskEntity.fromRow((await phone.taskRow(_entity))!);
      expect(task.id, _entity);
      expect(task.title, 'Подготовить смету');
      expect(task.source, TaskSource.ai);
      expect(task.status, TaskStatus.todo);
      expect(task.priority, 2);
      expect(task.durationMinutes, 60);
      expect(task.notes, 'Для Елены');
      // 15:00 по Москве = 12:00 UTC; пояс пользователя записан в задачу.
      expect(task.due.at, DateTime.utc(2026, 10, 7, 12));
      expect(task.due.tz, 'Europe/Moscow');
      expect((await phone.tasks.projects()).single.id, task.projectId);
      expect(
        (await phone.tasks.tagsOfTask(_entity)).map((t) => t.name).toSet(),
        {'работа', 'смета'},
      );

      final proposal = await phone.proposal();
      expect(proposal.status, ProposalStatus.approved);
      expect(proposal.decidedAt, isNotNull);

      // Задача создаётся раньше, чем обновляется предложение (одна пачка).
      final ops = (await phone.store.outbox()).skip(before).toList();
      final taskIndex = ops.indexWhere(
        (o) => o.table == 'tasks' && o.rowId == _entity,
      );
      final proposalIndex = ops.indexWhere(
        (o) => o.table == 'ai_tool_proposals' && o.rowId == _proposal,
      );
      expect(taskIndex, isNonNegative);
      expect(proposalIndex, greaterThan(taskIndex));
    },
  );

  test(
    'правка перед одобрением -> edited_approved, задача по правкам',
    () async {
      await phone.service.updateArguments(_proposal, {
        ..._args,
        'title': 'Смета для Елены',
        'priority': 1,
      });
      expect((await phone.proposal()).isEdited, isTrue);
      expect((await phone.proposal()).status, ProposalStatus.pending);
      await phone.service.approve(_proposal);
      final proposal = await phone.proposal();
      expect(proposal.status, ProposalStatus.editedApproved);
      expect(proposal.arguments['title'], 'Смета для Елены');
      expect(proposal.originalArguments['title'], 'Подготовить смету');
      final task = TaskEntity.fromRow((await phone.taskRow(_entity))!);
      expect(task.title, 'Смета для Елены');
      expect(task.priority, 1);
    },
  );

  test('двойное нажатие: одна задача, один результат', () async {
    final results = await Future.wait([
      phone.service.approve(_proposal),
      phone.service.approve(_proposal),
      phone.service.approve(_proposal),
    ]);
    expect(results.toSet(), {ApprovalOutcome.created});
    expect(await phone.taskCreateOps(), 1);
    // Позднее повторное нажатие ничего не меняет.
    expect(
      await phone.service.approve(_proposal),
      ApprovalOutcome.alreadyDecided,
    );
    expect(await phone.taskCreateOps(), 1);
    final tasks = await phone.store.visibleRows('tasks');
    expect(tasks.where((t) => t['id'] == _entity), hasLength(1));
  });

  test(
    'отклонение: задачи нет, причина записана, решённое не меняется',
    () async {
      expect(
        await phone.service.reject(_proposal, reason: '  Не то время '),
        isTrue,
      );
      final proposal = await phone.proposal();
      expect(proposal.status, ProposalStatus.rejected);
      expect(proposal.rejectReason, 'Не то время');
      expect(proposal.decidedAt, isNotNull);
      expect(await phone.taskRow(_entity), isNull);
      expect(await phone.service.reject(_proposal), isFalse);
      expect(
        await phone.service.approve(_proposal),
        ApprovalOutcome.alreadyDecided,
      );
      expect(await phone.taskRow(_entity), isNull);
      // Правка решённого предложения игнорируется.
      await phone.service.updateArguments(_proposal, {
        ..._args,
        'title': 'Поздно',
      });
      expect((await phone.proposal()).arguments['title'], 'Подготовить смету');
    },
  );

  test('отказ без причины: reject_reason пуст', () async {
    await phone.service.reject(_proposal, reason: '   ');
    expect((await phone.proposal()).rejectReason, isNull);
  });

  test(
    'задача с таким id уже есть: создание пропускается, статус ставится',
    () async {
      await phone.tasks.createTask(
        const TaskEntity(
          id: _entity,
          title: 'Уже создана',
          status: TaskStatus.todo,
        ),
      );
      final outcome = await phone.service.approve(_proposal);
      expect(outcome, ApprovalOutcome.alreadyExisted);
      expect(
        TaskEntity.fromRow((await phone.taskRow(_entity))!).title,
        'Уже создана',
        reason: 'чужая задача не перезаписана',
      );
      expect((await phone.proposal()).status, ProposalStatus.approved);
    },
  );

  test(
    'два устройства одобряют офлайн: после синхронизации одна задача',
    () async {
      phone.device.faults.offline = true;
      pc.device.faults.offline = true;
      await phone.service.approve(_proposal);
      await pc.service.approve(_proposal);
      phone.device.faults.offline = false;
      pc.device.faults.offline = false;
      for (var i = 0; i < 3; i++) {
        await phone.device.sync();
        await pc.device.sync();
      }
      final onServer = server.snapshot('tasks');
      expect(onServer.keys.where((k) => k == _entity), hasLength(1));
      expect(
        onServer.values.where((t) => t['source'] == 'ai'),
        hasLength(1),
        reason: 'дубля задачи нет',
      );
      for (final dev in [phone, pc]) {
        final rows = await dev.store.visibleRows('tasks');
        expect(rows.where((r) => r['id'] == _entity), hasLength(1));
        expect((await dev.proposal()).status, ProposalStatus.approved);
      }
      expect(
        server.snapshot('ai_tool_proposals')[_proposal]!['status'],
        'approved',
      );
    },
  );

  test(
    'одобрить и отклонить на двух устройствах: задача не дублируется',
    () async {
      phone.device.faults.offline = true;
      pc.device.faults.offline = true;
      await phone.service.approve(_proposal);
      clock.advance(const Duration(seconds: 5));
      await pc.service.reject(_proposal, reason: 'Не нужна');
      phone.device.faults.offline = false;
      pc.device.faults.offline = false;
      for (var i = 0; i < 3; i++) {
        await phone.device.sync();
        await pc.device.sync();
      }
      // Принятое поведение (spec 2, п. 6): статус решается по полям (LWW),
      // но дубля задачи нет, а устройства сходятся к одному значению.
      expect(
        server.snapshot('tasks').keys.where((k) => k == _entity),
        hasLength(1),
      );
      final a = (await phone.proposal()).status;
      final b = (await pc.proposal()).status;
      expect(a, b);
      expect(a, anyOf(ProposalStatus.approved, ProposalStatus.rejected));
    },
  );

  test(
    'одобрение чужой строки proposals с другого устройства видно через pull',
    () async {
      await phone.service.approve(_proposal);
      await phone.device.sync();
      await pc.device.sync();
      expect((await pc.proposal()).status, ProposalStatus.approved);
      expect(await pc.taskRow(_entity), isNotNull);
      // Кнопка на втором устройстве уже не создаёт ничего.
      expect(
        await pc.service.approve(_proposal),
        ApprovalOutcome.alreadyDecided,
      );
      expect(await pc.taskCreateOps(), 0);
    },
  );

  test(
    'неверные аргументы: предложение остаётся ожидающим, задачи нет',
    () async {
      await expectLater(
        phone.service.updateArguments(_proposal, {..._args, 'title': '  '}),
        throwsA(isA<AiValidationError>()),
      );
      await expectLater(
        phone.service.updateArguments(_proposal, {
          ..._args,
          'due_date': '07.10.2026',
        }),
        throwsA(isA<AiValidationError>()),
      );
      expect((await phone.proposal()).status, ProposalStatus.pending);
      expect(await phone.taskRow(_entity), isNull);
    },
  );

  test(
    'неизвестный проект не создаётся, а несуществующее предложение — ошибка',
    () async {
      await phone.service.approve(_proposal);
      final task = TaskEntity.fromRow((await phone.taskRow(_entity))!);
      expect(task.projectId, isNull, reason: 'проект ищется, но не создаётся');
      expect(await phone.tasks.projects(), isEmpty);
      await expectLater(
        phone.service.approve('00000000-0000-7000-8000-00000000dead'),
        throwsA(isA<AiValidationError>()),
      );
      expect(
        await phone.service.reject('00000000-0000-7000-8000-00000000dead'),
        isFalse,
      );
    },
  );
}

Future<_Dev> _newDevice(FakeSyncServer server, ManualClock clock) async {
  final device = await AiDevice.create(server, clock: clock);
  return _Dev(device);
}
