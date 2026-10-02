import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/local_llm/idle_unloader.dart';

void main() {
  test('выгружает модель после паузы; активность сбрасывает отсчёт', () {
    fakeAsync((async) {
      var unloads = 0;
      final idle = IdleUnloader(unload: () async => unloads++)..touch();
      async.elapse(const Duration(minutes: 4));
      idle.touch(); // новый ответ — отсчёт заново
      async.elapse(const Duration(minutes: 4));
      expect(unloads, 0);
      async.elapse(const Duration(minutes: 2));
      expect(unloads, 1);
      idle.dispose();
    });
  });

  test('во время ответа таймер остановлен', () {
    fakeAsync((async) {
      var unloads = 0;
      final idle =
          IdleUnloader(
              unload: () async => unloads++,
              after: const Duration(minutes: 1),
            )
            ..touch()
            ..hold();
      async.elapse(const Duration(minutes: 10));
      expect(unloads, 0);
      idle.touch();
      async.elapse(const Duration(minutes: 2));
      expect(unloads, 1);
    });
  });
}
