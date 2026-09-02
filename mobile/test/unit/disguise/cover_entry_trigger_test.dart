import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:miles/features/disguise/entry/cover_entry_trigger.dart';

/// The matcher is the whole door, and it runs silently: a rule that is too
/// loose opens for a stranger, a rule that is too tight locks the owner out,
/// and neither ever prints anything. So every rule is pinned here.
void main() {
  const box = Size(411, 869);

  /// A recording built from (x, y, durMs) triples with a fixed rhythm.
  List<TouchEvent> rec(List<(double, double, int)> touches, {int gap = 400}) {
    var t = 0;
    final out = <TouchEvent>[];
    for (final (x, y, dur) in touches) {
      out.add(TouchEvent(x: x, y: y, durMs: dur, downMs: t, upMs: t + dur));
      t += dur + gap;
    }
    return out;
  }

  TouchTrigger derive(List<TouchEvent> a, [List<TouchEvent>? b]) {
    final (t, err) = TouchTrigger.derive(
      a,
      b ?? a,
      cover: DisguiseCover.calculator,
      box: box,
    );
    // Not an expect: this runs at group scope too, where expect is illegal.
    if (err != null) throw StateError(err);
    return t!;
  }

  group('admissibility — the accident law', () {
    test('nothing recorded', () {
      expect(TouchTrigger.admissibilityError(const []), isNotNull);
    });

    test('one tap is refused', () {
      expect(TouchTrigger.admissibilityError(rec([(0.5, 0.5, 100)])),
          contains('One tap'),);
    });

    test('a lone hold needs three seconds', () {
      expect(TouchTrigger.admissibilityError(rec([(0.5, 0.5, 2000)])),
          contains('three seconds'),);
      expect(TouchTrigger.admissibilityError(rec([(0.5, 0.5, 3000)])), isNull);
    });

    test('the band between a tap and a hold is refused', () {
      expect(TouchTrigger.admissibilityError(rec([(0.5, 0.5, 500)])),
          contains('little longer'),);
    });

    test('a sequence passes with one hold of two seconds', () {
      expect(
        TouchTrigger.admissibilityError(rec([(0.2, 0.2, 100), (0.6, 0.6, 1500)])),
        isNull,
      );
      expect(
        TouchTrigger.admissibilityError(rec([(0.2, 0.2, 100), (0.6, 0.6, 900)])),
        contains('two seconds'),
      );
    });

    test('taps alone need five, quick, on two spots', () {
      List<(double, double, int)> taps(int n, {double dx = 0}) => [
            for (var i = 0; i < n; i++)
              (i.isEven ? 0.3 : 0.3 + dx, 0.5, 80),
          ];
      expect(TouchTrigger.admissibilityError(rec(taps(4, dx: 0.5), gap: 200)),
          contains('five'),);
      expect(TouchTrigger.admissibilityError(rec(taps(5, dx: 0.5), gap: 200)),
          isNull,);
      // Five taps on one spot is typing 77777.
      expect(TouchTrigger.admissibilityError(rec(taps(5), gap: 200)),
          contains('Same spot'),);
      // Five taps spread over four seconds is not a rhythm.
      expect(TouchTrigger.admissibilityError(rec(taps(5, dx: 0.5), gap: 900)),
          contains('faster'),);
    });
  });

  group('derivation from two recordings', () {
    test("tolerances come from the owner's own variance, floored and capped",
        () {
      final a = rec([(0.30, 0.50, 100), (0.70, 0.80, 2000)]);
      final b = rec([(0.31, 0.52, 100), (0.72, 0.80, 2400)]);
      final t = derive(a, b);
      expect(t.steps.length, 2);
      expect(t.steps[0].isHold, isFalse);
      expect(t.steps[1].holdMs, 2000, reason: 'the shorter of the two');
      expect(t.radius[0], kRadiusMin, reason: 'a steady pair hits the floor');
      expect(t.steps[1].x, closeTo(0.71, 1e-9));
      expect(t.windowMs, inInclusiveRange(2000, 12000));
      expect(t.gapMs, inInclusiveRange(1000, 4000));
    });

    test('a different shape the second time is named', () {
      final a = rec([(0.3, 0.5, 100), (0.7, 0.8, 2000)]);
      final b = rec([(0.3, 0.5, 100), (0.7, 0.8, 100), (0.5, 0.5, 2000)]);
      final (t, err) = TouchTrigger.derive(a, b,
          cover: DisguiseCover.calculator, box: box,);
      expect(t, isNull);
      expect(err, contains('1 tap and 1 hold'));
    });

    test('the same spot means within the cap', () {
      final a = rec([(0.3, 0.5, 100), (0.7, 0.8, 2000)]);
      final b = rec([(0.3, 0.5, 100), (0.95, 0.8, 2000)]);
      final (t, err) = TouchTrigger.derive(a, b,
          cover: DisguiseCover.calculator, box: box,);
      expect(t, isNull);
      expect(err, contains('same spot'));
    });

    test('an inadmissible first recording is refused before comparing', () {
      final (t, err) = TouchTrigger.derive(
        rec([(0.3, 0.5, 100)]),
        rec([(0.3, 0.5, 100)]),
        cover: DisguiseCover.calculator,
        box: box,
      );
      expect(t, isNull);
      expect(err, contains('One tap'));
    });
  });

  group('matching', () {
    final move = derive(rec([(0.30, 0.50, 100), (0.70, 0.80, 100),
        (0.50, 0.30, 2000),]),);

    test('the recorded rhythm at the recorded spots matches', () {
      expect(move.matchesTail(rec([(0.31, 0.49, 90), (0.69, 0.81, 110),
          (0.50, 0.31, 1400),]),), isTrue,
          reason: 'a hold at 0.6x the recorded length still counts',);
    });

    test('a stray tap before the move is harmless, after it is not', () {
      expect(move.matchesTail(rec([(0.1, 0.1, 80), (0.30, 0.50, 100),
          (0.70, 0.80, 100), (0.50, 0.30, 2000),]),), isTrue,);
      expect(move.matchesTail(rec([(0.30, 0.50, 100), (0.70, 0.80, 100),
          (0.50, 0.30, 2000), (0.1, 0.1, 80),]),), isFalse,);
    });

    test('off by more than the radius misses', () {
      expect(move.matchesTail(rec([(0.30, 0.50, 100), (0.70, 0.80, 100),
          (0.70, 0.30, 2000),]),), isFalse,);
    });

    test('a tap where a hold belongs misses, and the other way round', () {
      expect(move.matchesTail(rec([(0.30, 0.50, 100), (0.70, 0.80, 100),
          (0.50, 0.30, 100),]),), isFalse,);
      expect(move.matchesTail(rec([(0.30, 0.50, 900), (0.70, 0.80, 100),
          (0.50, 0.30, 2000),]),), isFalse,);
    });

    test('too slow misses: the window and the gap', () {
      expect(move.matchesTail(rec([(0.30, 0.50, 100), (0.70, 0.80, 100),
          (0.50, 0.30, 2000),], gap: 5000,),), isFalse,);
    });

    test('the final hold is armed while the finger is down', () {
      final prior = rec([(0.30, 0.50, 100), (0.70, 0.80, 100)]);
      final downMs = prior.last.upMs + 300;
      expect(move.armedHoldMs(prior, x: 0.51, y: 0.29, downMs: downMs), 1200,
          reason: '0.6 x 2000ms, above the 600ms floor',);
      expect(move.armedHoldMs(prior, x: 0.9, y: 0.9, downMs: downMs), isNull);
      expect(move.armedHoldMs(const [], x: 0.5, y: 0.3, downMs: 0), isNull,
          reason: 'the taps before the hold have not been made',);
      expect(
        move.armedHoldMs(prior, x: 0.5, y: 0.3, downMs: prior.last.upMs + 9000),
        isNull,
        reason: 'the gap before the hold ran out',
      );
    });

    test('a lone hold never arms sooner than one may be recorded', () {
      // 0.6 x 3000 is 1800, which would fire inside the reflex-press band
      // the record-time floor exists to exclude. The floor binds both ends.
      final lone = derive(rec([(0.5, 0.5, 3000)]));
      expect(lone.armedHoldMs(const [], x: 0.5, y: 0.5, downMs: 0),
          kLoneHoldMinMs,);
      expect(lone.matchesTail(rec([(0.5, 0.5, 3000)])), isTrue);
    });

    test('a box of another shape is never compared', () {
      expect(move.boxMatches(const Size(411, 869)), isTrue);
      expect(move.boxMatches(const Size(400, 850)), isTrue);
      expect(move.boxMatches(const Size(869, 411)), isFalse);
      expect(move.boxMatches(const Size(411, 500)), isFalse);
    });
  });

  group('json', () {
    test('a touch move round-trips', () {
      final move = derive(rec([(0.3, 0.5, 100), (0.7, 0.8, 2000)]));
      final back = CoverEntryTrigger.fromJson(move.encode());
      expect(back, isA<TouchTrigger>());
      expect(back!.encode(), move.encode());
      expect(back.cover, DisguiseCover.calculator);
    });

    test('a text move round-trips and still matches', () {
      final (t, err) = TextTrigger.derive('Lantern Fish', 'lantern fish',
          slot: TextSlot.notes, box: box,);
      expect(err, isNull);
      final back = CoverEntryTrigger.fromJson(t!.encode())! as TextTrigger;
      expect(back.matches('  LANTERN   fish '), isTrue);
      expect(back.matches('lanternfish'), isFalse);
      expect(back.encode(), isNot(contains('lantern')),
          reason: 'only the salted hash is stored',);
    });

    test('anything unreadable is null, never a throw', () {
      expect(CoverEntryTrigger.fromJson('not json'), isNull);
      expect(CoverEntryTrigger.fromJson('[]'), isNull);
      expect(CoverEntryTrigger.fromJson(jsonEncode({'v': 2})), isNull);
      final move = derive(rec([(0.3, 0.5, 100), (0.7, 0.8, 2000)]));
      final m = move.toJson();
      expect(CoverEntryTrigger.fromJson(jsonEncode({...m, 'kind': 'stroke'})),
          isNull, reason: 'a kind this build cannot match',);
      expect(CoverEntryTrigger.fromJson(jsonEncode({...m, 'cover': 'none'})),
          isNull,);
      expect(CoverEntryTrigger.fromJson(jsonEncode({...m, 'radius': [0.1]})),
          isNull, reason: 'steps and radii must pair up',);
      expect(CoverEntryTrigger.fromJson(jsonEncode({...m, 'box': {'w': 0}})),
          isNull,);
    });

    test('a text record whose slot belongs to another cover is null', () {
      final (t, _) = TextTrigger.derive('123457', '123457',
          slot: TextSlot.calc, box: box,);
      final m = t!.toJson();
      expect(CoverEntryTrigger.fromJson(jsonEncode({...m, 'cover': 'notes'})),
          isNull,);
    });
  });

  group('secret text', () {
    test('length and charset per slot', () {
      expect(TextTrigger.admissibilityError('12345', TextSlot.calc),
          contains('six'),);
      expect(TextTrigger.admissibilityError('12a456', TextSlot.calc),
          contains('Digits'),);
      expect(TextTrigger.admissibilityError('12a456', TextSlot.notes), isNull);
      expect(TextTrigger.admissibilityError('x' * 25, TextSlot.notes),
          contains('24'),);
    });

    test('numbers people type are refused', () {
      expect(TextTrigger.admissibilityError('111111', TextSlot.calc),
          contains('One digit over and over'),);
      expect(TextTrigger.admissibilityError('123456', TextSlot.convert),
          contains('straight run'),);
      expect(TextTrigger.admissibilityError('987654', TextSlot.calc),
          contains('straight run'),);
      expect(TextTrigger.admissibilityError('120000', TextSlot.calc),
          contains('Round'),);
      expect(TextTrigger.admissibilityError('471193', TextSlot.calc), isNull);
    });

    test('the two entries must agree after normalising', () {
      final (t, err) = TextTrigger.derive('471193', '471194',
          slot: TextSlot.calc, box: box,);
      expect(t, isNull);
      expect(err, contains('did not match'));
    });

    test('the hash is the app lock format', () {
      final (t, _) = TextTrigger.derive('471193', '471193',
          slot: TextSlot.calc, box: box,);
      expect(t!.hash, startsWith('sha256:'));
      expect(AppLock.secretMatches(t.hash, '471193'), isTrue);
    });
  });

  test('short-side units are the same on both axes', () {
    final p = toShortSide(const Offset(411, 411), const Size(411, 869));
    expect(p.dx, 1);
    expect(p.dy, 1);
  });
}
