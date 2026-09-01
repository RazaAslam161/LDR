import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/root_scaffold_key.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/data/partner_key_pin.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/services/sound/cue.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/ember_press.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:miles/features/closer/memory_threads/memory_thread_repository.dart';
import 'package:miles/features/closer/partner_key_change_sheet.dart';

/// Entry screen for the intimacy module ("Closer").
///
/// When Modest Mode is OFF, this screen proactively publishes our E2EE public
/// key (idempotent) and tries to derive the couple-shared key. If the partner
/// hasn't published theirs yet, we show a friendly "waiting for partner" state
/// with a retry button — instead of letting each sub-feature blow up with a
/// BadState error.
class CloserScreen extends ConsumerStatefulWidget {
  const CloserScreen({super.key});

  @override
  ConsumerState<CloserScreen> createState() => _CloserScreenState();
}

enum _KeyState { loading, ready, waitingForPartner, keyChanged, error }

class _CloserScreenState extends ConsumerState<CloserScreen> {
  _KeyState _key = _KeyState.loading;
  String? _error;

  /// The mismatch that put us in [_KeyState.keyChanged] — held because the
  /// review sheet needs the NEW key it carries, both to render the safety
  /// code and to repin once the couple has compared it.
  PartnerKeyChangedException? _keyChange;

  /// Where the two halves of the consent stand, once the server has said.
  ///
  /// Null while loading. [_consentError] is set instead when the read failed,
  /// and the two are deliberately not one nullable field: "nobody has consented
  /// yet" renders an instruction, and printing that instruction over a failed
  /// read tells somebody who has already turned Closer on to go and turn it on
  /// again.
  IntimacyConsent? _consent;
  String? _consentError;

