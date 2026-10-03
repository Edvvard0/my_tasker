import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/features/finance/data/finance_privacy_store.dart';
import 'package:my_tasker/features/finance/domain/finance_lock_models.dart';

import '../../../support/finance_ui_env.dart';
import '../../../support/privacy_env.dart';
import '../../../support/pump_app.dart';

/// Вводит PIN в окне создания (4–6 цифр) и жмёт «Далее».
Future<void> _typeAndNext(WidgetTester tester, String pin) async {
  for (final digit in pin.split('')) {
    await tester.tap(find.byKey(Key('pin-key-$digit')));
    await tester.pump();
  }
  await tester.tap(find.byKey(const Key('pin-submit')));
  await tester.pumpAndSettle();
}

Future<MemoryFinancePrivacyStore> _open(
  WidgetTester tester, {
  MemoryFinancePrivacyStore? store,
  FakeBiometric? biometric,
  Size size = phoneSize,
}) async {
  final s = store ?? MemoryFinancePrivacyStore();
  await pumpFinance(
    tester,
    size: size,
    location: '/finance/privacy',
    privacyStore: s,
    biometric: biometric,
  );
  return s;
}

void main() {
  group('экран «Приватность»', () {
    testWidgets('замка нет: только «скрывать суммы» и «замок раздела»', (
      tester,
    ) async {
      await _open(tester);
      expect(find.byKey(const Key('privacy-screen')), findsOneWidget);
      expect(find.byKey(const Key('privacy-hide-switch')), findsOneWidget);
      expect(find.byKey(const Key('privacy-lock-switch')), findsOneWidget);
      expect(find.byKey(const Key('privacy-change-pin')), findsNothing);
      expect(find.byKey(const Key('privacy-timing-1m')), findsNothing);
      expect(find.byKey(const Key('privacy-note')), findsOneWidget);
    });

    testWidgets('«скрывать суммы» переключается и запоминается', (
      tester,
    ) async {
      final store = await _open(tester);
      await tester.tap(find.byKey(const Key('privacy-hide-switch')));
      await tester.pumpAndSettle();
      expect(store.hidden, isTrue);
      await tester.tap(find.byKey(const Key('privacy-hide-switch')));
      await tester.pumpAndSettle();
      expect(store.hidden, isFalse);
    });

    testWidgets('включение замка: PIN дважды, запись без открытого PIN', (
      tester,
    ) async {
      final store = await _open(tester);
      await tester.tap(find.byKey(const Key('privacy-lock-switch')));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'pin-title'), 'Придумайте PIN');
      await _typeAndNext(tester, testPin);
      expect(textOf(tester, 'pin-title'), 'Повторите PIN');
      await _typeAndNext(tester, testPin);

      expect(find.byKey(const Key('pin-title')), findsNothing);
      expect(store.record, isNotNull);
      expect(store.record!.toJsonString(), isNot(contains(testPin)));
      expect(find.byKey(const Key('privacy-change-pin')), findsOneWidget);
      expect(
        find.byKey(const Key('privacy-timing-immediately')),
        findsOneWidget,
      );
    });

    testWidgets('второй ввод не совпал: начинаем заново, замок не включён', (
      tester,
    ) async {
      final store = await _open(tester);
      await tester.tap(find.byKey(const Key('privacy-lock-switch')));
      await tester.pumpAndSettle();
      await _typeAndNext(tester, testPin);
      await _typeAndNext(tester, testPinOther);
      expect(textOf(tester, 'pin-title'), 'Придумайте PIN');
      expect(pinMessage(tester), contains('не совпал'));
      expect(store.record, isNull);
    });

    testWidgets('«Далее» недоступно, пока нет четырёх цифр; шесть — максимум', (
      tester,
    ) async {
      await _open(tester);
      await tester.tap(find.byKey(const Key('privacy-lock-switch')));
      await tester.pumpAndSettle();
      for (final d in ['1', '2', '3']) {
        await tester.tap(find.byKey(Key('pin-key-$d')));
        await tester.pump();
      }
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('pin-submit')))
            .onPressed,
        isNull,
      );
      for (final d in ['4', '5', '6', '7', '8']) {
        await tester.tap(find.byKey(Key('pin-key-$d')));
        await tester.pump();
      }
      // Седьмая и восьмая цифры не принимаются: точек не больше шести.
      expect(find.byKey(const Key('pin-dot-5')), findsOneWidget);
      expect(find.byKey(const Key('pin-dot-6')), findsNothing);
      await tester.tap(find.byKey(const Key('pin-backspace')));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('pin-submit')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('закрыть окно создания PIN: замок остаётся выключенным', (
      tester,
    ) async {
      final store = await _open(tester);
      await tester.tap(find.byKey(const Key('privacy-lock-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pin-dialog-cancel')));
      await tester.pumpAndSettle();
      expect(store.record, isNull);
    });

    testWidgets('смена PIN: текущий, новый дважды; запись обновляется', (
      tester,
    ) async {
      final store = await _open(tester, store: lockedStore());
      // Раздел закрыт на холодном старте: открываем PIN-ом.
      await enterPin(tester, testPin);
      final before = store.record!.hash;

      await tester.tap(find.byKey(const Key('privacy-change-pin')));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'pin-title'), 'Введите текущий PIN');
      await enterPin(tester, testPinOther);
      expect(pinMessage(tester), contains('Неверный PIN'));
      await enterPin(tester, testPin);
      expect(textOf(tester, 'pin-title'), 'Новый PIN');
      await _typeAndNext(tester, '9753');
      await _typeAndNext(tester, '9753');

      expect(find.text('PIN изменён'), findsOneWidget);
      expect(store.record!.hash, isNot(before));
      expect(store.record!.pinLength, 4);
      expect(store.record!.toJsonString(), isNot(contains('9753')));
    });

    testWidgets('отключение: нужен текущий PIN, неверный — замок остаётся', (
      tester,
    ) async {
      final store = await _open(tester, store: lockedStore());
      await enterPin(tester, testPin);
      await tester.tap(find.byKey(const Key('privacy-lock-switch')));
      await tester.pumpAndSettle();
      expect(find.textContaining('чтобы отключить замок'), findsOneWidget);

      await enterPin(tester, testPinOther);
      expect(pinMessage(tester), contains('Неверный PIN'));
      expect(store.record, isNotNull);

      await enterPin(tester, testPin);
      expect(store.record, isNull);
      expect(find.byKey(const Key('pin-title')), findsNothing);
      expect(find.byKey(const Key('privacy-change-pin')), findsNothing);
    });

    testWidgets('пауза в окне подтверждения: сообщение с отсчётом', (
      tester,
    ) async {
      await _open(tester, store: lockedStore());
      await enterPin(tester, testPin);
      await tester.tap(find.byKey(const Key('privacy-change-pin')));
      await tester.pumpAndSettle();
      for (var i = 0; i < 5; i++) {
        await enterPin(tester, testPinOther);
      }
      expect(pinMessage(tester), 'Слишком много попыток. Повторите через 0:30');
    });

    testWidgets('тайминг: выбор сохраняется', (tester) async {
      final store = await _open(tester, store: lockedStore());
      await enterPin(tester, testPin);
      await tester.tap(find.byKey(const Key('privacy-timing-1m')));
      await tester.pumpAndSettle();
      expect(store.record!.timing, LockTiming.minute1);
      await tester.tap(find.byKey(const Key('privacy-timing-5m')));
      await tester.pumpAndSettle();
      expect(store.record!.timing, LockTiming.minute5);
      await tester.tap(find.byKey(const Key('privacy-timing-immediately')));
      await tester.pumpAndSettle();
      expect(store.record!.timing, LockTiming.immediately);
    });

    testWidgets('биометрия: переключатель есть, только если устройство '
        'умеет', (tester) async {
      final store = await _open(
        tester,
        store: lockedStore(),
        biometric: FakeBiometric(available: true),
      );
      await enterPin(tester, testPin);
      expect(find.byKey(const Key('privacy-biometric-switch')), findsOneWidget);
      await tester.tap(find.byKey(const Key('privacy-biometric-switch')));
      await tester.pumpAndSettle();
      expect(store.record!.biometric, isTrue);
    });

    testWidgets('биометрии на устройстве нет: переключателя нет', (
      tester,
    ) async {
      await _open(tester, store: lockedStore());
      await enterPin(tester, testPin);
      expect(find.byKey(const Key('privacy-biometric-switch')), findsNothing);
    });

    testWidgets('«Заблокировать сейчас» закрывает раздел', (tester) async {
      await _open(tester, store: lockedStore());
      await enterPin(tester, testPin);
      await tester.tap(find.byKey(const Key('privacy-lock-now')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-lock-screen')), findsOneWidget);
    });

    testWidgets('десктоп: экран и включение замка', (tester) async {
      final store = await _open(tester, size: desktopSize);
      await tester.tap(find.byKey(const Key('privacy-lock-switch')));
      await tester.pumpAndSettle();
      await _typeAndNext(tester, testPin);
      await _typeAndNext(tester, testPin);
      expect(store.record, isNotNull);
    });
  });

  group('вход из «Финансов»', () {
    testWidgets('значок замка в шапке ведёт в «Приватность»', (tester) async {
      await pumpFinance(tester, seedWith: seedFinanceDemo);
      await tester.tap(find.byKey(const Key('finance-open-privacy')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('privacy-screen')), findsOneWidget);
      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-total')), findsOneWidget);
    });
  });
}
