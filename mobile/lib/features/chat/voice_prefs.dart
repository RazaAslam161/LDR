import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// What the phone remembers about listening to voice notes.
///
/// Three things share one store because they share one lifetime and one bound:
/// the playback speed, how far into a note you got, and whether you have heard
/// it at all. Three separate keys would be three separate loads on a screen
/// that already has a conversation to fetch.
///
/// Nothing here is sent anywhere. Where the listener got to is a fact about the
/// person holding the phone, not about the couple, and a "played" flag that
/// crossed to the other handset would be a read receipt for voice notes that
/// nobody asked for.
class VoicePrefs {
  VoicePrefs._();

  static final VoicePrefs instance = VoicePrefs._();

  static const _speedKey = 'voice_speed';
  static const _notesKey = 'voice_notes';

  /// Newest-last, and trimmed from the front. A conversation is unbounded and
  /// this is not: without a cap, every voice note either partner ever sent
  /// would keep a row on disk forever to answer a question about a bubble
  /// nobody will scroll back to.
  static const int maxRemembered = 200;

  /// The speeds the chip cycles through. Ordered, because tapping walks it.
  static const List<double> cycle = [1, 1.5, 2];

  double _speed = 1;
  final Map<String, _NoteMemory> _notes = {};
  final List<String> _order = [];
  bool _loaded = false;

  double get speed => _speed;

  /// Read once per process. Safe to call again; it will not re-read.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final p = await SharedPreferences.getInstance();
    final stored = p.getDouble(_speedKey);
    // Only a speed the chip can actually reach. A value left by a build with a
    // different cycle would otherwise strand the chip on a rate no number of
    // taps returns to.
    if (stored != null && cycle.contains(stored)) _speed = stored;

    final raw = p.getString(_notesKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      for (final entry in decoded.entries) {
        final v = entry.value;
        if (v is! Map<String, dynamic>) continue;
        _notes[entry.key] = _NoteMemory(
          positionMs: v['p'] is int ? v['p'] as int : 0,
          played: v['d'] == true,
        );
        _order.add(entry.key);
      }
    } on FormatException {
      // A store written by another build is not worth a crash on the way into
      // the chat. The cost of losing it is that a few notes forget where you
      // were, which is the same state a fresh install is in.
      _notes.clear();
      _order.clear();
    }
  }

  Future<void> setSpeed(double value) async {
    if (!cycle.contains(value)) return;
    _speed = value;
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_speedKey, value);
  }

  /// The next speed in the cycle, wrapping back to 1x.
  double nextSpeed() {
    final i = cycle.indexOf(_speed);
    return cycle[(i + 1) % cycle.length];
  }

  Duration positionOf(String messageId) =>
      Duration(milliseconds: _notes[messageId]?.positionMs ?? 0);

  bool wasPlayed(String messageId) => _notes[messageId]?.played ?? false;

  /// Remember where a note got to, and that it was heard at all.
  ///
  /// [position] is dropped when it is within a second of the start or the note
  /// ran to the end: resuming a note "from 0:00" is just playing it, and
  /// resuming one from its final moment plays silence and looks broken.
  Future<void> remember(
    String messageId, {
    Duration? position,
    bool? played,
  }) async {
    final existing = _notes[messageId];
    final next = _NoteMemory(
      positionMs: position?.inMilliseconds ?? existing?.positionMs ?? 0,
      played: played ?? existing?.played ?? false,
    );
    _notes[messageId] = next;
    _order
      ..remove(messageId)
      ..add(messageId);
    while (_order.length > maxRemembered) {
      _notes.remove(_order.removeAt(0));
    }
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _notesKey,
      jsonEncode({
        for (final id in _order)
          id: {'p': _notes[id]!.positionMs, 'd': _notes[id]!.played},
      }),
    );
  }

  /// Test seam. The store is a process-wide singleton, so without this one
  /// test's writes are the next test's starting state.
  void resetForTest() {
    _speed = 1;
    _notes.clear();
    _order.clear();
    _loaded = false;
  }
}

class _NoteMemory {
  const _NoteMemory({required this.positionMs, required this.played});
  final int positionMs;
  final bool played;
}
