import 'package:chimera_companion/hardware/fp21_test_receipt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all printed rows fit 32 columns and use printable ASCII', () {
    final lines = [...fp21TestReceiptLines, ...fp21TestReceiptFooter];
    expect(lines.length, lessThanOrEqualTo(100));
    for (final line in lines) {
      expect(line, matches(RegExp(r'^[ -~]{1,32}$')), reason: line);
    }
    expect(fp21TestReceiptLines, contains('BON NEFISCAL DE TEST'));
    expect(fp21TestReceiptFooter.last, contains('NEFISCAL'));
  });

  test('extended prices and the simulated total match the printed basket', () {
    final rowPattern = RegExp(r'^\s+(\d+) x (\d+,\d{2})\s+(\d+,\d{2})$');
    final lines = fp21TestReceiptLines;
    var articles = 0;
    var total = 0;
    for (var i = 1; i < lines.length; i++) {
      final row = rowPattern.firstMatch(lines[i]);
      if (row == null) continue;
      expect(lines[i - 1], matches(RegExp(r'^[A-Z][a-z]')));
      final quantity = int.parse(row[1]!);
      final unitPrice = int.parse(row[2]!.replaceAll(',', ''));
      final extendedPrice = int.parse(row[3]!.replaceAll(',', ''));
      expect(extendedPrice, quantity * unitPrice);
      articles++;
      total += extendedPrice;
    }
    expect(articles, greaterThanOrEqualTo(8));
    final printedTotal = lines.singleWhere(
      (row) => row.startsWith('TOTAL SIMULAT'),
    );
    final amount = RegExp(r'(\d+),(\d{2}) RON$').firstMatch(printedTotal)!;
    expect(int.parse('${amount[1]}${amount[2]}'), total);
    expect(lines, contains('Fara incasare.'));
  });

  test(
    'uses the demo EAN-13 and leaves symbol printing to native commands',
    () {
      expect(fp21TestReceiptBarcode, matches(RegExp(r'^\d{13}$')));
      final digits = fp21TestReceiptBarcode.split('').map(int.parse).toList();
      final checksum = List.generate(
        13,
        (i) => digits[i] * (i.isEven ? 1 : 3),
      ).reduce((a, b) => a + b);
      expect(checksum % 10, 0);
      expect(fp21TestReceiptBarcode, '2000000000015');
      final printedText = [
        ...fp21TestReceiptLines,
        ...fp21TestReceiptFooter,
      ].join('\n');
      expect(printedText, isNot(contains('EAN-13:')));
      expect(printedText, isNot(contains('Spatiu rezervat')));
      expect(printedText, isNot(contains('fidelity.chimeraerp.ro')));
      expect(fp21TestReceiptFooter, ['SFARSIT BON NEFISCAL DE TEST']);
    },
  );
}
