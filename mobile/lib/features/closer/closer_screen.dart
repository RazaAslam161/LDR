import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/root_scaffold_key.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:miles/features/closer/memory_threads/memory_thread_repository.dart';

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

enum _KeyState { loading, ready, waitingForPartner, error }

class _CloserScreenState extends ConsumerState<CloserScreen> {
  _KeyState _key = _KeyState.loading;
  String? _error;

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

    // If not enabled yet, the modest-mode UI handles it; skip key prep.
    if (couple == null || couple.modestMode || me == null || partner == null) {
      return;
    }

    setState(() {
      _key = _KeyState.loading;
      _error = null;
    });

    try {
      // Always publish our own key first (idempotent upsert).
      await ensureSharedKey(session);
      if (!mounted) return;
      setState(() => _key = _KeyState.ready);
    } on Exception catch (e) {
      final msg = e.toString();
      if (msg.contains("hasn't enabled") ||
          msg.contains("hasn't published") ||
          msg.contains('partner')) {
        setState(() => _key = _KeyState.waitingForPartner);
      } else {
        setState(() {
          _key = _KeyState.error;
          _error = msg;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _key = _KeyState.error;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final couple = session.couple;
    final isModest = couple?.modestMode ?? true;

    return Scaffold(
      appBar: AppBar(
        actions: const [PartnerHereAction()],
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
              ? const _ModestModeOn()
              : _buildEnabledState(),
        ),
      ),
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
      case _KeyState.error:
        return _KeyError(
          message: _error ?? 'Unknown error',
          onRetry: _prepareKey,
        );
    }
  }
}

/// Shown when Modest Mode is on (default).
class _ModestModeOn extends StatelessWidget {
  const _ModestModeOn();

  @override
  Widget build(BuildContext context) {
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
            'Closer is an optional, private part of Miles for adult couples '
            'who want to deepen intimacy across distance. Touch traces, '
            'shared moods, a private vault.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0x99F5EFE6), height: 1.5),
          ),
          const SizedBox(height: 24),
          const Text(
            'It stays off until both of you turn it on in Settings.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Color(0x66F5EFE6)),
          ),
          const SizedBox(height: 32),
          OutlinedButton(
            // push, not go: '/app/settings' is a top-level route, so go()
            // collapses the stack and leaves the Settings back arrow with
            // nothing to pop — it threw, and system back left the app.
            onPressed: () => context.push('/app/settings'),
            child: const Text('Open Settings'),
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
            'Nothing in Closer is readable by anyone but the two of you — '
            'not even us.',
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
      _FeatureTile(
        emoji: '✏️',
        title: 'Touch Trace',
        blurb: 'Draw together, in real time',
        route: '/app/closer/touch-trace',
      ),
      _FeatureTile(
        emoji: '🎨',
        title: 'Mood Lamp',
        blurb: 'A color, no words',
        route: '/app/closer/mood-lamp',
      ),
      _FeatureTile(
        emoji: '🌡️',
        title: 'Desire',
        blurb: 'How much today?',
        route: '/app/closer/desire',
      ),
      _FeatureTile(
        emoji: '🍯',
        title: 'Fantasy Jar',
        blurb: 'Soft matches, big sparks',
        route: '/app/closer/fantasy-jar',
      ),
      _FeatureTile(
        emoji: '🌙',
        title: 'Afterglow',
        blurb: 'The tenderness after',
        route: '/app/closer/afterglow',
      ),
      _FeatureTile(
        emoji: '🔒',
        title: 'Private Vault',
        blurb: 'Yours alone, encrypted',
        route: '/app/closer/vault',
      ),
      _FeatureTile(
        emoji: '🗺️',
        title: 'Body Map',
        blurb: 'Pin what you love',
        route: '/app/closer/body-map',
      ),
      _FeatureTile(
        emoji: '🎲',
        title: 'Pick for us',
        blurb: 'A roll for tonight',
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
          'A private, end-to-end encrypted space. Nothing here is readable '
          'by anyone but the two of you — not even us.',
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
  /// This tile had nowhere to put a count, and Memory Threads is the ninth of
  /// nine with a second PIN behind it — so a proposal was undiscoverable even
  /// by someone standing on this screen looking straight at it.
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.push(route),
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
                      shape: BoxShape.rectangle,
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