  /// A failed WITHDRAWAL, kept apart from [_consentError] for the same reason
  /// that one is kept apart from [_consent]: the read's error screen says
  /// "could not check who has turned Closer on", which is the wrong sentence
  /// entirely over a write that was refused, and it would replace the button
  /// the user has to press again.
  String? _withdrawError;
  bool _withdrawing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _prepareKey();
  }

  Future<void> _prepareKey() async {
    final session = ref.read(sessionProvider);
    final couple = session.couple;
    final me = session.profile;
    final partner = session.partner;

    // Not enabled yet: the key is not the question, the consent is. Which of
    // the two of them has answered is the only thing that lets this screen
    // stop repeating "turn it on in Settings" at somebody who already did.
    if (couple == null || couple.modestMode || me == null || partner == null) {
      await _loadConsent(couple);
      return;
    }

    setState(() {
      _key = _KeyState.loading;
      _error = null;
      _keyChange = null;
    });

    try {
      // Always publish our own key first (idempotent upsert).
      await ensureSharedKey(session);
      if (!mounted) return;
      setState(() => _key = _KeyState.ready);
    } on PartnerKeyChangedException catch (e) {
      if (!mounted) return;
      // By TYPE, ahead of the string probes below: its toString carries no
      // sentence, so it fell into the raw-error state — a generic apology
      // with a retry that can never succeed, over the one failure here that
      // is a deliberate refusal and has its own resolution.
      setState(() {
        _key = _KeyState.keyChanged;
        _keyChange = e;
      });
    } catch (e) {
      if (!mounted) return;
      // ensureSharedKey signals "not linked" with StateError, which is not an
      // Exception — the old `on Exception` branch missed it and dropped it into
      // the raw-error state instead of the waiting-for-partner one.
      final msg = e.toString();
      if (msg.contains("hasn't enabled") ||
          msg.contains("hasn't published") ||
          msg.contains('partner')) {
        setState(() => _key = _KeyState.waitingForPartner);
      } else {
        setState(() {
          _key = _KeyState.error;
          _error = _friendly(e);
        });
      }
    }
  }

  /// An unpaired account is not asked: `intimacy_consent_state` would answer
  /// exactly this, and a round trip that can only return "nobody, nothing,
  /// modest" is one the screen can skip. Assigned rather than left null,
  /// because null is the loading state and this one is settled.
  Future<void> _loadConsent(Couple? couple) async {
    if (couple == null) {
      setState(() {
        _consent = (mine: false, partner: false, members: 0, modest: true);
        _consentError = null;
      });
      return;
    }
    setState(() {
      _consent = null;
      _consentError = null;
      _withdrawError = null;
    });
    try {
      final state = await SupabaseRepository.fetchIntimacyConsent();
      if (!mounted) return;
      setState(() => _consent = state);
      // Nothing pushes the partner's consent to this device — the realtime
      // channel carries the partner ROW, not the couple one — so this read is
      // the freshest word on the derived flag the whole screen switches on.
      // Without the reconcile, a couple whose Closer the server has just
      // opened goes on reading "waiting for them" here until something else
      // reloads the profile.
      if (couple.modestMode != state.modest) {
        await ref.read(sessionProvider.notifier).loadProfile();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _consentError = _friendly(e));
    }
  }

  /// Takes this member's half of the consent back while the couple is still
  /// waiting on the other half.
  ///
  /// Until this existed there was no control anywhere that could say no: the
  /// Settings switch is drawn from `couples.modest_mode`, which stays true
  /// until BOTH have agreed, so the only switch a waiting member was ever
  /// offered wrote consent = true again. The RPC's own answer is what the
  /// screen then renders — re-reading the couple row cannot tell "mine is off
  /// now" from "mine was never on", because the derived flag is true either
  /// way.
  Future<void> _withdrawConsent() async {
    setState(() {
      _withdrawing = true;
      _withdrawError = null;
    });
    try {
      final state = await SupabaseRepository.setIntimacyConsent(false);
      if (!mounted) return;
      setState(() => _consent = state);
    } catch (e) {
      if (!mounted) return;
      setState(() => _withdrawError = _friendly(e));
    } finally {
      if (mounted) setState(() => _withdrawing = false);
    }
  }

  Future<void> _reviewKeyChange() async {
    final me = ref.read(sessionProvider).profile;
    final change = _keyChange;
    if (me == null || change == null) return;
    final repinned = await PartnerKeyChangeSheet.show(
      context,
      myUid: me.id,
      exception: change,
    );
    // Re-run the whole entry load rather than flipping state locally: the
    // retry has to derive under the freshly pinned key, and _prepareKey is
    // the only path that does.
    if (repinned && mounted) await _prepareKey();
  }

  /// Closer's crypto guards throw `Exception('<sentence the user can act on>')`
  /// (closer_crypto.dart:24,32,46). Anything else landing here is a transport
  /// failure whose toString names the Supabase host.
  String _friendly(Object e) {
    final s = e.toString();
    return s.startsWith('Exception: ')
        ? s.substring('Exception: '.length)
        : friendlyAuthError(e);
  }

  @override
  Widget build(BuildContext context) {
    // didChangeDependencies does not fire on a provider change, so without this
    // the consent read stays whatever it was at first frame — including the
    // unpaired answer assigned before the couple had loaded, and the stale
    // "waiting for them" of a partner who has since agreed.
    ref.listen(
      sessionProvider.select((s) => (s.couple?.id, s.couple?.modestMode)),
      (_, __) => _prepareKey(),
    );
    final session = ref.watch(sessionProvider);
    final couple = session.couple;
    final isModest = couple?.modestMode ?? true;

    return Scaffold(
      appBar: AppBar(
        
        title: const Text('Closer'),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => rootScaffoldKey.currentState?.openDrawer(),
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: isModest
              ? _buildModestState(session.partner?.displayName)
              : _buildEnabledState(),
        ),
      ),
    );
  }

  Widget _buildModestState(String? partnerName) {
    final error = _consentError;
    if (error != null) {
      return _ConsentError(message: error, onRetry: _prepareKey);
    }
    final consent = _consent;
    if (consent == null) return const Center(child: CircularProgressIndicator());
    return _ModestModeOn(
      consent: consent,
      partnerName: partnerName,
      onWithdraw: _withdrawConsent,
      onRecheck: _prepareKey,
      withdrawing: _withdrawing,
      withdrawError: _withdrawError,
    );
  }

  Widget _buildEnabledState() {
    switch (_key) {
      case _KeyState.loading:
        return const Center(child: CircularProgressIndicator());
      case _KeyState.ready:
        return const _ModuleEnabled();
      case _KeyState.waitingForPartner:
        return _WaitingForPartner(onRetry: _prepareKey);
      case _KeyState.keyChanged:
        return _PartnerKeyChanged(onReview: _reviewKeyChange);
      case _KeyState.error:
        return _KeyError(
          message: _error ?? 'Unknown error',
          onRetry: _prepareKey,
        );
    }
  }
}

