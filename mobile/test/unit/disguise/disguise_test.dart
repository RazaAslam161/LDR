import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/disguise/disguise_profile.dart';

/// The cover screen each identity renders. Read by the tests below, which
/// assert on the source because the thing being protected — "this gesture is
/// actually wired to something" — is not observable from the catalog alone.
const _coverSources = {
  DisguiseCover.news: 'lib/features/covers/news_cover_screen.dart',
  DisguiseCover.calculator:
      'lib/features/disguise/covers/calculator_cover.dart',
  DisguiseCover.notes: 'lib/features/disguise/covers/notes_cover.dart',
  DisguiseCover.weather: 'lib/features/disguise/covers/weather_cover.dart',
  DisguiseCover.convert: 'lib/features/disguise/covers/convert_cover.dart',
  DisguiseCover.recorder: 'lib/features/disguise/covers/recorder_cover.dart',
  DisguiseCover.timer: 'lib/features/disguise/covers/timer_cover.dart',
  DisguiseCover.level: 'lib/features/disguise/covers/level_cover.dart',
  DisguiseCover.device: 'lib/features/disguise/covers/device_info_cover.dart',
};

/// Everything that runs the entry flow. The News cover predates the [CoverGate]
/// mixin and still owns its own copy, which is why there are two names.
final _gateCall = RegExp(r'\b(runEntryGate|_triggerEntry)\b');

/// Source with comment lines blanked, so a gesture described in a doc comment
/// cannot pass for one that is wired up.
String _code(String src) => src
    .split('\n')
    .map((l) => l.trimLeft().startsWith('//') ? '' : l)
    .join('\n');

/// Whether [name], used as a gesture callback, ends up running the entry flow.
///
/// Three ways it can: it IS the gate; it is a handler whose body calls the
/// gate; or it is a named argument bound to one of those further up the file —
/// which is how the notepad passes `runEntryGate` down to its empty state.
bool _reachesGate(String name, String code, [int depth = 0]) {
  if (_gateCall.hasMatch('$name(')) return true;
  if (depth > 2) return false;

  final decl =
      RegExp('\\b$name' r'\s*\([^)]*\)\s*(?:async\s*)?\{').firstMatch(code);
  if (decl != null) {
    // Handlers in these files are a few lines; 800 characters is comfortably
    // past the end of one.
    final end = (decl.start + 800).clamp(0, code.length);
    if (_gateCall.hasMatch(code.substring(decl.start, end))) return true;
  }

  for (final m in RegExp('\\b$name' r':\s*([A-Za-z_]\w*)').allMatches(code)) {
    if (_reachesGate(m.group(1)!, code, depth + 1)) return true;
  }
  return false;
}

