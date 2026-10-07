String minorToDecimal(int amount) =>
    '${amount ~/ 100}.${(amount % 100).toString().padLeft(2, '0')}';

int decimalToMinor(String value) {
  final text = value.trim();
  if (!RegExp(r'^\+?\d+(\.\d{1,2})?$').hasMatch(text)) {
    throw const FormatException('Invalid monetary decimal');
  }
  final parts = text.replaceFirst('+', '').split('.');
  return int.parse(parts[0]) * 100 +
      (parts.length == 2 ? int.parse(parts[1].padRight(2, '0')) : 0);
}

int lineTotalMinor(int priceMinor, String quantity) {
  if (priceMinor < 0 || !RegExp(r'^\d{1,6}(\.\d{1,3})?$').hasMatch(quantity)) {
    throw ArgumentError('Invalid price or quantity');
  }
  final parts = quantity.split('.');
  final scaled =
      BigInt.parse(parts[0]) * BigInt.from(1000) +
      (parts.length == 2
          ? BigInt.parse(parts[1].padRight(3, '0'))
          : BigInt.zero);
  if (scaled <= BigInt.zero) throw ArgumentError('Quantity must be positive');
  return ((BigInt.from(priceMinor) * scaled + BigInt.from(500)) ~/
          BigInt.from(1000))
      .toInt();
}
