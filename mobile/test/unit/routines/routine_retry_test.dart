import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The chart's failure state was unreachable, and then it was a lie.
///
/// `reload()` used to swallow a failed FIRST load, so the screen's error branch
/// never ran and a bare spinner was the terminal state. Making that branch
/// reachable exposed what it rendered: the empty state's grey line of text with
/// different words on it — "Couldn't load the chart. Pull to try again." — on a
/// feature with no RefreshIndicator in either of its files. A read that failed
/// looked like a chart with nothing on it, and the only instruction it gave
/// named a gesture that does nothing.
///
/// The other half is recovery. ManagedSubscription rebuilds its channel on
/// every socket resume and does nothing else, so with neither builder
/// re-reading, returning to the network never re-fetched: the chart stayed on
/// pre-outage rows, and a first load that errored stayed errored forever.
///
/// Neither is observable without a failing backend and there is no device here,
/// so both are asserted against the source.
void main() {
  // Normalised before anything scans it: this repo is a CRLF checkout, and a
  // scan for a '\n'-separated marker silently matches nothing there.
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  final screen = read('lib/features/routines/routine_screen.dart');
  final repo = read('lib/features/routines/routine_repository.dart');

  test('the chart names no refresh gesture it does not have', () {
    final hasIndicator = screen.contains('RefreshIndicator') ||
        repo.contains('RefreshIndicator');
    expect(
      hasIndicator || !screen.toLowerCase().contains('pull to'),
      isTrue,
      reason: 'The failure state told the user to pull to refresh on a screen '
          'whose body is a Column and a ListView with no RefreshIndicator '
          'anywhere. Either wire one up or stop naming the gesture.',
    );
  });

  test('a failed chart renders its own state, not the empty one', () {
    expect(screen.contains('return _LoadFailed(onRetry: _retry);'), isTrue,
        reason: 'snap.hasError must render the failure widget. Returning a '
            '_Note here is what made a read that failed indistinguishable from '
            'a chart with nothing on it.',);
    expect(screen.contains('class _LoadFailed extends StatelessWidget'), isTrue,
        reason: 'The failure state has to be its own widget — it carries an '
            'icon and a button the empty state must not have.',);
    expect(screen.contains('onPressed: onRetry'), isTrue,
        reason: 'The failure state needs a control that actually re-runs the '
            'load. Text describing a retry is not a retry.',);
  });

  test('the retry rebuilds the stream instead of no-opping', () {
    const signature = 'void _retry() {';
    final start = screen.indexOf(signature);
    expect(start, greaterThan(-1),
        reason: '_retry is gone from routine_screen.dart — this test asserts '
            'nothing until it is retargeted.',);
    final end = screen.indexOf('\n\n  ', start);
    expect(end, greaterThan(start),
        reason: 'no member boundary after _retry — the scan would widen to the '
            'rest of the file and assert nothing.',);
    final body = screen.substring(start, end);

    expect(body.contains('RoutineRepository.stream('), isTrue,
        reason: 'The error comes from a first load that threw before anything '
            'was delivered. Only a fresh stream re-runs it; setState alone '
            'redraws the same errored snapshot.',);
    expect(body.contains('showSnackBar'), isTrue,
        reason: 'The one path that cannot rebuild the stream — a session with '
            'no couple — has to say so. Returning silently is a button that '
            'does nothing, which is the defect being fixed.',);
  });

  test('both routine subscriptions re-read when they are rebuilt', () {
    const guard = 'if (subscribed) unawaited(reload());';
    expect(guard.allMatches(repo).length, 2,
        reason: 'A socket resume rebuilds the channel and nothing else. '
            'Without a re-read in BOTH builders — they rejoin on independent '
            'jitter, so either can come back first — a tick written while the '
            'phone was offline arrives by no path at all, and an errored first '
            'load can only be cleared by hand.',);
    expect(repo.indexOf('subscribed = true;'),
        greaterThan(repo.indexOf('await reload();')),
        reason: 'The flag is set only AFTER the ordered first load. Set '
            'earlier, the re-read inside the builder races ahead of '
            'ensureDefaults and paints an empty chart over a couple whose '
            'defaults were still being seeded.',);
  });
}
