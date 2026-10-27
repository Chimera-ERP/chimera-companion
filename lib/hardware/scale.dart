/// Contract for future scale drivers. No driver is advertised until implemented.
enum ScaleUnit { kg, g }

enum ScaleState { disconnected, connecting, ready, error }

class ScaleCapabilities {
  const ScaleCapabilities({this.tare = false, this.zero = false});
  final bool tare;
  final bool zero;
}

class ScaleReading {
  ScaleReading({
    required this.deviceId,
    required this.net,
    required this.unit,
    required this.stable,
    required this.observedAt,
    this.overload = false,
    this.gross,
    this.tare,
  }) {
    for (final value in [net, gross, tare]) {
      if (value != null &&
          !RegExp(r'^-?[0-9]+(?:\.[0-9]+)?$').hasMatch(value)) {
        throw ArgumentError('Scale quantities must be decimal strings');
      }
    }
    if (deviceId.isEmpty) throw ArgumentError('Scale identity is required');
  }
  final String deviceId;

  /// Decimal strings avoid transport rounding. Unit conversion belongs to POS.
  final String net;
  final String? gross;
  final String? tare;
  final ScaleUnit unit;
  final bool stable;
  final bool overload;
  final DateTime observedAt;

  bool usableAt(DateTime now, {Duration maxAge = const Duration(seconds: 2)}) {
    final age = now.difference(observedAt);
    final quantity = double.tryParse(net);
    return stable &&
        !overload &&
        quantity != null &&
        quantity.isFinite &&
        quantity > 0 &&
        !age.isNegative &&
        age <= maxAge;
  }

  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'net': net,
    'unit': unit.name,
    'stable': stable,
    'overload': overload,
    'observedAt': observedAt.toUtc().toIso8601String(),
    if (gross != null) 'gross': gross,
    if (tare != null) 'tare': tare,
  };
}

abstract interface class ScaleAdapter {
  String get deviceId;
  ScaleCapabilities get capabilities;
  Stream<ScaleState> get states;
  Stream<ScaleReading> get readings;
  Future<void> connect();
  Future<void> disconnect();
  Future<ScaleReading> read();

  /// Only exposed when the adapter advertises the matching capability.
  Future<void> tare();
  Future<void> zero();
}
