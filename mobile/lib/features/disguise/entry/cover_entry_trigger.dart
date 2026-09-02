import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:miles/core/services/app_lock.dart';
import 'package:miles/features/disguise/disguise_profile.dart';

/// A touch shorter than this is a tap; a recorded hold must be at least
/// [kHoldMinMs]. The band between is refused at record time ("hold a little
/// longer"), so a move never depends on a duration the owner cannot repeat.
const kTapMaxMs = 400;
const kHoldMinMs = 700;

/// A lone hold must be this long: a shorter one is the reflex press a curious
/// person uses to look for a menu.
const kLoneHoldMinMs = 3000;

/// A sequence that is not all taps needs one hold at least this long.
const kSequenceHoldMinMs = 1500;

/// A tap-only sequence needs this many taps, inside [kTapRunWindowMs], on at
/// least two spots — the shape a stranger typing a number never produces.
const kTapRunMin = 5;
const kTapRunWindowMs = 3000;

/// Position tolerance, in short-side units of the safe box: floor and ceiling
/// for the radius derived from the owner's two recordings.
const kRadiusMin = 0.08;
const kRadiusMax = 0.18;

/// A secret word or number, before hashing.
const kTextMin = 6;
const kTextMax = 24;

/// A matched box may differ from the recorded one by this much in aspect;
/// beyond it (split screen, a resized window) nothing is compared.
const kBoxAspectTolerance = 0.10;

/// One counted touch on the cover, as the pointer layer classified it.
///
/// [x] and [y] are in short-side units of the safe box (px / min(w, h)) so one
/// radius means one physical distance on both axes. [durMs] is the press
/// length; the matcher decides what counts as a tap or a hold against the
/// recorded move, never against a fixed threshold.
class TouchEvent {
  const TouchEvent({
    required this.x,
    required this.y,
    required this.durMs,
    required this.downMs,
    required this.upMs,
  });

  final double x;
  final double y;
  final int durMs;
  final int downMs;
  final int upMs;

  bool get isTap => durMs < kTapMaxMs;
  bool get isHold => durMs >= kHoldMinMs;
}

/// One step of a recorded touch move.
class TouchStep {
  const TouchStep({required this.x, required this.y, required this.holdMs});

  /// Centre, short-side units.
  final double x;
  final double y;

  /// 0 for a tap, otherwise the shorter of the two recorded holds.
  final int holdMs;

  bool get isHold => holdMs > 0;
}

/// Where a secret word is typed and committed on a cover.
enum TextSlot {
  /// The calculator display, committed by `=`. Digits only.
  calc,

  /// The converter's amount, committed by the swap button. Digits only.
  convert,

  /// A new note's title, committed by Save (which then saves nothing).
  notes;

  DisguiseCover get cover => switch (this) {
        TextSlot.calc => DisguiseCover.calculator,
        TextSlot.convert => DisguiseCover.convert,
        TextSlot.notes => DisguiseCover.notes,
      };

  static TextSlot? forCover(DisguiseCover cover) => switch (cover) {
        DisguiseCover.calculator => TextSlot.calc,
        DisguiseCover.convert => TextSlot.convert,
        DisguiseCover.notes => TextSlot.notes,
        _ => null,
      };

  bool get numeric => this != TextSlot.notes;
}

/// The owner's recorded way in, bound to one cover.
///
/// Versioned JSON in the keystore. A reader that cannot make sense of a record
/// gets null, never a throw and never a guess: the host then treats the cover
/// as having a move it cannot read, which keeps the backup door on the PIN.
sealed class CoverEntryTrigger {
  const CoverEntryTrigger({required this.cover, required this.box});

  static const version = 1;

  final DisguiseCover cover;

  /// The safe box the move was recorded in, dp.
  final Size box;

  /// One line the recorder shows once it is done; names the shape, never the
  /// content.
  String get summary;

  Map<String, Object?> toJson();

  String encode() => jsonEncode(toJson());

  static CoverEntryTrigger? fromJson(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    if (decoded['v'] != version) return null;
    final coverName = decoded['cover'];
    final cover = coverName is String
        ? DisguiseCover.values.where((c) => c.name == coverName).firstOrNull
        : null;
    if (cover == null || cover == DisguiseCover.none) return null;
    final boxRaw = decoded['box'];
    if (boxRaw is! Map<String, Object?>) return null;
    final w = boxRaw['w'];
    final h = boxRaw['h'];
    if (w is! num || h is! num || w <= 0 || h <= 0) return null;
    final box = Size(w.toDouble(), h.toDouble());
    return switch (decoded['kind']) {
      'touch' => TouchTrigger._fromJson(decoded, cover: cover, box: box),
      'text' => TextTrigger._fromJson(decoded, cover: cover, box: box),
      _ => null,
    };
  }

