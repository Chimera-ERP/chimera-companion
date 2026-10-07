import 'command_journal.dart';

/// Per-equipment admission queues and in-flight identity protection. The legacy
/// shared journal additionally serializes dispatch within a Companion; that
/// conservative gate can be relaxed after journal sharding/migration.
class HardwareCommandExecutor {
  final Map<String, Future<void>> _tails = {};
  final Map<String, ({String hash, Future<Map<String, Object?>> result})>
  _jobs = {};
  Future<void> _journalGate = Future.value();
  Future<Map<String, Object?>> execute({
    required String equipment,
    required String id,
    required String operation,
    required Map<String, dynamic> payload,
    required Future<Map<String, Object?>> Function() dispatch,
  }) {
    final hash = CommandJournal.fingerprint(equipment, operation, payload);
    final existing = _jobs[id];
    if (existing != null) {
      if (existing.hash != hash) {
        return Future.error(StateError('Idempotency key payload mismatch'));
      }
      return existing.result;
    }
    if (_jobs.length >= 64) {
      return Future.error(StateError('Hardware queue full'));
    }
    final previous = _tails[equipment] ?? Future<void>.value();
    final result = previous.then((_) {
      final scheduled = _journalGate.then((_) => dispatch());
      _journalGate = scheduled.then<void>((_) {}).catchError((_) {});
      return scheduled;
    });
    final tail = result.then<void>((_) {}).catchError((_) {});
    _tails[equipment] = tail;
    _jobs[id] = (hash: hash, result: result);
    void finish() {
      _jobs.remove(id);
      if (identical(_tails[equipment], tail)) _tails.remove(equipment);
    }

    result.then(
      (_) => finish(),
      onError: (Object error, StackTrace trace) => finish(),
    );
    return result;
  }
}
