import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/features/chat/chat_reactions.dart';
import 'package:miles/features/chat/widgets/reaction_bar.dart';
import 'package:miles/features/chat/widgets/reaction_chips.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Emoji reactions, and the four properties the feature is actually about:
/// it paints before the network, tapping the same emoji takes it back, the
/// partner's reaction arrives over the broadcast wire, and the bar cannot open
/// off the edge of the screen.
///
/// The reaction rules live in [ChatReactionStore] rather than inside
/// ChatScreen for the reason ChatSelection does: nothing here could be driven
/// through a 2800-line ConsumerStatefulWidget that needs a live Supabase
/// client, and a version of it that painted nothing at all would still pass the
/// suite.
///
/// Coverage limit, stated rather than implied: the crypto group injects a
/// 32-byte key past the platform keystore, so the seal→open round trip is real
/// but the DERIVE chain (keystore seed → X25519 → HKDF) stays device-only —
/// the same limit message_seal_test documents. The RLS behaviour is a database
/// property and is proven against staging and production, not here; what this
/// file pins is the migration that carries it (see reaction_rls_test.dart).
void main() {
  const me = 'user-me';
  const partner = 'user-partner';
  final t0 = DateTime(2026, 8, 19, 12);

  group('optimistic paint', () {
    test('a tap is on screen with no key, no network and nothing awaited', () {
      final store = ChatReactionStore();
      // Deliberately NOT an async test. If painting a reaction needed a round
      // trip — or even a seal — this test could not be written at all, which is
      // the whole property: on a dead connection the user still sees it happen.
      expect(store.apply('m1', me, '❤️', t0), isTrue);
      expect(store.emojiOf('m1', me), '❤️');
      expect(store.messagesWithReactions, 1);
    });

    test('the screen paints before its first await', () {
      // The store cannot enforce the ORDER the screen calls it in, and the
      // order is the feature. Pinned against the source, the way this repo
      // already pins the multi-select contract.
      final src = File('lib/features/chat/chat_screen.dart').readAsStringSync();
      final start = src.indexOf('Future<void> _react(Message m, String emoji)');
      expect(start, isNot(-1), reason: '_react was renamed — repoint this');
      // Comments stripped first: that file explains itself at length, and a
      // sentence about awaiting is not an await.
      final body = _code(src.substring(start, src.indexOf('\n  }', start)));
      final paint = body.indexOf('_reactions.apply(');
      final firstAwait = body.indexOf('await ');
      expect(paint, isNot(-1));
      expect(firstAwait, isNot(-1));
      expect(paint, lessThan(firstAwait),
          reason: 'the reaction must be painted before anything is awaited',);
    });

    test('a message with no server row is never offered the bar', () {
      // A reaction points at messages.id with a foreign key. Offering it on a
      // message still uploading buys a 23503 the outbox would have to throw
      // away, and on one already deleted for everyone there is nothing left to
      // react to.
      final src = File('lib/features/chat/chat_screen.dart').readAsStringSync();
      final start = src.indexOf('Future<void> _openReactionBar(');
      expect(start, isNot(-1));
      final body = _code(src.substring(start, src.indexOf('\n  }', start)));
      expect(body, contains('ChatSelection.canSelect(m)'));
    });
  });

  group('toggle', () {
    test('tapping the emoji you already left takes it back', () {
      final store = ChatReactionStore()..apply('m1', me, '👍', t0);
      expect(store.tap('m1', me, '👍'), isNull, reason: 'same emoji = removal');
      expect(store.apply('m1', me, null, t0.add(const Duration(seconds: 1))),
          isTrue,);
      expect(store.emojiOf('m1', me), isNull);
      expect(store.forMessage('m1'), isNull,
          reason: 'the last reaction leaving takes the whole entry with it, so '
              'an empty map can never draw an empty chip row',);
    });

    test('tapping a different emoji replaces, never adds a second', () {
      final store = ChatReactionStore()..apply('m1', me, '👍', t0);
      expect(store.tap('m1', me, '❤️'), '❤️');
      store.apply('m1', me, '❤️', t0.add(const Duration(seconds: 1)));
      expect(store.forMessage('m1')!.length, 1);
      expect(store.emojiOf('m1', me), '❤️');
    });

    test('an echo of what is already shown reports no change', () {
      // The caller skips its setState on false. Without this the postgres echo
      // of our own broadcast repaints the whole conversation for nothing.
      final store = ChatReactionStore()..apply('m1', me, '❤️', t0);
      expect(store.apply('m1', me, '❤️', t0.add(const Duration(seconds: 5))),
          isFalse,);
    });

    test('removing what was never there reports no change', () {
      expect(ChatReactionStore().apply('m1', me, null, t0), isFalse);
    });
  });

  group('two wires, out of order', () {
    test('a stale add cannot resurrect a reaction that was taken back', () {
      // The failure this exists for: the removal deletes the entry, so without
      // a clock that outlives it there is no timestamp left to reject the
      // slower ADD that was already in flight — and the reaction comes back on
      // its own, seconds after the user removed it.
      final store = ChatReactionStore()
        ..apply('m1', partner, '😂', t0)
        ..apply('m1', partner, null, t0.add(const Duration(seconds: 2)));
      expect(
        store.apply('m1', partner, '😂', t0.add(const Duration(seconds: 1))),
        isFalse,
      );
      expect(store.emojiOf('m1', partner), isNull);
    });

    test('a stale removal cannot undo a newer add', () {
      final store = ChatReactionStore()
        ..apply('m1', partner, '😂', t0.add(const Duration(seconds: 3)));
      expect(store.apply('m1', partner, null, t0), isFalse);
      expect(store.emojiOf('m1', partner), '😂');
    });

    test('the clock is per person, so one partner cannot block the other', () {
      final store = ChatReactionStore()
        ..apply('m1', partner, '😂', t0.add(const Duration(seconds: 5)));
      expect(store.apply('m1', me, '❤️', t0), isTrue);
      expect(store.forMessage('m1')!.length, 2);
    });
  });

  group('the partner reacting, over broadcast', () {
    setUp(() {
      ErrorReporter.insertRow = (_) async {};
      CryptoCore.setSharedKeyForTest(
        List<int>.generate(32, (i) => (i * 7 + 5) % 256),
      );
    });
    tearDown(CryptoCore.clearCache);

    test('sealed by the sender, opened and shown by the receiver', () async {
      // The whole live path in one test: the sending device seals and builds
      // the payload, and the receiving device parses it, opens it and paints
      // it — with no database anywhere in between.
      final sealed = await ChatReactionRepository.seal(
        emoji: '😮',
        messageId: 'm1',
        userId: partner,
        at: t0,
      );
      expect(sealed, isNotNull);
      final payload = ChatReactionRepository.broadcastPayload(
        from: partner,
        messageId: 'm1',
        at: t0,
        sealed: sealed,
      );
      // Nothing readable crosses the wire.
      expect(jsonEncode(payload).contains('😮'), isFalse);

      final incoming = ChatReactionRepository.fromBroadcast(payload);
      expect(incoming, isNotNull);
      final store = ChatReactionStore();
      expect(await store.applyIncoming(incoming!, myUid: me), isTrue);
      expect(store.emojiOf('m1', partner), '😮');
    });

    test('a payload with no ciphertext IS the removal', () async {
      final payload = ChatReactionRepository.broadcastPayload(
        from: partner,
        messageId: 'm1',
        at: t0.add(const Duration(seconds: 1)),
      );
      expect(payload.containsKey('cipher'), isFalse);
      final store = ChatReactionStore()..apply('m1', partner, '😮', t0);
      final incoming = ChatReactionRepository.fromBroadcast(payload)!;
      expect(incoming.isRemoval, isTrue);
      expect(await store.applyIncoming(incoming, myUid: me), isTrue);
      expect(store.emojiOf('m1', partner), isNull);
    });

    test('our own echo is ignored', () async {
      // Our copy is already painted and may already have been changed again,
      // so the one that comes back off the wire is always the older answer.
      final sealed = await ChatReactionRepository.seal(
        emoji: '❤️', messageId: 'm1', userId: me, at: t0,);
      final incoming = ChatReactionRepository.fromBroadcast(
        ChatReactionRepository.broadcastPayload(
            from: me, messageId: 'm1', at: t0, sealed: sealed,),
      )!;
      final store = ChatReactionStore();
      expect(await store.applyIncoming(incoming, myUid: me), isFalse);
      expect(store.messagesWithReactions, 0);
    });

    test('a malformed payload is nothing to apply, not a crash', () {
      for (final bad in <Map<String, dynamic>>[
        {},
        {'from': partner},
        {'from': partner, 'messageId': 'm1'},
        {'from': partner, 'messageId': 'm1', 'at': 'not-a-date'},
      ]) {
        expect(ChatReactionRepository.fromBroadcast(bad), isNull);
      }
    });

    test('a blob cannot be replayed onto another message or another person',
        () async {
      final sealed = await ChatReactionRepository.seal(
        emoji: '🙏', messageId: 'm1', userId: partner, at: t0,);
      // Same bytes, wrong binding: the associated data covers both ids, so
      // neither swap opens.
      expect(
        await ChatReactionRepository.open(
          cipher: sealed!.cipher,
          nonce: sealed.nonce,
          messageId: 'm2',
          userId: partner,
        ),
        isNull,
      );
      expect(
        await ChatReactionRepository.open(
          cipher: sealed.cipher,
          nonce: sealed.nonce,
          messageId: 'm1',
          userId: me,
        ),
        isNull,
      );
    });

    test('every emoji seals to the same number of bytes', () async {
      // XChaCha20 is a stream cipher and nothing on this path pads, so an
      // unpadded column is 16 + the emoji's UTF-8 length. Against a closed
      // palette this app itself publishes, that IS the value: ❤️ is six bytes
      // where the other five on the bar are four, so it sat alone in its own
      // bucket and `octet_length(emoji_cipher)` named it.
      final lengths = <int>{};
      for (final emoji in [...ChatReactionRepository.quick, ...kReactionPalette]) {
        final sealed = await ChatReactionRepository.seal(
            emoji: emoji, messageId: 'm1', userId: partner, at: t0,);
        expect(sealed, isNotNull, reason: emoji);
        lengths.add(sealed!.cipher.length);
        expect(sealed.nonce.length, 24);
        // And it still opens back to exactly what went in.
        expect(
          await ChatReactionRepository.open(
            cipher: sealed.cipher,
            nonce: sealed.nonce,
            messageId: 'm1',
            userId: partner,
          ),
          emoji,
        );
      }
      expect(lengths.length, 1,
          reason: 'the whole palette must be indistinguishable by length, '
              'not merely most of it: $lengths',);
    });

    test('the associated data binds the message AND the person', () {
      expect(ChatReactionRepository.reactionAd('m1', me), 'm1:$me');
      expect(ChatReactionRepository.reactionAd('m1', me),
          isNot(ChatReactionRepository.reactionAd('m1', partner)),);
      expect(ChatReactionRepository.reactionAd('m1', me),
          isNot(ChatReactionRepository.reactionAd('m2', me)),);
    });
  });

  group('with no couple key', () {
    setUp(CryptoCore.clearCache);

    test('sealing answers null rather than throwing or writing cleartext',
        () async {
      // The ordinary state of a cold start and of any couple mid key-exchange.
      // The caller takes its paint back and says so; it never falls back to
      // storing the emoji in the clear.
      expect(
        await ChatReactionRepository.seal(
            emoji: '❤️', messageId: 'm1', userId: me, at: t0,),
        isNull,
      );
    });

    test('opening answers null rather than throwing', () async {
      expect(
        await ChatReactionRepository.open(
          cipher: Uint8List.fromList(List.generate(48, (i) => i + 1)),
          nonce: Uint8List.fromList(List.generate(24, (i) => i + 100)),
          messageId: 'm1',
          userId: partner,
        ),
        isNull,
      );
    });
  });

  group('the bytea wire', () {
    test('what is written is what comes back', () {
      // The column is bytea and the hop is PostgREST — the same hop
      // messages.body_cipher already makes in production. Both encodings that
      // shipped here before were wrong in a way nothing failed on: a raw list
      // JSON-encodes as an int array, and a base64 string stores as its own
      // ASCII. Neither round-tripped.
      final bytes = Uint8List.fromList([0, 1, 15, 16, 127, 128, 254, 255]);
      final wire = bytesToBytea(bytes);
      expect(wire.startsWith(r'\x'), isTrue);
      expect(wire, r'\x00010f107f80feff');
      expect(byteaToBytes(wire), bytes);
    });
  });

  group('chips', () {
    test('two people, two emoji, in the order they reacted', () {
      final chips = tallyReactions({
        partner: ChatReaction(emoji: '😂', at: t0.add(const Duration(minutes: 1))),
        me: ChatReaction(emoji: '❤️', at: t0),
      }, me,);
      expect(chips.map((c) => c.emoji), ['❤️', '😂']);
      expect(chips.first.mine, isTrue);
      expect(chips.last.mine, isFalse);
      expect(chips.every((c) => c.count == 1), isTrue);
    });

    test('the same emoji from both merges into one chip with a count', () {
      // Two identical chips side by side read as a rendering bug.
      final chips = tallyReactions({
        me: ChatReaction(emoji: '❤️', at: t0),
        partner: ChatReaction(emoji: '❤️', at: t0.add(const Duration(minutes: 1))),
      }, me,);
      expect(chips.length, 1);
      expect(chips.single.count, 2);
      expect(chips.single.mine, isTrue);
    });

    test('nobody reacted draws nothing', () {
      expect(tallyReactions(const {}, me), isEmpty);
    });
  });

  group('the bar near an edge', () {
    final bar = reactionBarSize();
    const screen = Size(360, 800);
    const insets = EdgeInsets.only(top: 28, bottom: 48);

    bool onScreen(Offset at) =>
        at.dx >= 0 &&
        at.dy >= insets.top &&
        at.dx + bar.width <= screen.width &&
        at.dy + bar.height <= screen.height - insets.bottom;

    test('the FIRST message opens the bar below itself, not off the top', () {
      // Above is the default because that is where a thumb is not. The oldest
      // message on screen is the one case with no room there.
      final at = reactionBarOffset(
        anchor: const Rect.fromLTWH(16, 30, 200, 60),
        screen: screen,
        insets: insets,
        bar: bar,
        mine: false,
      );
      expect(at.dy, greaterThan(30));
      expect(onScreen(at), isTrue);
    });

    test('the LAST message cannot push the bar under the input bar', () {
      final at = reactionBarOffset(
        anchor: const Rect.fromLTWH(16, 700, 200, 60),
        screen: screen,
        insets: insets,
        bar: bar,
        mine: true,
      );
      expect(onScreen(at), isTrue);
    });

    test('a bubble hard against either edge still opens a whole bar', () {
      for (final anchor in <Rect>[
        const Rect.fromLTWH(0, 400, 60, 40),
        const Rect.fromLTWH(300, 400, 60, 40),
      ]) {
        for (final mine in [true, false]) {
          final at = reactionBarOffset(
            anchor: anchor,
            screen: screen,
            insets: insets,
            bar: bar,
            mine: mine,
          );
          expect(onScreen(at), isTrue, reason: '$anchor mine=$mine -> $at');
        }
      }
    });

    test('a screen narrower than the bar clamps instead of throwing', () {
      // clamp() throws when the lower bound passes the upper one, and a
      // 280dp-wide window is a real Android state (split screen).
      final at = reactionBarOffset(
        anchor: const Rect.fromLTWH(0, 100, 200, 40),
        screen: const Size(240, 500),
        insets: EdgeInsets.zero,
        bar: bar,
        mine: false,
      );
      expect(at.dx, greaterThanOrEqualTo(0));
    });
  });

  group('the bar on screen', () {
    Future<String?> openBar(WidgetTester tester) async {
      String? answer;
      var opened = false;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  opened = true;
                  answer = await ReactionBar.show(
                    context,
                    anchor: const Rect.fromLTWH(20, 300, 200, 60),
                    mine: false,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(opened, isTrue);
      return answer;
    }

    testWidgets('shows the six and the "+", and answers the one tapped',
        (tester) async {
      await openBar(tester);
      for (final emoji in ChatReactionRepository.quick) {
        expect(find.text(emoji), findsOneWidget);
      }
      expect(find.byIcon(Icons.add), findsOneWidget);
      await tester.tap(find.text('❤️'));
      await tester.pumpAndSettle();
      // The bar is gone and the choice came back through the future the
      // caller is awaiting.
      expect(find.text('😂'), findsNothing);
    });

    testWidgets('a tap outside dismisses it', (tester) async {
      await openBar(tester);
      expect(find.text('🙏'), findsOneWidget);
      // The barrier is transparent, so "outside" is a real place on the
      // screen and has to be hittable. Well inside the 800x600 test window,
      // and well clear of the bar at (20,238)-(324,292).
      await tester.tapAt(const Offset(400, 520));
      await tester.pumpAndSettle();
      expect(find.text('🙏'), findsNothing);
    });

    testWidgets('back dismisses it', (tester) async {
      await openBar(tester);
      expect(find.text('🙏'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('🙏'), findsNothing);
    });
  });

  group('the chips on screen', () {
    testWidgets('tapping a chip toggles that emoji', (tester) async {
      final tapped = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ReactionChips(
            byUser: {
              me: ChatReaction(emoji: '❤️', at: t0),
              partner: ChatReaction(emoji: '😂', at: t0.add(const Duration(minutes: 1))),
            },
            myUid: me,
            mine: false,
            onTap: tapped.add,
          ),
        ),
      ),);
      await tester.pumpAndSettle();
      await tester.tap(find.text('❤️'));
      await tester.tap(find.text('😂'));
      expect(tapped, ['❤️', '😂']);
    });

    testWidgets('a chip that did not change does not pop when a sibling goes',
        (tester) async {
      // The entrance is keyed to the emoji, and the key has to sit on the Row's
      // DIRECT child: one level down, reconciliation matches the unkeyed
      // Paddings slot for slot first, hands the survivor the departed chip's
      // element, then finds the keys differ and remounts it. The chip nobody
      // touched popped every time the other one was taken back.
      double scaleOf(String emoji) => tester
          .widget<Transform>(find.descendant(
            of: find.byKey(ValueKey(emoji)),
            matching: find.byType(Transform),
          ),)
          .transform
          .storage[0];

      Widget chips(Map<String, ChatReaction> byUser) => MaterialApp(
            home: Scaffold(
              body: ReactionChips(
                byUser: byUser,
                myUid: me,
                mine: false,
                onTap: _ignore,
              ),
            ),
          );

      final long = DateTime.now().subtract(const Duration(minutes: 5));
      await tester.pumpWidget(chips({
        partner: ChatReaction(emoji: '😂', at: long),
        me: ChatReaction(emoji: '❤️', at: long.add(const Duration(seconds: 1))),
      }),);
      await tester.pumpAndSettle();
      // The partner takes theirs back; ❤️ is untouched and must not move.
      await tester.pumpWidget(chips({
        me: ChatReaction(emoji: '❤️', at: long.add(const Duration(seconds: 1))),
      }),);
      await tester.pump();
      expect(scaleOf('❤️'), 1.0);
    });

    testWidgets('an old reaction scrolled back into view does not pop',
        (tester) async {
      // A reversed ListView.builder collects rows 250px outside the viewport
      // and re-inflates them on return, so mounting is not the same event as
      // arriving.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ReactionChips(
            byUser: {
              partner: ChatReaction(
                emoji: '👍',
                at: DateTime.now().subtract(const Duration(days: 3)),
              ),
            },
            myUid: me,
            mine: false,
            onTap: _ignore,
          ),
        ),
      ),);
      await tester.pump();
      expect(
        tester
            .widget<Transform>(find.descendant(
              of: find.byKey(const ValueKey('👍')),
              matching: find.byType(Transform),
            ),)
            .transform
            .storage[0],
        1.0,
      );
    });

    testWidgets('nobody reacted takes no vertical space', (tester) async {
      // The bubble must not gain a gap it will never fill: every message in a
      // conversation renders this, and most of them have no reactions.
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ReactionChips(
            byUser: {},
            myUid: me,
            mine: true,
            onTap: _ignore,
          ),
        ),
      ),);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(ReactionChips)).height, 0);
    });
  });

  group('the outbox', () {
    // The outbox persists through SharedPreferences; without the mock the
    // real plugin channel is hit and both restore and persist log a
    // MissingPluginException they then swallow.
    setUp(() => SharedPreferences.setMockInitialValues({}));
    tearDown(ChatReactionOutbox.instance.endSession);

    test('a refusal retrying cannot fix is not retried forever', () {
      // 42501 is RLS saying no, 23503 is the message being gone. A queue that
      // retried these would spin until the app is uninstalled.
      for (final code in ['42501', '23503', '22P02', '400', '403']) {
        expect(
          ChatReactionOutbox.permanent(
            PostgrestException(message: 'no', code: code),
          ),
          isTrue,
          reason: code,
        );
      }
    });

    test('everything that could still land stays in the queue', () {
      for (final code in ['500', '502', '503', '408', '429', null]) {
        expect(
          ChatReactionOutbox.permanent(
            PostgrestException(message: 'later', code: code),
          ),
          isFalse,
          reason: '$code',
        );
      }
      // No network at all is the ordinary offline case.
      expect(ChatReactionOutbox.permanent(const SocketException('offline')),
          isFalse,);
    });

    test('what reaches the disk is ciphertext and ids, never the emoji', () {
      // The same line ChatSendQueue holds for message bodies: this app does not
      // write down what people said in a form anything else can read.
      final intent = ReactionIntent(
        messageId: 'm1',
        coupleId: 'c1',
        userId: me,
        at: t0,
        cipherB64: base64Encode([1, 2, 3]),
        nonceB64: base64Encode([4, 5, 6]),
        emoji: '❤️',
      );
      final encoded = jsonEncode(intent.toJson());
      expect(encoded.contains('❤️'), isFalse);
      expect(ReactionIntent.fromJson(jsonDecode(encoded) as Map<String, dynamic>)
          .emoji, isNull,
          reason: 'the plaintext is recovered by decrypting, not by reading it '
              'back off the disk',);
    });

    test('a later decision is not overwritten by an earlier one', () async {
      // Sealing waits on the couple-key derive; a REMOVAL has nothing to seal
      // and no await at all, so the user's "take it back" can be queued before
      // the earlier add finishes sealing. Arrival order is not decision order.
      final box = ChatReactionOutbox.instance;
      await box.bindUser(me);
      await box.enqueue(
          coupleId: 'c1', messageId: 'm1', userId: me, sealed: null,
          at: t0.add(const Duration(seconds: 2)),);
      await box.enqueue(
          coupleId: 'c1', messageId: 'm1', userId: me,
          sealed: SealedReaction(
            emoji: '❤️',
            cipher: Uint8List.fromList([1, 2, 3]),
            nonce: Uint8List.fromList([4, 5, 6]),
            at: t0,
          ),
          at: t0,);
      expect(box.pending['m1']?.isRemoval, isTrue,
          reason: 'the stale add would put the reaction back on both phones',);
    });

    test('a removal is an intent with no ciphertext at all', () {
      final removal = ReactionIntent(
        messageId: 'm1', coupleId: 'c1', userId: me, at: t0,);
      expect(removal.isRemoval, isTrue);
      expect(jsonEncode(removal.toJson()).contains('"x"'), isFalse);
    });
  });

  group('the fetched page never outranks what is already known', () {
    test('a page lands when nothing has happened since it was asked for', () {
      final store = ChatReactionStore();
      final asOf = store.writes;
      store.mergeFetched({
        'm1': {partner: ChatReaction(emoji: '😂', at: t0)},
      }, asOfWrites: asOf,);
      expect(store.emojiOf('m1', partner), '😂');
    });

    test('a reaction that landed DURING the fetch survives it', () {
      // The window is not theoretical: both live wires are joined while the
      // SELECT is in flight, and on a cold open the decrypt inside it waits on
      // the couple-key derive. A blind overwrite here erased the partner's
      // live reaction and this device's own just-landed tap.
      final store = ChatReactionStore();
      final asOf = store.writes;
      // ... the partner reacts while the SELECT is still out ...
      store
        ..apply('m1', partner, '🙏', t0.add(const Duration(minutes: 5)))
        // ... and the page, a snapshot from before that, comes back.
        ..mergeFetched({
          'm1': {partner: ChatReaction(emoji: '😂', at: t0)},
        }, asOfWrites: asOf,);
      expect(store.emojiOf('m1', partner), '🙏');
    });

    test('a reaction the server no longer has is dropped', () {
      // The other half, and why this is a merge and not an append: a removal
      // made while the socket was down reaches the device only as an absence.
      final store = ChatReactionStore()..apply('m1', partner, '😂', t0);
      store.mergeFetched(const {}, asOfWrites: store.writes);
      expect(store.emojiOf('m1', partner), isNull);
      expect(store.messagesWithReactions, 0);
    });

    test('and what it dropped can be learned again at the same instant', () {
      // The prune FORGETS the clock, and that is the whole of it. Keeping the
      // timestamp made every prune permanent: the same write returning on the
      // durable wire carries the pruned instant as its updated_at, and an ADD
      // has to be strictly newer — so a reaction the partner could still see
      // on their phone was gone from this one for the life of the screen.
      final store = ChatReactionStore()
        ..apply('m1', partner, '😂', t0)
        ..mergeFetched(const {}, asOfWrites: 1);
      expect(store.emojiOf('m1', partner), isNull);
      expect(store.apply('m1', partner, '😂', t0), isTrue);
      expect(store.emojiOf('m1', partner), '😂');
    });

    test('an own reaction pruned mid-flight is restored by the overlay', () {
      // _react stamps the paint and the outbox intent with the SAME instant,
      // so a prune that kept the clock made _applyPendingReactions a no-op in
      // exactly the case it exists for: a reaction made offline, pruned by the
      // first page that came back, and never seen again on this device even
      // though the retry landed it.
      final store = ChatReactionStore()
        ..apply('m1', me, '❤️', t0)
        ..mergeFetched(const {}, asOfWrites: 1);
      expect(store.apply('m1', me, '❤️', t0), isTrue,
          reason: 'the overlay re-applies at intent.at, which IS t0',);
    });
  });

  group('a removal that carries no clock', () {
    test('forget drops the value AND the ordering', () {
      // Under RLS a DELETE payload is the primary key and nothing else: no
      // updated_at, and the value the row held was written by the add anyway.
      // An earlier version derived a timestamp one tick past the latest known
      // write, which killed a re-add that had already arrived over the faster
      // wire and then outranked that re-add's own durable INSERT forever.
      final store = ChatReactionStore()
        ..apply('m1', partner, '❤️', t0)
        ..forget('m1', partner);
      expect(store.emojiOf('m1', partner), isNull);
      // Nothing is left to reject what the server says next, at any instant.
      expect(store.apply('m1', partner, '❤️', t0), isTrue);
    });

    test('forget is safe on a key nothing is known about', () {
      final store = ChatReactionStore()..forget('m1', partner);
      expect(store.messagesWithReactions, 0);
      expect(store.apply('m1', partner, '❤️', t0), isTrue);
    });

    test('a removal wins a tie, an add does not', () {
      // A row is stamped by its ADD, so a removal derived from that row carries
      // the same instant — and the two wires deliver them either way round,
      // because the add parks on a decrypt and the removal does not.
      final removal = ChatReactionStore()..apply('m1', partner, '❤️', t0);
      expect(removal.apply('m1', partner, null, t0), isTrue);
      final replay = ChatReactionStore()..apply('m1', partner, '❤️', t0);
      expect(replay.apply('m1', partner, '😂', t0), isFalse);
    });
  });

  group('the screen wires the fixes it cannot hold itself', () {
    late final chat =
        _code(File('lib/features/chat/chat_screen.dart').readAsStringSync());

    String body(String signature) {
      final at = chat.indexOf(signature);
      expect(at, isNot(-1), reason: '$signature was renamed — repoint this');
      return chat.substring(at, chat.indexOf('\n  }', at));
    }

    test('dismissing the bar leaves the selection alone', () {
      // The bar is a full-screen modal: its barrier swallows the tap that
      // would add a second message. Clearing on dismiss therefore made bulk
      // delete unreachable, because long press is the only way in.
      final b = body('Future<void> _openReactionBar(');
      final dismiss = b.indexOf('if (choice == null) return;');
      final clear = b.indexOf('_clearSelection();');
      expect(dismiss, isNot(-1),
          reason: 'a dismiss must return before touching the selection',);
      expect(dismiss, lessThan(clear));
    });

    test('a rejoin re-reads the reactions it missed, after the gap merges', () {
      // Both reaction wires are live-only: the broadcast is at-most-once and a
      // rejoined postgres_changes channel replays nothing. It has to run AFTER
      // fetchSince — the id list comes from _messages — and OUTSIDE the try,
      // because the commonest case of all is a partner who reacted without
      // sending anything.
      final b = body('Future<void> _catchUp(');
      final reload = b.indexOf('_loadReactions(couple)');
      expect(reload, isNot(-1));
      expect(reload, greaterThan(b.indexOf('fetchSince')));
      expect(reload, greaterThan(b.indexOf('} catch (e) {')));
    });

    test('a refused write hands the key back to the server', () {
      // Not "roll back to nothing": refuse a CHANGE of mind and the server
      // still holds the previous emoji, which the partner can still see.
      final b = body('void _onReactionOutbox(');
      expect(b, contains('_reactions.forget(intent.messageId, uid)'));
      expect(b, contains('_loadReactions(coupleId)'));
      expect(b.contains('DateTime.now()'), isFalse);
    });

    test('the reaction fetch is single-flight', () {
      // A resume produces two triggers — this screen's lifecycle callback and
      // the shell's forced socket reconnect — and a durable DELETE asks for a
      // third. Each concurrent pass is another chance to snapshot the server
      // mid-write.
      final b = body('Future<void> _loadReactions(');
      expect(b, contains('_reactionFetchBusy'));
      expect(b, contains('_reactionFetchAgain'));
    });

    test('a durable removal is answered by the server, not by a guess', () {
      final b = body('void _onReactionRow(');
      expect(b, contains('_reactions.forget(messageId, userId)'));
      expect(b.contains('applyRemoval'), isFalse);
    });

    test('the bar re-checks the message after its own awaits', () {
      // The partner can delete it for everyone while the bar, or the picker
      // behind it, is up.
      final b = body('Future<void> _openReactionBar(');
      final show = b.indexOf('await ReactionBar.show(');
      final recheck = b.indexOf('ChatSelection.canSelect(live)');
      expect(recheck, isNot(-1));
      expect(show, lessThan(recheck));
    });

    test('an album is compared against the items that could be selected', () {
      // ChatSelection.toggle silently refuses an item still uploading, so a
      // partially-sent album selects fewer rows than it holds.
      final b = body('Future<void> _openReactionBar(');
      expect(b, contains('row.items.where(ChatSelection.canSelect)'));
      expect(b.contains('_selection.length == row.items.length'), isFalse);
    });

    test('the bar does not take focus', () {
      final bar = _code(
          File('lib/features/chat/widgets/reaction_bar.dart').readAsStringSync(),);
      expect(bar, contains('requestFocus: false'),
          reason: 'the default moves focus to the modal scope, closing the '
              'keyboard and sliding the whole conversation ~300dp out from '
              'under a bar that is already pinned',);
    });

    test('signing out ends the outbox', () {
      final session = _code(
          File('lib/core/app/session_provider.dart').readAsStringSync(),);
      expect(session, contains('ChatReactionOutbox.instance.endSession()'),
          reason: 'the backoff timer stays armed for minutes and would retry '
              "under the next account's session",);
    });
  });
}

void _ignore(String _) {}

/// Source with its line comments removed, so a source pin reads what the code
/// does rather than what it says about itself.
String _code(String src) => src
    .split('\n')
    .map((l) {
      final at = l.indexOf('//');
      return at < 0 ? l : l.substring(0, at);
    })
    .join('\n');