/// Shown when Modest Mode is on (default).
///
/// The last line here used to read "It stays off until both of you turn it on
/// in Settings" over a schema where one person's tap opened Closer on both
/// phones — the app stating a guarantee no code implemented. 20260829160000
/// made the guarantee real, so the sentence stays; what it can now do, because
/// the server will say, is stop repeating an instruction at whoever already
/// followed it.
class _ModestModeOn extends StatelessWidget {
  const _ModestModeOn({
    required this.consent,
    required this.onWithdraw,
    required this.onRecheck,
    required this.withdrawing,
    this.withdrawError,
    this.partnerName,
  });

  final IntimacyConsent consent;
  final VoidCallback onWithdraw;

  /// Re-reads the consent AND reconciles the session's copy of the derived
  /// flag, which is the pair of steps that turn a partner's yes on the other
  /// handset into this screen opening.
  final VoidCallback onRecheck;
  final bool withdrawing;
  final String? withdrawError;
  final String? partnerName;

  @override
  Widget build(BuildContext context) {
    // Named only when the server says there are two of them; a couple of one
    // has nobody to be waiting for, whatever the session still holds.
    final them = (partnerName?.trim().isNotEmpty ?? false)
        ? partnerName!.trim()
        : 'your partner';
    // members == 2 is the server's count of live members, and the derivation
    // needs exactly two — so a stale consent left behind by somebody who has
    // gone is not "waiting for them", it is nobody to wait for.
    final linked = consent.members == 2;
    final waiting = linked && consent.mine;
    final theirTurn = linked && !consent.mine && consent.partner;
    final line = !linked
        ? 'Closer opens for two. It stays off until the two of you are linked '
            'and both of you turn it on.'
        : waiting
            ? "You've turned Closer on. It opens the moment $them does too — "
                'nothing here is visible to either of you until then.'
            : theirTurn
                ? '$them has turned Closer on. It opens the moment you do too, '
                    'and not before.'
                : 'It stays off until both of you turn it on in Settings.';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🕯️', style: TextStyle(fontSize: 48)),
          const SizedBox(height: 16),
          Text(
            'A space for the two of you',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  color: const Color(0xFFFBF8F4),
                ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Closer is an optional, private part of Miles for the two of you — '
            'a quiet place to stay close across the distance. Touch traces, '
            'shared moods, a private vault.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0x99F5EFE6), height: 1.5),
          ),
          const SizedBox(height: 24),
          Text(
            line,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Color(0x66F5EFE6)),
          ),
          const SizedBox(height: 32),
          if (waiting) ...[
            // The one state Settings could not express before this pass, and
            // the only screen the waiting member is actually looking at. It
            // writes consent = false; the couple-wide flag does not move,
            // because it was already closed.
            OutlinedButton(
              onPressed: withdrawing ? null : onWithdraw,
              child: Text(withdrawing ? 'Taking it back…' : 'Take it back'),
            ),
            TextButton(
              // The answer being waited for lands on the OTHER phone and
              // arrives here on no channel. Without this the wait ends only
              // when something else happens to reload the profile.
              onPressed: withdrawing ? null : onRecheck,
              child: const Text('Check again'),
            ),
          ] else
            OutlinedButton(
              // push, not go: '/app/settings' is a top-level route, so go()
              // collapses the stack and leaves the Settings back arrow with
              // nothing to pop — it threw, and system back left the app.
              onPressed: () => context.push('/app/settings'),
              child: const Text('Open Settings'),
            ),
          if (withdrawError != null) ...[
            const SizedBox(height: 12),
            Text(
              // The button above stays where it is, so pressing it again IS
              // the retry — this line says why the last press did nothing
              // instead of leaving the screen looking as though it worked.
              withdrawError!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: MilesColors.blush),
            ),
          ],
        ],
      ),
    );
  }
}

