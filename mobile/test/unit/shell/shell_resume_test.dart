import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/shell/app_shell.dart';

/// Coming back to the app is not one event, and treating it as one is what put
/// people back inside Touch after a night away while the socket that fed it was
/// dead. These pin the two halves of the answer: how long away makes the screen
/// you left the wrong screen, and what is happening that means you must not be
/// moved off it anyway.
String _read(String p) => File(p).readAsStringSync();

String _codeOnly(String s) => s
    .split('\n')
    .where((l) =>
        !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'),)
    .join('\n');

void main() {
  final shell = _read('lib/features/shell/app_shell.dart');
  final bar = _read('lib/features/chat/widgets/chat_input_bar.dart');

  group('a short absence keeps the screen the user was on', () {
    test('a cover flip, a shade peek, a glance at another app change nothing',
        () {
      for (final away in [
        Duration.zero,
        const Duration(seconds: 3),
        const Duration(seconds: 45),
        const Duration(minutes: 2),
        const Duration(minutes: 10),
      ]) {
        expect(landsHome(away: away, overlayActive: false), isFalse,
            reason: 'away for $away pulled the user off their screen; the '
                'common path has to stay exactly where it was',);
      }
    });

    test('the boundary belongs to the shorter side', () {
      expect(
        landsHome(
            away: kLongAbsence - const Duration(seconds: 1),
            overlayActive: false,),
        isFalse,
      );
      expect(landsHome(away: kLongAbsence, overlayActive: false), isTrue);
    });

    test('the threshold is long enough to survive a reply gap', () {
      // The product IS the conversation. A couple trading messages across a
      // working day leaves the app sitting backgrounded for minutes at a
      // time, and coming back to Home instead of the thread they are mid-way
      // through would read as the app losing their place.
      expect(kLongAbsence, greaterThanOrEqualTo(const Duration(minutes: 15)));
      expect(kLongAbsence, lessThanOrEqualTo(const Duration(minutes: 30)));
    });
  });

  group('a long absence lands on Home', () {
    test('an hour away, a night away', () {
      expect(landsHome(away: const Duration(hours: 1), overlayActive: false),
          isTrue,);
      expect(landsHome(away: const Duration(hours: 9), overlayActive: false),
          isTrue,);
    });

    test('but a picker, a lock or a permission dialog is not an absence', () {
      // The whole trap. The photo picker reports the app as paused, and the
      // app-lock's own biometric prompt does too. Landing Home on those means
      // choosing a photo dumps the user out of the chat they were sending it
      // to - a bug they can hit fifty times a day.
      expect(landsHome(away: const Duration(hours: 2), overlayActive: true),
          isFalse,);
      expect(landsHome(away: const Duration(minutes: 40), overlayActive: true),
          isFalse,);
    });
  });

  group('an action in progress is never interrupted', () {
    bool busy({
      bool callLive = false,
      bool onChatTab = false,
      bool recording = false,
      bool draftPending = false,
      bool sending = false,
    }) =>
        resumeIsBusy(
          callLive: callLive,
          onChatTab: onChatTab,
          recording: recording,
          draftPending: draftPending,
          sending: sending,
        );

    test('a live call holds the app still wherever the user is standing', () {
      // A PiP call reports the app backgrounded for its whole length, so a
      // twenty-minute call is a twenty-minute "absence" that never happened.
      // The return-to-call window is drawn over the shell as well, so moving
      // the tab under it is both visible and pointless.
      expect(busy(callLive: true), isTrue);
      expect(busy(callLive: true, onChatTab: true), isTrue);
    });

    test('a recording in the chat is not abandoned', () {
      // The recorder belongs to the input bar's State, and a tab change
      // disposes it - so this is the one guard where losing the race loses
      // the recording itself, not just the user's place.
      expect(busy(onChatTab: true, recording: true), isTrue);
    });

    test('a send still moving, and a composer with something in it', () {
      expect(busy(onChatTab: true, sending: true), isTrue);
      expect(busy(onChatTab: true, draftPending: true), isTrue);
    });

    test('nothing in progress does not hold the app anywhere', () {
      expect(busy(), isFalse);
      expect(busy(onChatTab: true), isFalse);
    });

    test("another tab's leftovers do not pin the user to a screen", () {
      // A draft typed yesterday and a send that failed overnight both outlive
      // the chat screen on purpose. Reading them as "in progress" from the
      // Touch tab would mean this user never gets a fresh Home again.
      expect(busy(recording: true), isFalse);
      expect(busy(draftPending: true), isFalse);
      expect(busy(sending: true), isFalse);
    });
  });

  group('the decision is wired to the two shapes a return arrives in', () {
    final code = _codeOnly(shell);

    test('the absence clock outlives the shell that started it', () {
      // raiseCover() swaps the whole router for the disguise on every real
      // background, so the state that saw the app leave is gone by the time it
      // comes back. As an instance field this timed pickers and nothing else.
      expect(code, contains('static DateTime? _leftForegroundAt;'),
          reason: 'the clock went back to being per-instance, so a real '
              'absence is invisible again and the doze reconnect under it '
              'stops running',);
    });

    test('a return is answered on resume AND on mount', () {
      expect(code, contains('_returned(fromMount: false)'));
      expect(code, contains('_returned(fromMount: true)'));
      // Mount-side, before the first build: deciding after it paints the old
      // tab for a frame and then swaps, which is the jump being removed.
      final init = code.substring(code.indexOf('void initState()'));
      final body = init.substring(0, init.indexOf('\n  }'));
      expect(body.indexOf('_returned(fromMount: true)'),
          lessThan(body.indexOf('addPostFrameCallback')),
          reason: 'the tab is corrected after the first frame is scheduled, '
              'so the user sees the screen they left flash past',);
    });

    test('the overlay question is asked on the way OUT, not on the way back',
        () {
      // MilesApp clears systemOverlayActive on every resume, and its observer
      // is registered before the shell's — so a guard that reads the flag on
      // return always reads false, and picking a photo for twenty minutes
      // dumps the user on Home. Latched at departure, it answers what it is
      // for.
      final leave = code.substring(code.indexOf('if (state != AppLifecycleState.resumed) {'));
      expect(leave.substring(0, leave.indexOf('return;')),
          contains('_leftViaOverlay ='),
          reason: 'the overlay state is no longer captured when the app '
              'leaves, so by the time it is read it has been wiped',);
      final ret = code.substring(code.indexOf('void _returned('));
      final body = ret.substring(0, ret.indexOf('\n  }'));
      expect(body, contains('landsHome(away: away, overlayActive: viaOverlay)'));
      expect(body, isNot(contains('MilesApp.systemOverlayActive')),
          reason: 'the resume path went back to reading the live flag, which '
              'main.dart has already cleared by then',);
    });

    test('the doze reconnect still runs on its own threshold', () {
      // It predates this and is the reason the socket recovers at all. Folding
      // it into the go-home decision would silently stop reconnecting for
      // every absence shorter than kLongAbsence.
      expect(code, contains('if (away >= _dozeRisk) _reconnectRealtime();'));
    });

    test("Home is the literal 'home', never a computed value", () {
      // The provider stores room identity now (an index meant different rooms
      // for different accounts — the reason the model changed). The invariant
      // this pins is unchanged: landing home must be the same literal for
      // everyone, never something computed from flags.
      final land = code.substring(code.indexOf('void _landHome('));
      expect(land.substring(0, land.indexOf('\n  }')),
          contains("state = 'home';"),);
    });

    test('presence is not announced from underneath a pushed route', () {
      // The observer is the single publisher and its dedupe latches: saying
      // 'Home' while the user is actually in the vault sticks past the pop.
      final land = code.substring(code.indexOf('void _landHome('));
      final body = land.substring(0, land.indexOf('\n  }'));
      expect(body, contains("uri.path == '/app'"));
      expect(body, isNot(contains('Navigator')),
          reason: 'a pushed route was popped; the call screen, the vault and '
              'an awaited camera result all break when they are popped from '
              'under the user',);
    });

    test('the busy guard reads live state rather than a stale copy', () {
      final g = code.substring(code.indexOf('bool get _resumeIsBusy'));
      final body = g.substring(0, g.indexOf('\n  }'));
      expect(body, contains('PipMode.active.value'));
      expect(body, contains('callControllerProvider'));
      expect(body, contains('ChatInputBar.recording.value'));
      expect(body, contains('ChatDraftStore.peek'));
      expect(body, contains('SendStatus.sending'),
          reason: 'a failed send counted as in-progress would pin the user to '
              'the Chat tab for the life of the install',);
    });
  });

  group('the recording flag cannot get stuck raised', () {
    final code = _codeOnly(bar);

    test('it is on the widget, where the shell can reach it', () {
      final widget = code.substring(
          code.indexOf('class ChatInputBar extends StatefulWidget'),
          code.indexOf('class _ChatInputBarState'),);
      expect(widget, contains('static final ValueNotifier<bool> recording'));
    });

    test('it is lowered on stop and on dispose', () {
      // dispose is the one that matters: _stopRecording is a setState and
      // cannot run from there, so a bar torn down mid-hold would leave the
      // flag raised and this user would never be moved Home again.
      final d = code.substring(code.indexOf('void dispose()'));
      expect(d.substring(0, d.indexOf('\n  }')),
          contains('ChatInputBar.recording.value = false;'),);
      final stop = code.substring(code.indexOf('Future<void> _stopRecording('));
      expect(stop.substring(0, stop.indexOf('\n  }')),
          contains('ChatInputBar.recording.value = false;'),);
    });
  });
}