  /// Whether a box the layer is matching in is close enough to the recorded
  /// one for positions to mean the same thing.
  bool boxMatches(Size other) {
    if (other.width <= 0 || other.height <= 0) return false;
    final recorded = box.width / box.height;
    final now = other.width / other.height;
    return (recorded - now).abs() / recorded <= kBoxAspectTolerance;
  }
}

/// A sequence of taps and holds at recorded spots.
class TouchTrigger extends CoverEntryTrigger {
  const TouchTrigger({
    required super.cover,
    required super.box,
    required this.steps,
    required this.radius,
    required this.windowMs,
    required this.gapMs,
  });

  final List<TouchStep> steps;

  /// Per step, short-side units.
  final List<double> radius;

  /// First down to last up.
  final int windowMs;

  /// Longest allowed idle between one step's up and the next step's down.
  final int gapMs;

  static TouchTrigger? _fromJson(
    Map<String, Object?> m, {
    required DisguiseCover cover,
    required Size box,
  }) {
    final events = m['events'];
    final radius = m['radius'];
    final windowMs = m['windowMs'];
    final gapMs = m['gapMs'];
    if (events is! List || radius is! List || events.isEmpty) return null;
    if (events.length != radius.length) return null;
    if (windowMs is! int || gapMs is! int) return null;
    final steps = <TouchStep>[];
    for (final e in events) {
      if (e is! Map<String, Object?>) return null;
      final x = e['x'];
      final y = e['y'];
      final holdMs = e['holdMs'];
      if (x is! num || y is! num || holdMs is! int) return null;
      steps.add(TouchStep(x: x.toDouble(), y: y.toDouble(), holdMs: holdMs));
    }
    final radii = <double>[];
    for (final r in radius) {
      if (r is! num) return null;
      radii.add(r.toDouble());
    }
    return TouchTrigger(
      cover: cover,
      box: box,
      steps: steps,
      radius: radii,
      windowMs: windowMs,
      gapMs: gapMs,
    );
  }

  @override
  Map<String, Object?> toJson() => {
        'v': CoverEntryTrigger.version,
        'cover': cover.name,
        'kind': 'touch',
        'box': {'w': box.width, 'h': box.height},
        'events': [
          for (final s in steps) {'x': s.x, 'y': s.y, 'holdMs': s.holdMs},
        ],
        'radius': radius,
        'windowMs': windowMs,
        'gapMs': gapMs,
      };

  @override
  String get summary {
    final taps = steps.where((s) => !s.isHold).length;
    final holds = steps.length - taps;
    if (holds == 0) return '$taps taps';
    if (taps == 0) return holds == 1 ? 'a hold' : '$holds holds';
    final tapWord = taps == 1 ? '1 tap' : '$taps taps';
    return steps.last.isHold
        ? '$tapWord, then a hold'
        : '$tapWord and ${holds == 1 ? 'a hold' : '$holds holds'}';
  }

