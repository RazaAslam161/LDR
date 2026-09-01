import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/glow_button.dart';

/// Where a signed-in user waits while the server cannot be reached.
///
/// A cold start in airplane mode used to fall through to the new-user form: a
/// profile fetch that threw and one that found no row both left the profile
/// null, and the router reads null as "needs onboarding". Filling that form in
/// upserted a blank name, timezone and date of birth over the real ones the
/// moment connectivity returned. The router now holds a failed load here
/// instead — see [SessionState.profileLoadFailed] — and this screen's only job
/// is to say so and try again until the server actually answers.
class OfflineScreen extends ConsumerStatefulWidget {
  const OfflineScreen({super.key});

  @override
  ConsumerState<OfflineScreen> createState() => _OfflineScreenState();
}

class _OfflineScreenState extends ConsumerState<OfflineScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Retry on arrival, not only on the button. On the disguised channel the
    // cover replaces the whole widget tree, so coming back to the app mounts
    // this screen AFTER the resumed event has fired — the observer below never
    // hears it. Mounting is that path's resume signal.
    WidgetsBinding.instance.addPostFrameCallback((_) => _retry());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Connectivity comes back OUTSIDE the app — airplane mode, wifi, a tunnel
  /// ending — so returning to it is the moment a retry is most likely to land.
  /// Nobody should have to find the button for that. (main.dart's own resume
  /// refresh only runs once a couple is loaded, which is exactly what this
  /// screen exists for lacking.)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _retry();
  }

  /// The same path a successful launch takes, so success here IS a successful
  /// launch. No navigation either: the loaded session changes state, the
  /// router re-runs its redirect, and this screen is swept to wherever the
  /// funnel says next.
  void _retry() {
    // The post-frame callback can outlive this screen — a retry elsewhere can
    // succeed and let the redirect sweep it away inside the first frame.
    if (!mounted) return;
    // The resumed event and the post-frame callback can land together; one
    // attempt at a time.
    if (ref.read(sessionProvider).loading) return;
    ref.read(sessionProvider.notifier).loadProfile();
  }

  /// The exit for the failures retrying cannot fix.
  ///
  /// loadProfile does not only fail for network reasons — a revoked session
  /// the gateway rejects, a paused project, an account in a broken state all
  /// land here too, and the copy below blames the connection for every one of
  /// them. Without this, that person is parked behind "try again" forever.
  /// Same quiet corner as /couple's sign-out, for the same reason: an exit
  /// that is findable without competing with the retry it sits above.
  Future<void> _signOut() async {
    try {
      await ref.read(sessionProvider.notifier).signOut();
    } catch (e) {
      // Expected on this screen of all screens: the server-side revoke needs
      // the network this screen exists for lacking. gotrue drops the local
      // session BEFORE that call, so the sign-out has already happened on this
      // device — log the revoke failure and let the funnel move on.
      debugPrint('[offline] sign-out revoke failed: $e');
    }
    if (mounted) context.go('/signin');
  }

  @override
  Widget build(BuildContext context) {
    final loading = ref.watch(sessionProvider.select((s) => s.loading));
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      "Can't reach the server",
                      style: Theme.of(context).textTheme.displaySmall,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Everything you two have is still here and still safe. '
                      'This phone just could not reach the server to open it. '
                      'Check your connection and try again.',
                      style: TextStyle(color: MilesColors.taupe, height: 1.5),
                    ),
                    const SizedBox(height: 24),
                    GlowButton(
                      label: 'Try again',
                      color: MilesColors.blush,
                      loading: loading,
                      onPressed: loading ? null : _retry,
                    ),
                  ],
                ),
              ),
            ),
            // Never greyed out while loading, unlike /couple's: the retry loop
            // here owns `loading` and re-fires itself on every resume, so an
            // exit that dims whenever a ten-second timeout is pending is an
            // exit that is mostly not there.
            Positioned(
              top: 4,
              right: 4,
              child: TextButton(
                onPressed: _signOut,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  foregroundColor: MilesColors.taupe,
                ),
                child: const Text('Sign out'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