void main() {
  group('disguise catalog', () {
    test('every offered disguise has a cover that exists', () {
      // A launcher icon whose cover does not match is a louder tell than no
      // disguise at all, so the catalog may only offer covers that are built.
      for (final d in kDisguises) {
        final path = _coverSources[d.cover];
        expect(path, isNotNull,
            reason: '${d.label} is offered but ${d.cover} has no cover screen',);
        expect(File(path!).existsSync(), isTrue,
            reason: '${d.label} names $path, which does not exist',);
      }
    });

    test('every cover in the enum is offered', () {
      // The other direction: a cover built and then never listed is dead code
      // that looks like a feature.
      //
      // `none` is excluded because it is the ABSENCE of a cover, not one of
      // them — kDisguises answers "which covers exist" and the plain identity
      // is not an answer to that. It belongs to kPlainProfile, asserted below.
      final offered = kDisguises.map((d) => d.cover).toSet();
      final coversThatExist =
          DisguiseCover.values.toSet()..remove(DisguiseCover.none);
      expect(offered, coversThatExist);
      expect(kPlainProfile.cover, DisguiseCover.none,
          reason: 'the plain identity must draw no cover — a launcher that '
              'says Miles opening a news reader is the bug this prevents',);
    });

    test('alias ids are unique — they map 1:1 to manifest aliases', () {
      final ids = kDisguises.map((d) => d.aliasId).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('alias ids are safe to interpolate into a component name', () {
      // MainActivity builds "$packageName.Alias$aliasId"; anything but a bare
      // identifier would silently target a component that does not exist.
      for (final d in kDisguises) {
        expect(RegExp(r'^[A-Za-z][A-Za-z0-9]*$').hasMatch(d.aliasId), isTrue,
            reason: '${d.aliasId} is not a valid component-name suffix',);
      }
    });

    test('the default is the alias the manifest ships enabled', () {
      // Exactly one <activity-alias> has android:enabled="true" (News). If the
      // default here disagreed, a fresh install would render the wrong cover.
      expect(kDefaultDisguise.aliasId, 'News');
      expect(kDisguises.first.aliasId, kDefaultDisguise.aliasId);
    });

    test('an unknown or missing alias falls back to the default', () {
      expect(disguiseForAlias(null).aliasId, kDefaultDisguise.aliasId);
      expect(disguiseForAlias('Nonexistent').aliasId, kDefaultDisguise.aliasId);
      expect(disguiseForAlias('Calculator').cover, DisguiseCover.calculator);
    });
  });

  group('entry doors', () {
    test('every disguise documents a distinct way in', () {
      // Non-empty first: the apply confirmation interpolates this string as
      // the way back (play contract item 2), so a cover without one ships a
      // lockout behind a dialog that promises nothing. Distinct second: two
      // covers that describe the same gesture means one of them is wrong, and
      // the user cannot tell which — the picker and that dialog are the only
      // places these are ever written down.
      final seen = <String, String>{};
      for (final d in kDisguises) {
        expect(d.entry.trim(), isNotEmpty,
            reason: '${d.label} has no entry gesture written down',);
        final key = d.entry.trim().toLowerCase();
        expect(seen.containsKey(key), isFalse,
            reason: '${d.label} and ${seen[key]} claim the same gesture: '
                '${d.entry}',);
        seen[key] = d.label;
      }
    });

    test('no cover is a no-op — every door reaches the entry flow', () {
      // The failure this exists for: a cover that renders beautifully and has
      // no way in. It is invisible to the analyzer, invisible to a widget test
      // that never long-presses, and it locks the owner out of their own app
      // with no recovery short of a reinstall.
      for (final entry in _coverSources.entries) {
        final code = _code(File(entry.value).readAsStringSync());
        expect(_gateCall.hasMatch(code), isTrue,
            reason: '${entry.key} never calls the entry gate — it is a dead '
                'cover with no way in',);
      }
    });

    test('every door is wired to a real gesture', () {
      // Calling the gate somewhere is not enough: it has to hang off a handler
      // the user can actually reach. Reaching it only from initState, or only
      // from the incoming-call listener every cover inherits, is exactly the
      // shape of a cover with no door — and it would look completely finished.
      final callback =
          RegExp(r'on(?:LongPress|Tap|TapDown|Submitted|Selected)\w*:');
      final identifier = RegExp(r'[A-Za-z_]\w*');

      for (final entry in _coverSources.entries) {
        final code = _code(File(entry.value).readAsStringSync());
        final wired = <String>{};
        for (final m in callback.allMatches(code)) {
          // A callback often wraps onto the next line or sits inside a
          // conditional, so take a window rather than the rest of the line.
          final end = (m.end + 120).clamp(0, code.length);
          wired.addAll(identifier
              .allMatches(code.substring(m.end, end))
              .map((i) => i.group(0)!),);
        }
        expect(wired, isNotEmpty,
            reason: '${entry.key} declares no gesture callbacks at all',);
        expect(wired.any((name) => _reachesGate(name, code)), isTrue,
            reason: '${entry.key} calls the entry gate, but no gesture the '
                'user can perform reaches it',);
      }
    });

    test('every cover names the way back, for its own identity', () {
      // This used to pin a widget: every cover had to draw a CoverExitButton,
      // a small unlabelled ring in the app bar. Conspicuous and mute is the
      // worst pair on a screen pretending to be a weather app — it was the one
      // thing worth tapping and it said nothing — so the ring is gone and an
      // element each cover already draws opens an About sheet instead.
      //
      // The widget was never the property worth protecting. These three are:
      // a way back exists on every cover; it names THIS cover's gesture, not
      // another's; and its action reaches the same gate the hidden trigger
      // does. A tenth cover that ships without one ships a lockout, and one
      // that passes the wrong DisguiseCover hands the owner instructions that
      // do not work — the exact bug the apply dialog shipped once, when it
      // printed the News gesture under all nine covers.
      for (final entry in _coverSources.entries) {
        final code = _code(File(entry.value).readAsStringSync());
        final calls = RegExp(r'showCoverAbout\(').allMatches(code).toList();
        expect(calls, isNotEmpty,
            reason: '${entry.key} opens no About sheet — nothing on the screen '
                'can tell the owner the way back',);
        // Read out of the call itself, not the file: a cover that passed the
        // wrong value while merely mentioning the right one somewhere else
        // would satisfy a whole-file substring.
        final identities = calls.map((m) {
          final end = (m.end + 300).clamp(0, code.length);
          return RegExp(r'cover:\s*DisguiseCover\.(\w+)')
              .firstMatch(code.substring(m.start, end))
              ?.group(1);
        }).toSet();
        expect(identities, {entry.key.name},
            reason: '${entry.key} opens an About sheet for a different '
                "identity — it would print another cover's gesture",);
        // Opening the sheet is not enough: its Open action has to reach the
        // entry flow, or the way out is a leaflet with no door behind it.
        final wired = calls.any((m) {
          final end = (m.end + 300).clamp(0, code.length);
          final bound = RegExp(r'onOpen:\s*([A-Za-z_]\w*)')
              .firstMatch(code.substring(m.start, end));
          return bound != null && _reachesGate(bound.group(1)!, code);
        });
        expect(wired, isTrue,
            reason: '${entry.key} opens the About sheet but its onOpen never '
                'reaches the entry gate',);
      }
    });

    test('every disguise names what to tap for its About panel', () {
      // The apply dialog interpolates this ("Tap ${d.about} to see this
      // again"), which is the only place the About panel is ever advertised.
      // It used to promise "a small ring near the top right" for all nine —
      // true until the ring was deleted, and then a lie on all nine. Living
      // beside `entry` is what stops that happening a third time.
      final seen = <String, String>{};
      for (final d in kDisguises) {
        expect(d.about.trim(), isNotEmpty,
            reason: '${d.label} names nothing to tap, so the apply dialog '
                'advertises its About panel with a blank',);
        expect(d.about.trim().endsWith('.'), isFalse,
            reason: '${d.label}: `about` is interpolated mid-sentence, so a '
                'trailing full stop lands in the middle of the dialog',);
        final key = d.about.trim().toLowerCase();
        expect(seen.containsKey(key), isFalse,
            reason: '${d.label} and ${seen[key]} claim the same About '
                'affordance: ${d.about}',);
        seen[key] = d.label;
      }
    });

    test('the guide documents every disguise and its gesture', () {
      // The picker prints these, but the owner needs them somewhere he can
      // read without opening the app he is locked out of.
      final guide = File('../docs/guides/disguises.md').readAsStringSync();
      for (final d in kDisguises) {
        expect(guide.contains(d.label), isTrue,
            reason: '${d.label} is missing from docs/guides/disguises.md',);
        // Punctuation drifts; the words do not.
        final words = d.entry
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
            .split(RegExp(r'\s+'))
            .where((w) => w.length > 3)
            .toList();
        final text = guide.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
        final missing = words.where((w) => !text.contains(w)).toList();
        expect(missing, isEmpty,
            reason: "${d.label}'s gesture is not described in the guide: "
                'missing $missing',);
      }
    });

    test('no door hangs off typing, which is ordinary use everywhere', () {
      // The News cover opened the gate when `home` was submitted in its search
      // box. Searching a news reader for "home" is something a person does on
      // purpose, so the door was reachable by using the app as intended — and
      // what it produced was a biometric prompt in front of whoever was
      // holding the phone. Nothing a user types may be a door, in any cover.
      for (final entry in _coverSources.entries) {
        final code = _code(File(entry.value).readAsStringSync());
        for (final m
            in RegExp(r'on(?:Submitted|Changed|Editing\w*):\s*([A-Za-z_]\w*)')
                .allMatches(code)) {
          expect(_reachesGate(m.group(1)!, code), isFalse,
              reason: '${entry.key} opens the entry gate from ${m.group(1)} — '
                  'a text callback the user reaches by typing',);
        }
      }
    });
  });
}