  static double _dist(double ax, double ay, double bx, double by) =>
      math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));

  bool _stepAccepts(int i, TouchEvent e) {
    final s = steps[i];
    if (_dist(s.x, s.y, e.x, e.y) > radius[i]) return false;
    return s.isHold ? e.durMs >= 0.6 * s.holdMs : e.isTap;
  }

  bool _gapsAccept(List<TouchEvent> tail) {
    for (var i = 1; i < tail.length; i++) {
      if (tail[i].downMs - tail[i - 1].upMs > gapMs) return false;
    }
    return true;
  }

  /// Whether the most recent events in [buffer] are this move.
  ///
  /// A tail match: a stray tap BEFORE the move is harmless, a stray tap after
  /// it is not — which is the right bias, the owner finishes deliberately.
  bool matchesTail(List<TouchEvent> buffer) {
    final n = steps.length;
    if (buffer.length < n) return false;
    final tail = buffer.sublist(buffer.length - n);
    for (var i = 0; i < n; i++) {
      if (!_stepAccepts(i, tail[i])) return false;
    }
    if (tail.last.upMs - tail.first.downMs > windowMs) return false;
    return _gapsAccept(tail);
  }

  /// When the last step is a hold and everything before it has just been
  /// performed, the layer arms a timer on the pointer that just went down at
  /// ([x], [y]) rather than waiting for the up — every real hold fires while
  /// the finger is still there. Returns how long to wait, or null.
  int? armedHoldMs(
    List<TouchEvent> buffer, {
    required double x,
    required double y,
    required int downMs,
  }) {
    final last = steps.last;
    if (!last.isHold) return null;
    final prior = steps.length - 1;
    if (buffer.length < prior) return null;
    final tail = buffer.sublist(buffer.length - prior);
    for (var i = 0; i < prior; i++) {
      if (!_stepAccepts(i, tail[i])) return null;
    }
    if (_dist(last.x, last.y, x, y) > radius[prior]) return null;
    if (tail.isNotEmpty) {
      if (!_gapsAccept(tail)) return null;
      if (downMs - tail.last.upMs > gapMs) return null;
    }
    final wait = (0.6 * last.holdMs).round();
    // A lone hold may not fire sooner than the recorder would accept one.
    // At 2000 it matched a two-second press — the reflex a curious person
    // uses to look for a menu, which is the whole reason the floor exists.
    final floor = prior == 0 ? kLoneHoldMinMs : 600;
    final armed = math.max(wait, floor);
    if (tail.isNotEmpty && downMs + armed - tail.first.downMs > windowMs) {
      return null;
    }
    return armed;
  }

  /// Why a first recording cannot be a move, or null when it can.
  ///
  /// Every rule here is the accident law from disguises.md: a curious person
  /// taps once, holds a list item to look for a menu, types a number. None of
  /// those may be a move.
  static String? admissibilityError(List<TouchEvent> rec) {
    if (rec.isEmpty) return 'Do your move on the screen first.';
    if (rec.any((e) => !e.isTap && !e.isHold)) {
      return 'Hold a little longer — a hold is at least a second.';
    }
    if (rec.length == 1) {
      final only = rec.single;
      if (only.isTap) {
        return 'One tap is too easy to hit by accident. Add more taps, or '
            'hold instead.';
      }
      if (only.durMs < kLoneHoldMinMs) {
        return 'A hold on its own needs three seconds.';
      }
      return null;
    }
    if (rec.any((e) => e.durMs >= kSequenceHoldMinMs)) return null;
    if (rec.any((e) => e.isHold)) {
      return 'Hold longer — about two seconds — or add more taps.';
    }
    if (rec.length < kTapRunMin) {
      return 'Taps alone need five quick ones, or add a hold of about two '
          'seconds.';
    }
    if (rec.last.upMs - rec.first.downMs > kTapRunWindowMs) {
      return 'Tap faster — five taps within three seconds.';
    }
    final first = rec.first;
    final spread = rec.any(
      (e) => _dist(first.x, first.y, e.x, e.y) > 2 * kRadiusMin,
    );
    if (!spread) {
      return 'Same spot every time is just typing. Use two different spots, '
          'or add a hold.';
    }
    return null;
  }

  /// Derives a move from two recordings that must agree, or explains why
  /// they do not. Tolerances come from the owner's own variance between the
  /// two, floored and capped so an unusually steady pair still produces a
  /// move they can repeat and a sloppy pair cannot match ordinary use.
  static (TouchTrigger?, String?) derive(
    List<TouchEvent> a,
    List<TouchEvent> b, {
    required DisguiseCover cover,
    required Size box,
  }) {
    final firstError = admissibilityError(a);
    if (firstError != null) return (null, firstError);
    if (b.length != a.length) {
      return (null, 'That was a different move — ${_shape(a)} the first time.');
    }
    final steps = <TouchStep>[];
    final radius = <double>[];
    for (var i = 0; i < a.length; i++) {
      final p = a[i];
      final q = b[i];
      if (p.isTap != q.isTap) {
        return (
          null,
          'That was a different move — ${_shape(a)} the first time.'
        );
      }
      if (!q.isTap && !q.isHold) {
        return (null, 'Hold a little longer — a hold is at least a second.');
      }
      final d = _dist(p.x, p.y, q.x, q.y);
      if (d > kRadiusMax) return (null, 'Not the same spot — try again.');
      steps.add(
        TouchStep(
          x: (p.x + q.x) / 2,
          y: (p.y + q.y) / 2,
          holdMs: p.isTap ? 0 : math.min(p.durMs, q.durMs),
        ),
      );
      radius.add((1.5 * d).clamp(kRadiusMin, kRadiusMax));
    }
    final span = math.max(
      a.last.upMs - a.first.downMs,
      b.last.upMs - b.first.downMs,
    );
    var maxGap = 0;
    for (final rec in [a, b]) {
      for (var i = 1; i < rec.length; i++) {
        maxGap = math.max(maxGap, rec[i].downMs - rec[i - 1].upMs);
      }
    }
    return (
      TouchTrigger(
        cover: cover,
        box: box,
        steps: steps,
        radius: radius,
        windowMs: (1.5 * span + 1000).round().clamp(2000, 12000),
        gapMs: (2 * maxGap).clamp(1000, 4000),
      ),
      null,
    );
  }

  static String _shape(List<TouchEvent> rec) {
    final taps = rec.where((e) => e.isTap).length;
    final holds = rec.length - taps;
    final t = taps == 1 ? '1 tap' : '$taps taps';
    final h = holds == 1 ? '1 hold' : '$holds holds';
    if (holds == 0) return t;
    if (taps == 0) return h;
    return '$t and $h';
  }
}

