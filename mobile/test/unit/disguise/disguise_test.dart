import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/disguise/cover_gate.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:miles/features/disguise/entry/entry_trigger_layer.dart';

/// The cover screen each identity renders. Read by the tests below, which
/// assert on the source because the thing being protected — "this cover
/// carries no door of its own" — is not observable from the catalog alone.
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

/// Source with comment lines blanked, so a door named in a doc comment (every
/// cover's own history names the one it used to have) cannot trip a scan.
String _code(String src) => src
    .split('\n')
    .map((l) => l.trimLeft().startsWith('//') ? '' : l)
    .join('\n');

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

    test('the host draws every cover from the one builder', () {
      // The recorder and the host both call buildCoverWidget, so the owner's
      // move is recorded on exactly the widget it is later matched on. A
      // cover missing from the switch is a compile error in Dart; a cover
      // added to the enum and drawn somewhere else is what this catches.
      final host = _code(
        File('lib/features/disguise/disguise_cover_host.dart')
            .readAsStringSync(),
      );
      final at = host.indexOf('Widget buildCoverWidget');
      expect(at, isNonNegative,
          reason: 'buildCoverWidget is gone — the recorder and the host would '
              'no longer draw the same cover',);
      final builder = host.substring(at);
      for (final cover in DisguiseCover.values) {
        expect(builder.contains('DisguiseCover.${cover.name} =>'), isTrue,
            reason: 'buildCoverWidget does not draw ${cover.name}',);
      }
    });
  });

  group('no cover owns a door', () {
    // The app ships no entry gesture. Every way in is the owner's own
    // recorded move or the backup hold, both matched by the host's pointer
    // layer above the cover — so a cover file that reaches the gate, names
    // the lock, or carries a hold handler of its own is a door the app
    // authored, which is the one thing the owner asked to have none of.
    test('no cover reaches the gate, the lock or the move store', () {
      // Everything that opens the app, by any route: the gate and its
      // sources, the lock and the reveal, the store and the layer, the
      // scope's own open hook, and the two statics behind the cover itself.
      final banned = RegExp(
        r'\b(CoverEntry|EntrySource|onOpen|runEntryGate|showCoverAbout|'
        'CoverAboutTap|LockScreen|IntroSplashScreen|CoverEntryStore|'
        r'EntryTriggerLayer|onAuthenticated|showRealApp|raiseCover)\b',
      );
      const bannedImports = [
        'cover_gate.dart',
        'disguise_cover_host.dart',
        'cover_entry_store.dart',
        'entry_trigger_layer.dart',
        'package:miles/main.dart',
      ];
      for (final entry in _coverSources.entries) {
        final code = _code(File(entry.value).readAsStringSync());
        final hit = banned.firstMatch(code);
        expect(hit, isNull,
            reason: '${entry.key} names ${hit?.group(0)} — a cover carries '
                'no door of its own',);
        for (final import in bannedImports) {
          expect(code.contains(import), isFalse,
              reason: '${entry.key} imports $import',);
        }
      }
    });

    test('no cover declares a hold of its own', () {
      // The shapes every old door had: a long-press handler, a tap-down that
      // armed a timer, or a raw recogniser. A cover may keep an InkWell's
      // default long-press (which is nothing); it may not wire one to a
      // handler, and it may not watch pointers itself.
      final hold = RegExp(
        r'(on(?:LongPress|TapDown|TapCancel)\w*:\s*(?!null\b))|'
        r'\b(RawGestureDetector|LongPressGestureRecognizer|onPointerDown|'
        r'onPointerUp)\b',
      );
      for (final entry in _coverSources.entries) {
        final code = _code(File(entry.value).readAsStringSync());
        expect(hold.hasMatch(code), isFalse,
            reason: '${entry.key} wires a long-press handler',);
      }
    });

    test('a committed word reaches the scope only from a control, never from '
        'typing', () {
      // The News search once opened the gate on `home`, which a person types
      // on purpose; a keyboard's Enter is the same door. The three covers
      // that take a secret word hand it over from a control they already
      // have — the = key, the swap button, Save — and nothing else may.
      final typing = RegExp(r'on(?:Submitted|Changed|Editing\w*):');
      final feed = RegExp(r'feedText\(');
      final commits = {
        DisguiseCover.calculator,
        DisguiseCover.convert,
        DisguiseCover.notes,
      };
      for (final entry in _coverSources.entries) {
        final code = _code(File(entry.value).readAsStringSync());
        final feeds = feed.allMatches(code).toList();
        if (!commits.contains(entry.key)) {
          expect(feeds, isEmpty,
              reason: '${entry.key} hands text to the scope but has no '
                  'commit control to do it from',);
          continue;
        }
        expect(feeds.length, 1,
            reason: '${entry.key} must hand text over from exactly one '
                'control',);
        final call = code.substring(
          feeds.single.start,
          (feeds.single.end + 80).clamp(0, code.length),
        );
        expect(call.contains('commit: true'), isTrue,
            reason: '${entry.key} hands text over uncommitted',);
        for (final m in typing.allMatches(code)) {
          final window = code.substring(
            m.end,
            (m.end + 300).clamp(0, code.length),
          );
          expect(feed.hasMatch(window), isFalse,
              reason: '${entry.key} hands text over from a typing callback',);
        }
      }
    });

    test('no user-facing surface teaches the backup gesture', () {
      // Owner's ruling 2026-09-03: the hold stays, and users are not told
      // about it. It reached four dialogs, both FAQs and the public site the
      // first time round, so the rule is pinned rather than remembered.
      //
      // Matched on the shapes a hint actually takes, not on "hold" alone —
      // "hold to confirm" buttons are unrelated and must stay legal.
      final hint = RegExp(
        r'(two|2)[\s-]*fingers?|fingers?[\s\S]{0,40}(five|ten|5|10)[\s-]*seconds',
        caseSensitive: false,
      );
      // Dart comments explain the gesture to maintainers and that is allowed,
      // so only shipped strings are searched. HTML is read raw: _code() would
      // treat "https://" as a line comment and blank the rest of the line,
      // which could hide the sentence being looked for.
      final surfaces = <String>[
        'lib/features/legal/faq_text.dart',
        'lib/features/disguise/disguise_picker_screen.dart',
        'lib/features/disguise/entry/cover_entry_recorder_screen.dart',
        'lib/features/shell/app_shell.dart',
        'lib/features/settings/settings_screen.dart',
        '../web/faq.html',
        '../web/privacy-policy.html',
        '../web/security.html',
      ];
      for (final path in surfaces) {
        final f = File(path);
        if (!f.existsSync()) {
          fail('$path is missing; the surface list needs updating');
        }
        final raw = f.readAsStringSync();
        final text = path.endsWith('.dart') ? _code(raw) : raw;
        expect(hint.hasMatch(text), isFalse,
            reason: '$path teaches the backup gesture. It is undisclosed: the '
                'app, the FAQ and the public site must not name it. Play '
                "Console's App access notes are the only place it belongs.",);
      }
    });

    test('the guide documents the backup hold and every cover', () {
      // A maintainer has to be able to find it; a user must not. The guide is
      // repo-only, so it is where the gesture is allowed to be written down.
      final guide = File('../docs/guides/disguises.md').readAsStringSync();
      expect(guide.contains('two fingers'), isTrue);
      expect(guide.contains('ten seconds'), isTrue);
      for (final d in kDisguises) {
        expect(guide.contains(d.label), isTrue,
            reason: '${d.label} is missing from docs/guides/disguises.md',);
      }
    });

    test('the gate can never become a door with no key', () {
      // A OnePlus 7 with no fingerprint, no face and no screen lock applied a
      // cover and could not get back in: the gate read AppLock.authenticate()'s
      // `false` as a verdict, when its own doc says false means the CALLER
      // falls back to the PIN. On a handset where no credential is enrolled it
      // can only ever return false, so the way back in was a control that did
      // nothing. Same build, same code, worked on a OnePlus 8 that had a lock.
      final gate = _code(
        File('lib/features/disguise/cover_gate.dart').readAsStringSync(),
      );

      expect(gate.contains('AppLock.hasPin()'), isTrue,
          reason: 'the gate must know whether a PIN exists before refusing',);
      expect(gate.contains('AppLock.availableBiometrics()'), isTrue,
          reason: 'the gate must know whether any biometric is enrolled',);
      expect(gate.contains('LockScreen'), isTrue,
          reason: 'the PIN fallback belongs to LockScreen, which already '
              'prompts biometrics, retries, and drops to the pad — the gate '
              'must not re-implement a worse half of it',);
      expect(RegExp(r'await AppLock\.authenticate\(\)').hasMatch(gate), isFalse,
          reason: "authenticate()'s bool is not a verdict; only LockScreen "
              'may call it, because it retries and drops to the pad',);
      // Asserted on the file that USES it — cover_gate.dart is where it is
      // declared, so looking for it there can never fail.
      final layer = _code(
        File('lib/features/disguise/entry/entry_trigger_layer.dart')
            .readAsStringSync(),
      );
      expect(layer.contains('kCoverRecoveryHold'), isTrue,
          reason: 'the layer must time the backup hold by the shared '
              'constant, not by a number of its own',);
      expect(kCoverRecoveryHold, const Duration(seconds: 10),
          reason: 'raised from 5s on 2026-09-03 when the gesture stopped being '
              'disclosed; the guide and the Play Console notes quote ten',);
      expect(kBackupSlop, 4.0 * kCoverRecoveryHoldSeconds,
          reason: 'the drift tolerance is derived from the duration, never a '
              'standalone number: a finger drifts further the longer it '
              'rests, so a slop tuned for 5s makes a 10s hold impossible',);
      expect(gate.contains('nameless: forced'), isTrue,
          reason: 'the backup door lands on a lock screen that names no app',);
    });
  });
}
