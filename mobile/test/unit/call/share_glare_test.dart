import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/call/call_controller.dart';

/// Simultaneous share, modelled as the two handsets it actually happens on.
///
/// This exists because the first fix for this bug was WRONG and shipped: it
/// reused `callGlareFor`, which compares two call ids. That is right for the
/// call, where two different calls compete. A share happens INSIDE one call, so
/// both peers hold the same `_callId`, `callGlareFor` returns `undecidable` for
/// equal ids, and the caller treated everything except `keepMine` as "yield" —
/// symmetric again, so both shares died exactly as before.
///
/// Nothing caught it. The share's "law" test greps source text, and the real
/// logic sat in an async method on a controller that cannot be constructed off
/// a device. So the decision was pulled out as a pure function, and this asserts
/// the PROPERTY that was violated rather than the shape of the code.
void main() {
  group('simultaneous share', () {
    // The property. Not "the caller wins" — that is an implementation choice —
    // but that the two handsets never agree, because agreement is what kills
    // both shares.
    test('exactly one peer keeps its share, never both, never neither', () {
      const callerKeeps = true;
      const calleeKeeps = false;
      expect(shareGlareKeepsMine(isCaller: callerKeeps), isTrue);
      expect(shareGlareKeepsMine(isCaller: calleeKeeps), isFalse);

      final decisions = [
        shareGlareKeepsMine(isCaller: callerKeeps),
        shareGlareKeepsMine(isCaller: calleeKeeps),
      ];
      expect(decisions.where((k) => k).length, 1,
          reason: 'both yielding kills both shares; both keeping is a loop',);
    });

    test('the decision is asymmetric for every possible pairing', () {
      for (final iAmCaller in [true, false]) {
        final mine = shareGlareKeepsMine(isCaller: iAmCaller);
        final theirs = shareGlareKeepsMine(isCaller: !iAmCaller);
        expect(mine == theirs, isFalse,
            reason: 'peers must not reach the same conclusion',);
      }
    });

    // The regression, pinned so nobody reaches for callGlareFor here again.
    test('callGlareFor cannot decide this — both peers share one call id', () {
      const shared = 'call-abc-123';
      expect(callGlareFor(mine: shared, theirs: shared), CallGlare.undecidable,
          reason: 'equal ids are undecidable, which is why the first fix was '
              'dead code that always fell through to yield',);
    });

    test('and it still works for the CALL, where the ids differ', () {
      expect(callGlareFor(mine: 'aaa', theirs: 'bbb'), CallGlare.keepMine);
      expect(callGlareFor(mine: 'bbb', theirs: 'aaa'), CallGlare.yieldToPeer);
    });
  });
}
