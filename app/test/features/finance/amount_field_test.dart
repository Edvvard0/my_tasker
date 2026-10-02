import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_tasker/core/theme/app_theme.dart';
import 'package:my_tasker/features/finance/presentation/finance_format.dart';
import 'package:my_tasker/features/finance/presentation/widgets/amount_field.dart';

const _nb = ' ';

TextEditingValue _type(String raw, {int? caret, bool negative = false}) =>
    AmountInputFormatter(allowNegative: negative).formatEditUpdate(
      TextEditingValue.empty,
      TextEditingValue(
        text: raw,
        selection: TextSelection.collapsed(offset: caret ?? raw.length),
      ),
    );

void main() {
  group('автоформат поля суммы', () {
    test('разряды группируются неразрывными пробелами', () {
      expect(_type('1').text, '1');
      expect(_type('1234').text, '1${_nb}234');
      expect(_type('1234567').text, '1${_nb}234${_nb}567');
    });

    test('копейки: запятая, не больше двух знаков', () {
      expect(_type('1234,5').text, '1${_nb}234,5');
      expect(_type('1234,567').text, '1${_nb}234,56');
      expect(_type('1234.5').text, '1${_nb}234,5');
      expect(_type('12,').text, '12,');
    });

    test('один разделитель, запятая первой даёт «0,»', () {
      expect(_type('1,2,3').text, '1,23');
      expect(_type(',5').text, '0,5');
    });

    test('ведущие нули и лишние символы', () {
      expect(_type('007').text, '7');
      expect(_type('00').text, '0');
      expect(_type('05').text, '5');
      expect(_type('a1b2').text, '12');
      expect(_type('').text, '');
    });

    test('не больше 12 цифр целой части', () {
      expect(_type('1234567890123').text.replaceAll(_nb, ''), '123456789012');
    });

    test('минус — только первым символом и только если разрешён', () {
      expect(_type('-5').text, '5');
      expect(_type('-5', negative: true).text, '−5');
      expect(_type('−5', negative: true).text, '−5');
      expect(_type('5-', negative: true).text, '5');
      expect(_type('-', negative: true).text, '−');
    });

    test('курсор остаётся за теми же цифрами', () {
      expect(_type('1234').selection.baseOffset, 5);
      // Цифра вставлена после «1» в «1 234»: курсор после двух цифр.
      final v = _type('19${_nb}234', caret: 2);
      expect(v.text, '19${_nb}234');
      expect(v.selection.baseOffset, 2);
      // Курсор стоял после первой цифры: остаётся перед разделителем.
      final w = _type('1234', caret: 1);
      expect(w.text, '1${_nb}234');
      expect(w.selection.baseOffset, 1);
      // Недействительный курсор — в конец.
      final x = const AmountInputFormatter().formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(text: '12'),
      );
      expect(x.selection.baseOffset, 2);
    });
  });

  group('разбор и показ суммы', () {
    test('parseAmountField даёт целые копейки', () {
      expect(parseAmountField('1${_nb}234,5'), 123450);
      expect(parseAmountField('12,'), 1200);
      expect(parseAmountField('0'), 0);
      expect(parseAmountField('−5'), -500);
      expect(parseAmountField(''), isNull);
      expect(parseAmountField('−'), isNull);
    });

    test('amountInputText', () {
      expect(amountInputText(123450), '1${_nb}234,50');
      expect(amountInputText(100), '1');
      expect(amountInputText(-1250), '−12,50');
    });

    test('moneyText: минус «−», плюс у дохода, копейки только ненулевые', () {
      expect(moneyText(124990), '1${_nb}249,90$_nb₽');
      expect(moneyText(-124990), '−1${_nb}249,90$_nb₽');
      expect(moneyText(2000000, signed: true), '+20${_nb}000$_nb₽');
      expect(moneyText(0, signed: true), '0$_nb₽');
      expect(moneyText(99999999999999 + 1), '100000000000000 коп.');
    });
  });

  testWidgets('быстрые чипы «+1 000» и «+5 000» прибавляют к сумме', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final seen = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Column(
            children: [
              AmountField(controller: controller),
              AmountChips(controller: controller, onChanged: seen.add),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('amount-chip-1000')));
    expect(controller.text, '1${_nb}000');
    await tester.tap(find.byKey(const Key('amount-chip-5000')));
    expect(controller.text, '6${_nb}000');
    expect(seen, ['1${_nb}000', '6${_nb}000']);
    controller.text = '10,5';
    await tester.tap(find.byKey(const Key('amount-chip-1000')));
    expect(controller.text, '1${_nb}010,50');
    // Подписи чипов.
    expect(find.text('+1${_nb}000'), findsOneWidget);
    expect(find.text('+5${_nb}000'), findsOneWidget);
  });

  testWidgets('поле суммы: ввод форматируется на лету', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: AmountField(controller: controller, allowNegative: true),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '1250000');
    expect(controller.text, '1${_nb}250${_nb}000');
    await tester.enterText(find.byType(TextField), '-300,5');
    expect(controller.text, '−300,5');
    expect(parseAmountField(controller.text), -30050);
  });
}
