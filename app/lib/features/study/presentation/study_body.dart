import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_tasker/core/widgets/notice_card.dart';
import 'package:my_tasker/features/study/application/study_providers.dart';
import 'package:my_tasker/features/study/presentation/study_forms.dart';

/// Содержимое экрана «Учёбы»: пока данные читаются — скелетон, при ошибке
/// чтения — красная карточка с «Повторить», иначе [builder].
class StudyBody extends ConsumerWidget {
  const StudyBody({required this.builder, super.key});

  final Widget Function(BuildContext context, StudyData data) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(studyDataProvider)
        .when(
          loading: () => const ListSkeleton(rows: 4),
          error: (error, _) => const StudyErrorCard(
            key: Key('study-error'),
            text: 'Не удалось прочитать данные «Учёбы» на устройстве.',
          ),
          data: (data) => builder(context, data),
        );
  }
}