/// The consent read failed.
///
/// Its own state, not the modest one: modest renders an instruction, and an
/// instruction printed over a failed read is the app telling somebody who has
/// already turned Closer on to go and turn it on again. Retry re-runs the whole
/// entry load, which is the only path that reaches the RPC.
class _ConsentError extends StatelessWidget {
  const _ConsentError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('⚠️', style: TextStyle(fontSize: 44)),
          const SizedBox(height: 12),
          Text(
            'Could not check who has turned Closer on',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  color: const Color(0xFFFBF8F4),
                ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0x80F5EFE6), fontSize: 12),
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: onRetry,
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

/// Shown when our key is published but partner's key isn't yet.
/// Both partners must open Closer at least once after enabling it.
class _WaitingForPartner extends StatelessWidget {
  const _WaitingForPartner({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🔑', style: TextStyle(fontSize: 44)),
          const SizedBox(height: 16),
          Text(
            'Waiting for your partner',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  color: const Color(0xFFFBF8F4),
                ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Your end-to-end encryption key is set up. Ask your partner to '
            'open the Closer tab once on their phone — that publishes their '
            'key and unlocks everything here.\n\n'
            'Memory Threads, the text of Wish Jar entries and the files in '
            'your Private Vault are end-to-end encrypted — readable by '
            'nobody but the two of you. The FAQ in Settings lists exactly '
            'what is and is not.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0x99F5EFE6), height: 1.5),
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: onRetry,
            child: const Text('Check again'),
          ),
        ],
      ),
    );
  }
}

/// Shown when the fetched partner key contradicts this device's pin.
///
/// Deliberately its own state and not the waiting-for-partner one: that
/// screen's advice ("ask them to open Closer once") cannot resolve a
/// mismatch, and its Check-again button would just meet the same refusal.
/// The only way forward is the review sheet, so that is the only button.
class _PartnerKeyChanged extends StatelessWidget {
  const _PartnerKeyChanged({required this.onReview});
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🔒', style: TextStyle(fontSize: 44)),
          const SizedBox(height: 16),
          Text(
            "Your partner's security key changed",
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  color: const Color(0xFFFBF8F4),
                ),
          ),
          const SizedBox(height: 12),
          const Text(
            'This usually means they reinstalled the app or moved to a new '
            'phone. It can also mean someone is interfering with your '
            'connection. Nothing here will decrypt or send until you review '
            'the change.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0x99F5EFE6), height: 1.5),
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: onReview,
            child: const Text('Review'),
          ),
        ],
      ),
    );
  }
}

class _KeyError extends StatelessWidget {
  const _KeyError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('⚠️', style: TextStyle(fontSize: 44)),
          const SizedBox(height: 12),
          Text(
            'Could not set up encryption',
            style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  color: const Color(0xFFFBF8F4),
                ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0x80F5EFE6), fontSize: 12),
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: onRetry,
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

/// What the couple sees once the shared key is derived and Closer is ready.
class _ModuleEnabled extends ConsumerStatefulWidget {
  const _ModuleEnabled();

  @override
  ConsumerState<_ModuleEnabled> createState() => _ModuleEnabledState();
}

class _ModuleEnabledState extends ConsumerState<_ModuleEnabled> {
  int _pendingMemories = 0;

