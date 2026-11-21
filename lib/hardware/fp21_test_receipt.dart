import 'money.dart';

const fp21TestReceiptBarcode = '2000000000015';
const fp21TestReceiptQrUrl = 'https://chimeraerp.ro';

const _items = [
  (name: 'Cafea de specialitate 250 g', quantity: 1, priceMinor: 3490),
  (name: 'Lapte integral 1 l', quantity: 2, priceMinor: 875),
  (name: 'Paine cu maia', quantity: 1, priceMinor: 1450),
  (name: 'Croissant cu unt', quantity: 3, priceMinor: 690),
  (name: 'Gem de caise 320 g', quantity: 1, priceMinor: 1890),
  (name: 'Ceai de menta', quantity: 2, priceMinor: 1290),
  (name: 'Ciocolata neagra 80 g', quantity: 2, priceMinor: 950),
  (name: 'Apa minerala 0,5 l', quantity: 4, priceMinor: 425),
];

String _price(int minor) => minorToDecimal(minor).replaceAll('.', ',');

String _columns(String left, String right) =>
    left.padRight(32 - right.length) + right;

final List<String> fp21TestReceiptLines = _receiptLines();

List<String> _receiptLines() {
  final lines = [
    'CHIMERA COMPANION',
    'BON NEFISCAL DE TEST',
    'Simulare vanzare in RON',
    '--------------------------------',
    _columns('Cant. x pret unitar', 'Valoare'),
  ];
  var totalMinor = 0;
  for (final item in _items) {
    final amount = lineTotalMinor(item.priceMinor, item.quantity.toString());
    lines.add(item.name);
    lines.add(
      _columns(
        '  ${item.quantity} x ${_price(item.priceMinor)}',
        _price(amount),
      ),
    );
    totalMinor += amount;
  }
  lines.addAll([
    '--------------------------------',
    _columns('TOTAL SIMULAT', '${_price(totalMinor)} RON'),
    'Fara incasare.',
    'Cod de bare demonstrativ',
  ]);
  return List.unmodifiable(lines);
}

const List<String> fp21TestReceiptFooter = [
  'SFARSIT BON NEFISCAL DE TEST',
];
