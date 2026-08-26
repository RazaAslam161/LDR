import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cryptography/cryptography.dart'
    show SecretBoxAuthenticationError;
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/partner_key_pin.dart';
import 'package:miles/core/data/partner_rewrap.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/core/services/server_clock.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/glow_button.dart';
import 'package:miles/core/widgets/love_text_field.dart';
import 'package:miles/core/widgets/surface_panel.dart';
import 'package:miles/features/auth/widgets/alert_banner.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:miles/features/closer/memory_threads/memory_failure.dart';
import 'package:miles/features/safety/severance_state.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Both halves of the rewrap ceremony, on one screen.
///
/// Which half you get is not a choice: if the other phone has a live request
/// open, you are the one answering it; otherwise you are the one asking. The
/// two roles never overlap, because a device that still holds the couple key
/// has nothing to ask for.
///
/// There is no copy button on the digits. A code that can be pasted into a
/// message is a code that travels off the voice channel, and the voice channel
/// is the only thing here that authenticates anybody.
class RewrapScreen extends ConsumerStatefulWidget {
  const RewrapScreen({super.key});

  @override
  ConsumerState<RewrapScreen> createState() => _RewrapScreenState();
}

class _RewrapScreenState extends ConsumerState<RewrapScreen> {
  final _typed = TextEditingController();

  /// Their live request. Non-null means this phone is the one answering.
  RewrapRequest? _incoming;

  String? _code;
  String? _requestId;
  DateTime? _expiresAt;

  bool _loading = true;
  bool _asked = false;
  bool _busy = false;

  /// Set only by [_offerReadableOverride], and only for this screen: the human
  /// has looked at their own messages and confirmed this phone can read them.
  bool _readableConfirmed = false;
  bool _claiming = false;
  String? _error;

  /// Consecutive mismatches. The third one stops being a typo and starts being
  /// worth warning about.
  int _wrong = 0;