  @override
  void initState() {
    super.initState();
    // A push landing while this grid is mounted must move the count without
    // waiting for the user to navigate away and back.
    pendingMemory.addListener(_refreshCounts);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshCounts());
  }

  @override
  void dispose() {
    pendingMemory.removeListener(_refreshCounts);
    super.dispose();
  }

  /// `state` and `proposer` are plaintext, so this needs no key and no PIN —
  /// which is the only reason a tile sealed behind one can carry a count at all.
  Future<void> _refreshCounts() async {
    final session = ref.read(sessionProvider);
    final coupleId = session.couple?.id;
    final me = session.profile?.id;
    if (coupleId == null || me == null) return;
    final n = await MemoryThreadRepository.pendingProposalCount(
      coupleId: coupleId,
      me: me,
    );
    if (!mounted || n == _pendingMemories) return;
    setState(() => _pendingMemories = n);
  }

  @override
  Widget build(BuildContext context) {
    final features = <_FeatureTile>[
      const _FeatureTile(
        emoji: '✏️',
        title: 'Touch Trace',
        blurb: 'Draw together, in real time',
        route: '/app/closer/touch-trace',
      ),
      const _FeatureTile(
        emoji: '🎨',
        title: 'Mood Lamp',
        blurb: 'A color, no words',
        route: '/app/closer/mood-lamp',
      ),
      const _FeatureTile(
        emoji: '🌡️',
        title: 'Closeness',
        blurb: 'How close do you feel today?',
        route: '/app/closer/warmth',
      ),
      const _FeatureTile(
        emoji: '🍯',
        title: 'Wish Jar',
        blurb: 'A quiet nudge when you match',
        route: '/app/closer/wish-jar',
      ),
      // Points at the shared gallery, not the vault. The vault's route still
      // exists so the couple's existing encrypted items stay reachable, but
      // this tile is the one people open, and the gallery is what replaces it.
      //
      // The blurb no longer says "encrypted": gallery objects are stored in the
      // clear so they can be paged and cached like any other picture, and a
      // promise the storage does not keep is worse than no promise.
      const _FeatureTile(
        emoji: '🖼️',
        title: 'Gallery',
        blurb: 'Everything, shared',
        route: '/app/gallery',
      ),
      const _FeatureTile(
        emoji: '✅',
        title: 'Today',
        blurb: 'Your day, side by side',
        route: '/app/routines',
      ),
      const _FeatureTile(
        emoji: '🎬',
        title: 'Watch list',
        blurb: 'Reels you send each other',
        route: '/app/watch-list',
      ),
      const _FeatureTile(
        emoji: '🎲',
        title: 'Pick for us',
        blurb: 'Let the dice decide',
        route: '/app/closer/pick-for-us',
      ),
      _FeatureTile(
        emoji: '🧵',
        title: 'Memory Threads',
        blurb: "Milestones you've kept",
        route: '/app/closer/memory-threads',
        badgeCount: _pendingMemories,
      ),
    ];

    return ListView(
      children: [
        Text(
          'For the two of you',
          style: Theme.of(context).textTheme.displaySmall?.copyWith(
                color: const Color(0xFFFBF8F4),
              ),
        ),
        const SizedBox(height: 8),
        const Text(
          'A private space for the two of you. Memory Threads and Wish Jar '
          'entries are end-to-end encrypted; the rest is kept behind strict '
          'access rules.',
          style: TextStyle(color: Color(0x99F5EFE6), height: 1.5),
        ),
        const SizedBox(height: 24),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.1,
          children: features,
        ),
      ],
    );
  }
}

class _FeatureTile extends StatelessWidget {
  const _FeatureTile({
    required this.emoji,
    required this.title,
    required this.blurb,
    required this.route,
    this.badgeCount = 0,
  });
  final String emoji;
  final String title;
  final String blurb;
  final String route;

  /// How many things inside are waiting for this person. Zero draws nothing.
  ///
  /// This tile had nowhere to put a count, and Memory Threads is the last of
  /// them with a second PIN behind it — so a proposal was undiscoverable even
  /// by someone standing on this screen looking straight at it.
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    return EmberPress(
      onTap: () => context.push(route),
      onCue: () => MilesSound.cue(Cue.tap),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: MilesColors.surface1,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: const Color(0xFFEF6F58).withValues(alpha: 0.3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(emoji, style: const TextStyle(fontSize: 28)),
                if (badgeCount > 0)
                  Container(
                    constraints: const BoxConstraints(minWidth: 20),
                    height: 20,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: Color(0xFFEF6F58),
                      borderRadius: BorderRadius.all(Radius.circular(10)),
                    ),
                    child: Text(
                      badgeCount > 9 ? '9+' : '$badgeCount',
                      style: const TextStyle(
                        color: Color(0xFF141B26),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                else
                  const Icon(Icons.arrow_outward,
                      size: 14, color: Color(0xFFEF6F58),),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFFFBF8F4),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  blurb,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0x80F5EFE6),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
