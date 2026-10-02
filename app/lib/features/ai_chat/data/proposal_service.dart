import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/config/clock.dart';
import 'package:my_tasker/core/sync/sync_providers.dart';
import 'package:my_tasker/core/sync/sync_store.dart';
import 'package:my_tasker/features/ai_chat/data/ai_repository.dart';
import 'package:my_tasker/features/ai_chat/domain/ai_models.dart';
import 'package:my_tasker/features/ai_chat/domain/proposal_mapping.dart';
import 'package:my_tasker/features/calendar/application/device_timezone.dart';
import 'package:my_tasker/features/calendar/domain/calendar_models.dart';
import 'package:my_tasker/features/tasks/data/task_repository.dart';
import 'package:timezone/timezone.dart' as tz;

/// Итог одобрения.
enum ApprovalOutcome {
  /// Задача создана с `id = entity_id`, предложение одобрено.
  created,

  /// Задача с таким id уже была (двойное нажатие, другое устройство):
  /// создание пропущено, статус предложения поставлен.
  alreadyExisted,

  /// Предложение уже решено — ничего не изменено.
  alreadyDecided,
}

/// Решения по предложениям инструментов (spec Этапа 3, раздел 2).
///
/// «Одно одобрение = ровно одна задача»: задача создаётся с неизменяемым
/// `entity_id`, назначенным сервером, поэтому любое число одобрений
/// (двойное нажатие, два устройства, повтор после потери ответа) даёт
/// одну строку `tasks`.
class ProposalService {
  ProposalService(
    this._store,
    this._tasks, {
    required this._zone,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final SyncStore _store;
  final TaskRepository _tasks;
  final tz.Location Function() _zone;
  final DateTime Function() _now;

  final Map<String, Future<ApprovalOutcome>> _inFlight = {};

  Future<ToolProposal?> getProposal(String id) async {
    final row = await _store.getRow(AiRepository.proposalsTable, id);
    return row == null || row['deleted_at'] != null
        ? null
        : ToolProposal.fromRow(row);
  }

  tz.Location get _userZone {
    final zone = _zone();
    return isIanaLocation(zone) ? zone : tz.UTC;
  }

  /// Сохраняет правки пользователя в `arguments` (пока предложение ждёт
  /// решения). Ошибка проверки — [AiValidationError].
  Future<void> updateArguments(
    String proposalId,
    Map<String, Object?> arguments,
  ) async {
    final problem = proposalProblem(arguments, zone: _userZone);
    if (problem != null) throw AiValidationError(problem);
    await _store.transaction(() async {
      final proposal = await getProposal(proposalId);
      if (proposal == null || !proposal.isPending) return;
      await _store.update(AiRepository.proposalsTable, proposalId, {
        'arguments': arguments,
      });
    });
  }

  /// Одобряет предложение. Параллельные вызовы для одного предложения
  /// делят один результат; повторный вызов после решения ничего не меняет.
  Future<ApprovalOutcome> approve(String proposalId) async {
    final running = _inFlight[proposalId];
    if (running != null) return await running;
    final future = _approve(proposalId);
    _inFlight[proposalId] = future;
    try {
      return await future;
    } finally {
      unawaited(_inFlight.remove(proposalId));
    }
  }

  Future<ApprovalOutcome> _approve(String proposalId) => _store.transaction(
    () async {
      final proposal = await getProposal(proposalId);
      if (proposal == null) {
        throw const AiValidationError('Предложение не найдено');
      }
      if (!proposal.isPending) return ApprovalOutcome.alreadyDecided;
      if (proposal.tool != 'create_task' || proposal.entityType != 'task') {
        throw AiValidationError('Неизвестный инструмент: ${proposal.tool}');
      }
      final args = proposal.arguments;
      final zone = _userZone;
      final problem = proposalProblem(args, zone: zone);
      if (problem != null) throw AiValidationError(problem);

      var outcome = ApprovalOutcome.alreadyExisted;
      // Задача с этим id уже есть (живая или в корзине): не создаём.
      if (await _store.getRow(TaskRepository.tasksTable, proposal.entityId) ==
          null) {
        final projectName = projectFromArguments(args);
        final project = projectName == null
            ? null
            : await _tasks.findProject(projectName);
        await _tasks.createTask(
          taskFromArguments(
            args,
            entityId: proposal.entityId,
            zone: zone,
            projectId: project?.id,
          ),
        );
        final tags = tagsFromArguments(args);
        if (tags.isNotEmpty) await _tasks.setTaskTags(proposal.entityId, tags);
        outcome = ApprovalOutcome.created;
      }
      await _store.update(AiRepository.proposalsTable, proposalId, {
        'status':
            (argumentsDiffer(args, proposal.originalArguments)
                    ? ProposalStatus.editedApproved
                    : ProposalStatus.approved)
                .wire,
        'decided_at': storedInstant(_now().toUtc()),
      });
      return outcome;
    },
  );

  /// Отклоняет предложение; задача не создаётся. Решённое — не меняется.
  Future<bool> reject(String proposalId, {String? reason}) =>
      _store.transaction(() async {
        final proposal = await getProposal(proposalId);
        if (proposal == null || !proposal.isPending) return false;
        final clean = reason?.trim();
        if (clean != null && clean.length > 1000) {
          throw const AiValidationError('Причина не длиннее 1000 знаков');
        }
        await _store.update(AiRepository.proposalsTable, proposalId, {
          'status': ProposalStatus.rejected.wire,
          'reject_reason': clean == null || clean.isEmpty ? null : clean,
          'decided_at': storedInstant(_now().toUtc()),
        });
        return true;
      });
}

final proposalServiceProvider = Provider<ProposalService>(
  (ref) => ProposalService(
    ref.watch(syncStoreProvider),
    ref.watch(taskRepositoryProvider),
    zone: () => ref.read(deviceTimeZoneProvider),
    now: ref.watch(clockProvider),
  ),
);