/// A secret word or number, typed into the cover and committed by a control
/// the cover already has. Stored only as a salted hash.
class TextTrigger extends CoverEntryTrigger {
  const TextTrigger({
    required super.cover,
    required super.box,
    required this.hash,
    required this.slot,
  });

  final String hash;
  final TextSlot slot;

  static TextTrigger? _fromJson(
    Map<String, Object?> m, {
    required DisguiseCover cover,
    required Size box,
  }) {
    final hash = m['hash'];
    final slotName = m['slot'];
    if (hash is! String || slotName is! String) return null;
    final slot = TextSlot.values.where((s) => s.name == slotName).firstOrNull;
    if (slot == null || slot.cover != cover) return null;
    return TextTrigger(cover: cover, box: box, hash: hash, slot: slot);
  }

  @override
  Map<String, Object?> toJson() => {
        'v': CoverEntryTrigger.version,
        'cover': cover.name,
        'kind': 'text',
        'box': {'w': box.width, 'h': box.height},
        'hash': hash,
        'slot': slot.name,
      };

  @override
  String get summary => slot.numeric ? 'a secret number' : 'a secret word';

  /// Trimmed, whitespace collapsed, case folded: keyboards capitalise and
  /// autocorrect, and the entropy lost is nothing beside a four-digit PIN.
  static String normalise(String raw) =>
      raw.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  bool matches(String raw) {
    final n = normalise(raw);
    if (n.isEmpty) return false;
    return AppLock.secretMatches(hash, n);
  }

  /// Why [raw] cannot be the secret for [slot], or null when it can.
  static String? admissibilityError(String raw, TextSlot slot) {
    final n = normalise(raw);
    if (n.length < kTextMin) return 'At least six characters.';
    if (n.length > kTextMax) return 'At most 24 characters.';
    if (slot.numeric) {
      if (!RegExp(r'^[0-9]+$').hasMatch(n)) return 'Digits only here.';
      if (n.split('').toSet().length == 1) {
        return 'One digit over and over is something people type — mix them.';
      }
      if (_isRun(n)) {
        return 'A straight run is something people type — mix the digits.';
      }
      if (n.endsWith('000')) {
        return 'Round numbers are something people type — mix the digits.';
      }
    } else if (n.split('').toSet().length == 1) {
      return 'One character repeated is too easy to type by accident.';
    }
    return null;
  }

  static bool _isRun(String digits) {
    var up = true;
    var down = true;
    for (var i = 1; i < digits.length; i++) {
      final d = digits.codeUnitAt(i) - digits.codeUnitAt(i - 1);
      if (d != 1) up = false;
      if (d != -1) down = false;
    }
    return up || down;
  }

  /// Derives the trigger from the word typed twice, or explains why not.
  static (TextTrigger?, String?) derive(
    String first,
    String second, {
    required TextSlot slot,
    required Size box,
  }) {
    final error = admissibilityError(first, slot);
    if (error != null) return (null, error);
    if (normalise(first) != normalise(second)) {
      return (null, 'The two did not match — type it again.');
    }
    return (
      TextTrigger(
        cover: slot.cover,
        box: box,
        hash: AppLock.hashSecret(normalise(first)),
        slot: slot,
      ),
      null,
    );
  }
}

/// Short-side units for a point in a box: the layer and the recorder share
/// this so a move is measured the same way on both sides.
Offset toShortSide(Offset p, Size box) {
  final s = math.min(box.width, box.height);
  return Offset(p.dx / s, p.dy / s);
}
