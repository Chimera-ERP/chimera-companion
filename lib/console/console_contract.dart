/// Semantic console contract. No ERP credentials, SQL or hardware commands.
class ConsoleKey {
  const ConsoleKey(this.id, this.label, this.icon, this.enabled);
  final String id, label, icon;
  final bool enabled;
  static const icons = {
    'previous',
    'next',
    'open',
    'back',
    'start',
    'pause',
    'resume',
    'done',
    'person',
    'check',
    'refresh',
    'up',
    'down',
    'coffee',
    'cake',
    'water',
    'oven',
    'timer',
    'box',
    'star',
    'settings',
  };
  factory ConsoleKey.parse(Map<String, dynamic> value) {
    final id = value['id'], label = value['label'], icon = value['icon'];
    if (id is! String ||
        !RegExp(r'^[a-zA-Z0-9:_-]{1,100}$').hasMatch(id) ||
        label is! String ||
        label.length > 60 ||
        !icons.contains(icon) ||
        value['enabled'] is! bool) {
      throw const FormatException('Invalid console key');
    }
    return ConsoleKey(id, label, icon as String, value['enabled'] as bool);
  }
}

class ConsoleFrame {
  const ConsoleFrame(this.revision, this.title, this.keys);
  final int revision;
  final String title;
  final List<ConsoleKey> keys;
  factory ConsoleFrame.parse(Map<String, dynamic> value) {
    final revision = value['revision'],
        title = value['title'],
        keys = value['keys'];
    if (value['version'] != 1 ||
        revision is! int ||
        revision < 1 ||
        revision > 9007199254740991 ||
        title is! String ||
        title.length > 100 ||
        keys is! List ||
        keys.length > 13) {
      throw const FormatException('Invalid console frame');
    }
    final parsed = keys
        .map((k) => ConsoleKey.parse(Map<String, dynamic>.from(k as Map)))
        .toList(growable: false);
    if (parsed.map((k) => k.id).toSet().length != parsed.length) {
      throw const FormatException('Duplicate console key');
    }
    return ConsoleFrame(revision, title, parsed);
  }
}
