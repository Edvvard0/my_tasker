import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:my_tasker/features/finance/data/secret_store.dart';
import 'package:my_tasker/features/finance/domain/finance_models.dart';
import 'package:my_tasker/features/finance/presentation/finance_icons.dart';

void main() {
  group('иконки', () {
    test('все иконки предустановленных категорий известны, неизвестное — '
        'нейтральный тег', () {
      for (final name in [
        'shopping_basket',
        'restaurant',
        'directions_bus',
        'home',
        'wifi',
        'medical_services',
        'checkroom',
        'movie',
        'school',
        'card_giftcard',
        'chair',
        'subscriptions',
        'directions_car',
        'flight',
        'more_horiz',
        'local_taxi',
        'train',
        'local_gas_station',
        'build',
        'key',
        'bolt',
        'medication',
        'stethoscope',
        'payments',
        'work',
        'redeem',
        'savings',
      ]) {
        expect(categoryIcons, contains(name));
        expect(categoryIcon(name), isNot(LucideIcons.tag), reason: name);
      }
      expect(categoryIcon('нет такой'), LucideIcons.tag);
      expect(categoryIcon(null), LucideIcons.tag);
    });

    test('иконки счетов и видов операций различаются', () {
      final accountIcons = <IconData>{
        for (final k in AccountKind.values) accountIcon(k),
      };
      expect(accountIcons.length, greaterThanOrEqualTo(4));
      expect(txKindIcon(TxKind.expense), LucideIcons.arrowUpRight);
      expect(txKindIcon(TxKind.income), LucideIcons.arrowDownLeft);
      expect(txKindIcon(TxKind.transfer), LucideIcons.arrowLeftRight);
    });
  });

  group('SecureSecretStore', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('запись, чтение, удаление', () async {
      final store = SecureSecretStore();
      expect(await store.read('k'), isNull);
      await store.write('k', 'v');
      expect(await store.read('k'), 'v');
      await store.delete('k');
      expect(await store.read('k'), isNull);
    });
  });

  group('MemorySecretStore', () {
    test('сломанное хранилище бросает при чтении', () async {
      final store = MemorySecretStore();
      await store.write('k', 'v');
      expect(await store.read('k'), 'v');
      store.failReads = true;
      await expectLater(store.read('k'), throwsStateError);
    });
  });
}
