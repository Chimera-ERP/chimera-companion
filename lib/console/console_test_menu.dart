import 'dart:math';
import 'console_contract.dart';

/// Local pictogram diagnostics only. No KDS callbacks or production commands.
class ConsoleTestMenu {
  ConsoleTestMenu({Random? random}) : _random = random ?? Random() {
    _populate();
  }

  static const pageCount = 3;
  static const _choices = [
    (icon: 'coffee', label: 'Cafea'),
    (icon: 'cake', label: 'Tort'),
    (icon: 'water', label: 'Apă'),
    (icon: 'oven', label: 'Cuptor'),
    (icon: 'timer', label: 'Cronometru'),
    (icon: 'box', label: 'Stoc'),
    (icon: 'star', label: 'Favorit'),
    (icon: 'settings', label: 'Setări'),
    (icon: 'start', label: 'Pornește'),
    (icon: 'pause', label: 'Pauză'),
    (icon: 'done', label: 'Gata'),
    (icon: 'person', label: 'Persoană'),
    (icon: 'refresh', label: 'Reîncarcă'),
    (icon: 'open', label: 'Deschide'),
    (icon: 'check', label: 'Confirmă'),
  ];

  final Random _random;
  int page = 0, _revision = 0;
  late List<ConsoleKey> _keys;
  ConsoleFrame get frame => ConsoleFrame(
    _revision,
    'Probă pictograme · ${page + 1}/$pageCount',
    List.unmodifiable(_keys),
  );

  ConsoleKey _key(int index, ({String icon, String label}) choice) =>
      ConsoleKey('test:$index', choice.label, choice.icon, true);

  void _populate() {
    final choices = [..._choices]..shuffle(_random);
    var next = 0;
    _keys = List.generate(
      13,
      (index) => switch (index) {
        4 => const ConsoleKey('test:up', 'Sus', 'up', true),
        9 => const ConsoleKey('test:down', 'Jos', 'down', true),
        _ => _key(index, choices[next++]),
      },
    );
    _revision++;
  }

  void press(int index) {
    if (index < 0 || index >= _keys.length) return;
    if (index == 4 || index == 9) {
      page = (page + (index == 4 ? -1 : 1)) % pageCount;
      _populate();
      return;
    }
    final choices = _choices.where((c) => c.icon != _keys[index].icon).toList();
    _keys[index] = _key(index, choices[_random.nextInt(choices.length)]);
    _revision++;
  }
}
