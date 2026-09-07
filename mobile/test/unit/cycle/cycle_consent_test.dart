import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Her consent must never be reconstructed from a default.
///
/// `CycleSettings.shareWithPartner` defaults to TRUE, every control on the
/// cycle screen writes the WHOLE row back through one upsert, and
/// `cycle_events_partner_read` (20260601002220) gates her partner's SELECT on
/// that column — the 2026-08-17 audit migration exists precisely because the
/// client-side hide was ruled "a UI hide, not an access control".
///
/// So while `_settings` held a default instance and the load's catch was bare,
/// a first read that threw — a paused free-tier project, a handset off the
/// network — rendered the tracker over `shareWithPartner: true`, and her next
/// stepper tap committed it over a row that said false. Nothing failed, nothing
/// was logged, and the wrong value survived the network coming back.
///
/// It is unobservable without a failing backend and there is no device here, so
/// the invariant is asserted against the source: the state cannot be built, so
/// the write cannot happen.
void main() {
  // Newlines normalised before anything scans this. The separator below is
  // '\n\n  ', and on a CRLF checkout — which this repo has — the file contains
  // '\r\n\r\n  ' and never matches it. bodyOf then silently returned the WHOLE
  // FILE, so every assertion below passed on a hit anywhere in 700 lines and
  // the test could not fail.
  final src = File('lib/features/cycle/cycle_screen.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  /// A method body, from its signature to the start of the next member.
  String bodyOf(String signature) {
    final start = src.indexOf(signature);
    expect(start, greaterThan(-1),
        reason: '$signature is gone from cycle_screen.dart — this file is '
            'asserting nothing until it is retargeted.',);
    final end = src.indexOf('\n\n  ', start);
    expect(end, greaterThan(start),
        reason: 'no member boundary after $signature — the scan would widen to '
            'the rest of the file and assert nothing.',);
    return src.substring(start, end);
  }

  test('a failed cycle read cannot be written back as her settings', () {
    expect(src.contains('CycleSettings? _settings;'), isTrue,
        reason: 'The settings field must stay nullable and unassigned: null is '
            'what says "her row has never been read on this screen". A default '
            'instance here is a consent record the user never gave.',);
    expect(src.contains('CycleSettings _settings = '), isFalse,
        reason: 'A default CycleSettings shares her cycle with her partner. '
            'Rendered after a failed read, one stepper tap upserts it.',);
    expect(src.contains('Widget _settingsCard(CycleSettings'), isTrue,
        reason: 'The settings card must take the loaded settings as an '
            'argument. Reading the field instead is what let a control exist '
            'for a row this screen had never read.',);
  });

  test('a failed cycle read is reported and shown, not swallowed', () {
    final load = bodyOf('Future<void> _load() async {');
    expect(load.contains('catch (e, st)'), isTrue,
        reason: '`catch (_)` here cleared the spinner and said nothing, which '
            'is what made a failed read look like an empty one.',);
    expect(load.contains('ErrorReporter.report'), isTrue,
        reason: 'A cycle read failing in the field must reach client_errors — '
            'debugPrint is compiled out of a release build.',);
    expect(load.contains('_loadError ='), isTrue,
        reason: 'The screen must be able to render the failure distinctly '
            'from an empty tracker.',);
  });

  test('the cycle channel is rebuilt through ManagedSubscription', () {
    expect(src.contains('ManagedSubscription'), isTrue,
        reason: 'The hand-rolled unsubscribe-then-re-channel on every resume '
            'races a duplicate channel onto the same topic — `channel()` never '
            'dedupes and `unsubscribe()` only schedules a leave. Her partner '
            'edits then stop arriving with nothing said.',);
    expect(src.contains('realtimeResumed.addListener'), isFalse,
        reason: 'ManagedSubscription owns the resume listener; a second one '
            'here would rebuild the channel twice per reconnect.',);
  });

  test('the consent subtitle names what the partner view renders', () {
    // The switch said 'a gentle heads-up — never the details' while
    // _partnerView prints a day countdown, whether it has started and a
    // phase-selected note, from her raw rows. The consent sentence must be
    // derived from the three things the partner surface renders.
    final card = bodyOf('Widget _settingsCard(CycleSettings settings) {');
    expect(card, isNot(contains('never the details')));
    for (final word in ['countdown', 'started', 'note']) {
      expect(card, contains(word), reason: 'the subtitle must name: $word');
    }
    final partner = bodyOf('List<Widget> _partnerView() {');
    expect(partner, contains('Next period in'));
    expect(partner, contains('started her period'));
    expect(partner, contains('partnerNote'));
  });
}
