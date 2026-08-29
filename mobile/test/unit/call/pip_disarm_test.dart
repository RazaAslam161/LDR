import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Android PiP has to be DISARMED when a call ends, not merely forgotten.
///
/// `PipMode.setWanted(true)` is native state on the Activity — MainActivity
/// keeps `pipWanted` in a plain field and resets it nowhere — so a minimised
/// call that ends leaves the home button armed for the rest of the process. The
/// next home press, with no call anywhere, floats the REAL Miles UI over the
/// launcher, and main.dart exempts `PipMode.active` from the disguise cover, so
/// nothing comes down over it.
///
/// Source-read, because entering PiP needs a handset and this machine has no
/// Android SDK. The trap this pins is subtle enough to be re-introduced by
/// anyone tidying `_teardown`: the reset there is a RAW field write, and
/// routing it through `setMinimized(false)` would look cleaner while silently
/// doing nothing.
void main() {
  final controller =
      File('lib/features/call/call_controller.dart').readAsStringSync();
  final start = controller.indexOf('Future<void> _teardown(CallState end)');
  final stop = controller.indexOf('/// Keep the display awake', start + 1);
  // Checked as its own test: a rename would otherwise turn every assertion
  // below into a vacuous pass over an empty string.
  test('the teardown body is still where this test reads it', () {
    expect(start, greaterThan(-1), reason: '_teardown was renamed');
    expect(stop, greaterThan(start), reason: '_teardown no longer ends here');
  });
  final teardown =
      start < 0 || stop <= start ? '' : controller.substring(start, stop);

  test('_teardown disarms PiP itself', () {
    expect(teardown.contains('PipMode.setWanted(false)'), isTrue,
        reason: 'every call exit runs through _teardown; without the disarm '
            'here, pipWanted stays true until the process dies',);
  });

  test('the disarm cannot be routed through setMinimized', () {
    // The setter is the arm/disarm owner for the LIVE call, and its early-out
    // is correct there. It is also exactly why _teardown may not delegate: the
    // field is already false on most exits, so the setter would return before
    // reaching setWanted.
    expect(controller.contains('if (minimized == v) return;'), isTrue,
        reason: "setMinimized's early-out is what makes a delegated disarm a "
            'no-op — if it is gone, re-read the teardown path',);
    expect(teardown.contains('setMinimized('), isFalse,
        reason: 'a delegated disarm is silently skipped whenever minimized is '
            'already false',);
  });
}