  Timer? _tick;
  ManagedSubscription? _sub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.dispose();
    _typed.dispose();
    super.dispose();
  }

  /// The couple this ceremony belongs to, live or dissolved.
  ///
  /// A dissolved couple inside its window still has two people who can run the
  /// ceremony — 20260826180000 opened the policies for exactly that — but
  /// profiles.couple_id is null on both sides by then, so the session cannot
  /// name it. SeveranceState can, and the router only lets an unpaired account
  /// reach this screen when it does.
  String? get _coupleId =>
      ref.read(sessionProvider).couple?.id ??
      SeveranceState.held.value?.coupleId;

  /// Which half of the ceremony this is — as soon as there is a couple to ask
  /// about; sign-in routes straight here, so the profile and the couple are
  /// usually still in flight when the first frame lands.
  Future<void> _load() async {
    final coupleId = _coupleId;
    if (_asked || coupleId == null) return;
    _asked = true;

    // This phone may already be mid-ask from before a process death. The hold
    // is the only record of that — pending() filters own requests out — and it
    // carries the code, which exists nowhere else once the screen dies.
    final held = await CryptoCore.heldRequest();
    if (held != null && held.id != 'pending') {
      RewrapRequest? own;
      try {
        own = await PartnerRewrap.fetchOwn(held.id);
      } catch (_) {
        // Offline. The hold stands; show the code from it and let the
        // subscription and the poll catch up when the socket does.
      }
      if (!mounted) return;
      setState(() {
        _requestId = held.id;
        _code = held.code;
        _expiresAt = own?.expiresAt ?? held.until;
        _loading = false;
      });
      _startTicking();
      _subscribe(coupleId);
      // An answer may have landed while this phone was dead. The peer comes off
      // the answered row, so this no longer needs a partner in the session.
      unawaited(_claim());
      return;
    }

    RewrapRequest? req;
    var reached = false;
    try {
      req = await PartnerRewrap.pending(coupleId);
      reached = true;
    } catch (_) {
      // Offline, or the table is unreachable. Fall through to the asking side
      // — it is the half that starts with a button — but WITHOUT latching:
      // a phone that holds the key and hit one bad socket would otherwise be
      // stuck on the asking side for the life of the screen, minting requests
      // against the partner it should be answering.
      _asked = false;
    }
    if (!mounted) return;
    setState(() {
      _incoming = req;
      _expiresAt = req?.expiresAt;
      _loading = false;
    });
    if (reached) _subscribe(coupleId);
    if (req != null) _startTicking();
  }

  /// One subscription, both roles: an asker claims on change, an answerer
  /// refreshes — a retry on the other phone replaces the request, and typing
  /// old digits against a new commitment can only ever mismatch.
  void _subscribe(String coupleId) {
    if (_sub != null) return;
    _sub = ManagedSubscription.start(
      () => RealtimeService.coupleTable(
        channelName: 'rewrap:$coupleId',
        table: 'partner_rewrap_requests',
        coupleId: coupleId,
        onChange: (_) => unawaited(_onRowChange(coupleId)),
      ),
    );
  }

  Future<void> _onRowChange(String coupleId) async {
    if (!mounted || _busy || _claiming) return;
    if (_requestId != null) {
      await _claim();
      return;
    }
    RewrapRequest? req;
    try {
      req = await PartnerRewrap.pending(coupleId);
    } catch (_) {
      return;
    }
    if (!mounted || _busy) return;
    if (req?.id != _incoming?.id) {
      setState(() {
        _incoming = req;
        _expiresAt = req?.expiresAt ?? _expiresAt;
        _typed.clear();
        _wrong = 0;
      });
      if (req != null) _startTicking();
    }
  }

  void _startTicking() {
    _tick?.cancel();
    var beats = 0;
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      // Past the deadline nothing moves again, and a 1 Hz rebuild forever is a
      // battery cost with nothing on the other end of it.
      if (_left.isNegative) t.cancel();
      // The realtime event is the fast path, not the only one: a socket that
      // dropped during the ten minutes used to cost the couple the attempt
      // with no diagnosis. Fifteen seconds is far inside the window and free
      // against a request that is usually answered in one or two of them.
      if (++beats % 15 == 0 && _requestId != null && !_claiming) {
        unawaited(_claim());
      }
      setState(() {});
    });
  }

  /// Server-relative, like every other deadline in the app: the row's ten
  /// minutes are counted by Postgres, and a phone with a skewed clock would
  /// otherwise offer a button whose write the policy has already refused.
  Duration get _left => _expiresAt == null
      ? Duration.zero
      : _expiresAt!.difference(ServerClock.now());

  String get _countdown {
    final left = _left;
    if (left.isNegative) return 'Expired';
    return '${left.inMinutes}:'
        '${(left.inSeconds % 60).toString().padLeft(2, '0')} left';
  }

  /// D: post the request and start watching for the answer.
  Future<void> _openRequest() async {
    final coupleId = _coupleId;
    // The partner used to be checked here too, purely as a still-loading
    // proxy — opening a request never needed one, and while the couple is
    // dissolved there is no partner in the session to find.
    if (coupleId == null) {
      // Sign-in routes straight here, so the profile is often still in flight
      // when the button is first tappable. Returning bare made "Ask them" a
      // button that did nothing, twice, and then worked.
      setState(() => _error = 'Still loading. Try that again in a second.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final (id, code, expiresAt) = await PartnerRewrap.open(coupleId);
      if (!mounted) return;
      setState(() {
        _requestId = id;
        _code = code;
        _expiresAt = expiresAt;
        _busy = false;
      });
      _startTicking();
      _subscribe(coupleId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // The limiter is the one failure with a real answer for the user.
        // (It is abuse control, not the code's strength: the adversary that
        // matters to six digits never inserts a row — its bound is the
        // Argon2id sweep, as the migration says.)
        _error = e is PostgrestException && e.code == 'PT429'
            ? 'Too many attempts. Try again in a minute — and after three, in '
                'an hour.'
            : "That didn't go through. Try again.";
      });
    }
  }

  /// D: try to open whatever the partner has left in the row.
  Future<void> _claim() async {
    final id = _requestId;
    if (id == null || _claiming) return;
    _claiming = true;
    try {
      final result = await PartnerRewrap.claim(id);
      if (result == null || !mounted) return;
      _tick?.cancel();
      // added == 0 is stated, not dressed up: the chain held nothing this
      // phone did not already derive, which is what a key that rotated before
      // the partner sealed it looks like. Printing "your history is back" over
      // that is the one lie this whole feature exists to not tell.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.added == 0
                ? 'Nothing new arrived — this phone already holds every key '
                    'the ceremony carried. If old memories still do not open, '
                    'start again while you are both on the call.'
                : result.dropped > 0
                    ? 'Your history is back. Your earliest memories may not '
                        'open on this phone any more.'
                    : 'Your history is back.',
          ),
        ),
      );
      _leave();
    } on SecretBoxAuthenticationError {
      _abandonCeremony();
    } on ArgumentError {
      // A malformed chain. Same finality as a blob that will not open.
      _abandonCeremony();
    } on StateError catch (e) {
      // Not transient and not fatal: the partner's key is missing or wrong on
      // the server. Retrying silently forever left "Waiting for…" over a
      // condition that will not change on its own — say it, keep the ceremony
      // standing, and let the poll pick up if the condition clears.
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      // Transient. The row is still there, the hold still stands, and the next
      // poll or realtime event retries the whole claim — every step of which
      // is idempotent up to the delete. Tearing the ceremony down here turned
      // any dropped packet on a poll that runs forty times a window into
      // "start again", which walked the user straight into the rate limiter.
    } finally {
      _claiming = false;
    }
  }

  /// The blob was sealed to a key this phone does not hold — the one
  /// unrecoverable answer, and the only thing allowed to reset the screen.
  void _abandonCeremony() {
    if (!mounted) return;
    _tick?.cancel();
    _sub?.dispose();
    _sub = null;
    setState(() {
      _code = null;
      _requestId = null;
      _error = "That didn't finish. Start again.";
    });
  }

  /// Pop when pushed — AppShell awaits that future to reset its offer flag,
  /// and go() would strand the flag true, with no rewrap ever offered again
  /// this process. Go when this screen IS the stack, as it is from sign-in.
  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/app');
    }
  }

  /// P: check the digits, then hand the keys over.
  Future<void> _sendAnswer() async {
    final req = _incoming;
    if (req == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await PartnerRewrap.verifyCode(req, _typed.text.trim())) {
        if (!mounted) return;
        _wrong++;
        _typed.clear();
        setState(() {
          _busy = false;
          // Nothing left the phone for this — the row is untouched, so a
          // mismatch costs the couple nothing and costs an attacker one of
          // three attempts an hour.
          _error = _wrong >= 3
              ? 'If this keeps failing, stop. Someone may be trying to '
                  'intercept this.'
              : "Those digits don't match. Check you're reading from their "
                  'screen, not a message.';
        });
        return;
      }
      // The couple key is derived, not stored, and this is the one thing being
      // handed over. Their new key is normally unpublished here, so this
      // derives the OLD key — which is exactly the one their history needs.
      //
      // "Normally" has one exception: a partner who DEFERRED the ceremony and
      // opened chat or Closer first has already published the NEW key, so the
      // fetch inside ensureSharedKey meets a changed key and the pin refuses.
      // The digits that passed one line above are Argon2id-committed to
      // exactly req's key — a stronger authentication than the pin — so a
      // mismatch naming that same key is repinned and retried, and only a
      // THIRD key is a real alarm worth the generic failure below.
      final session = ref.read(sessionProvider);
      try {
        await ensureSharedKey(session);
      } on PartnerKeyChangedException catch (e) {
        if (e.newKeyB64 != req.newPublicKeyB64) rethrow;
        final me = session.profile;
        if (me == null) rethrow;
        await PartnerKeyPin.repin(
          myUid: me.id,
          partnerId: e.partnerId,
          partnerPubB64: e.newKeyB64,
        );
        await ensureSharedKey(session);
      }
      final dropped =
          await PartnerRewrap.answer(req, readableConfirmed: _readableConfirmed);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            dropped > 0
                ? 'Sent. Their phone can open it all now — though your own '
                    'earliest memories may no longer open here.'
                : 'Sent. Their phone can open it all now.',
          ),
        ),
      );
      _leave();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // The refusals are stated as sentences where they are raised, because
        // only that code knows which one happened: a declined unlock, or no
        // key on this phone at all. Guessing "the unlock" for both would tell
        // someone to fix a thing that was not the problem.
        _error = e is StateError ? e.message : partnerKeyMessage(e);
      });
      // Only this one refusal has a way past it, and only through the person
      // holding the phone. Offered after the digits have already matched, so it
      // is never the first thing anybody sees.
      if (e is StateError && e.message.contains('had lost your key')) {
        unawaited(_offerReadableOverride(req));
      }
    }
  }

  /// Ask the human the question the device cannot answer.
  ///
  /// Deliberately not a checkbox on the form. It appears only after a refusal,
  /// it states the cost of getting it wrong before the affirmative option, and
  /// the affirmative is worded as a fact about their screen ("Yes, I can read
  /// them") rather than as an instruction to proceed.
  Future<void> _offerReadableOverride(RewrapRequest req) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Can you still read your messages on this phone?'),
        content: const Text(
          'Open your chat and look, then come back.\n\n'
          'If you can read them, this phone holds the key and it is safe to '
          'send.\n\n'
          'If they look empty or scrambled, do not send — this phone would '
          'overwrite the real key and neither of you could open anything '
          'again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text("No, or I'm not sure"),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Yes, I can read them'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => _readableConfirmed = true);
    await _sendAnswer();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sessionProvider, (_, __) => unawaited(_load()));
    final name = ref.watch(sessionProvider).partner?.displayName ?? 'your partner';
    return Scaffold(
      backgroundColor: MilesColors.night,
      appBar: AppBar(title: const Text('Your history')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else if (_incoming != null)
                ..._answering(name)
              else
                ..._asking(name),
              if (_error != null) ...[
                const SizedBox(height: 16),
                AlertBanner(message: _error!),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _asking(String name) {
    final code = _code;
    // An expired code can no longer be answered — the policy refuses the write
    // — so the screen goes back to the button rather than leaving six dead
    // digits on it and no way forward.
    if (code == null || _left.isNegative) {
      return [
        Text('This phone has no key',
            style: Theme.of(context).textTheme.displaySmall,),
        const SizedBox(height: 8),
        Text(
          code == null
              ? 'Everything you wrote before is still here and still sealed. '
                  "$name's phone holds the key that opens it, and can hand it "
                  'over while the two of you are on a call.'
              : 'That code expired. Start again when you are both on the call.',
          style: const TextStyle(color: MilesColors.taupe, height: 1.5),
        ),
        const SizedBox(height: 24),
        GlowButton(
          label: 'Ask $name',
          color: MilesColors.blush,
          loading: _busy,
          onPressed: _busy ? null : _openRequest,
        ),
        // The router sends a keyless phone here from every route, so without a
        // way past it this screen is the whole app — settings and sign-out
        // included. Only the routing stops: nothing about tapping it puts the
        // key back, so escrow goes on refusing to seal the stand-in one and the
        // next sign-in offers the ceremony again.
        TextButton(
          onPressed: () async {
            await CryptoCore.deferRecovery();
            if (mounted) _leave();
          },
          child: const Text('Not now',
              style: TextStyle(color: MilesColors.taupe),),
        ),
      ];
    }
    return [
      Text('Read these to $name',
          style: Theme.of(context).textTheme.displaySmall,),
      const SizedBox(height: 8),
      const Text(
        'Call them and say the six digits out loud. Not in a message — a '
        'message can be read by whoever is in the way.',
        style: TextStyle(color: MilesColors.taupe, height: 1.5),
      ),
      const SizedBox(height: 24),
      SurfacePanel(
        glow: MilesColors.blush,
        padding: const EdgeInsets.all(28),
        child: Column(
          children: [
            Text(
              code,
              style: Theme.of(context).textTheme.displayLarge?.copyWith(
                    letterSpacing: 8,
                    fontWeight: FontWeight.w300,
                  ),
            ),
            const SizedBox(height: 8),
            Text(_countdown,
                style: const TextStyle(fontSize: 11, color: MilesColors.faint),),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Text(
        'Waiting for $name.',
        textAlign: TextAlign.center,
        style: const TextStyle(color: MilesColors.taupe),
      ),
    ];
  }

  List<Widget> _answering(String name) {
    final expired = _left.isNegative;
    return [
      Text('$name is setting up a new phone',
          style: Theme.of(context).textTheme.displaySmall,),
      const SizedBox(height: 8),
      const Text(
        'Their new phone cannot open anything you two have written. Yours '
        'still can, so it can pass the key across. Ask them to read you the '
        'six digits on their screen — on the call, not in a message.',
        style: TextStyle(color: MilesColors.taupe, height: 1.5),
      ),
      const SizedBox(height: 24),
      LoveTextField(
        controller: _typed,
        hint: '000000',
        textAlign: TextAlign.center,
        maxLength: 6,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textStyle: const TextStyle(
            color: MilesColors.cream50, fontSize: 22, letterSpacing: 6,),
      ),
      const SizedBox(height: 8),
      Text(
        expired ? 'That code expired — ask them to start again.' : _countdown,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 11, color: MilesColors.faint),
      ),
      const SizedBox(height: 16),
      GlowButton(
        label: 'Hand over the key',
        color: MilesColors.blush,
        loading: _busy,
        onPressed: _busy || expired ? null : _sendAnswer,
      ),
    ];
  }
}
