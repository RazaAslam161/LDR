import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/features/auth/couple_page.dart';
import 'package:miles/features/auth/sign_in_page.dart';
import 'package:miles/features/auth/sign_up_page.dart';
import 'package:miles/features/auth/welcome_page.dart';
import 'package:miles/features/call/call_screen.dart';
import 'package:miles/features/capsule/capsule_create_screen.dart';
import 'package:miles/features/capsule/capsule_detail_screen.dart';
import 'package:miles/features/capsule/capsule_fill_screen.dart';
import 'package:miles/features/capsule/capsule_list_screen.dart';
import 'package:miles/features/capsule/capsule_repository.dart';
import 'package:miles/features/closer/afterglow/afterglow_form_screen.dart';
import 'package:miles/features/closer/afterglow/afterglow_screen.dart';
import 'package:miles/features/closer/body_map/body_map_screen.dart';
import 'package:miles/features/closer/desire/desire_temp_screen.dart';
import 'package:miles/features/closer/fantasy_jar/fantasy_jar_screen.dart';
import 'package:miles/features/closer/memory_threads/memory_threads_screen.dart';
import 'package:miles/features/closer/memory_threads/propose_memory_screen.dart';
import 'package:miles/features/closer/mood_lamp/mood_lamp_screen.dart';
import 'package:miles/features/closer/pick_for_us/pick_for_us_screen.dart';
import 'package:miles/features/closer/private_vault/private_vault_screen.dart';
import 'package:miles/features/closer/touch_trace/touch_trace_screen.dart';
import 'package:miles/features/daily_prompt/daily_prompt_screen.dart';
import 'package:miles/features/intimacy/intimacy_prefs_screen.dart';
import 'package:miles/features/intimacy/intimacy_screen.dart';
import 'package:miles/features/rituals/rituals_screen.dart';
import 'package:miles/features/settings/settings_screen.dart';
import 'package:miles/features/shell/app_shell.dart';
import 'package:miles/features/timeline/timeline_screen.dart';
import 'package:miles/features/together/together_screen.dart';
import 'package:miles/features/touch_map/touch_map_screen.dart';
import 'package:miles/features/vault/vault_gate_screen.dart';

/// Routes the user based on auth + onboarding state.
GoRouter buildRouter(Ref ref) {
  return GoRouter(
    refreshListenable: _SessionListenable(ref),
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      final path = state.uri.path;

      final isAuthRoute = path == '/signin' || path == '/signup';

      // While the session is resolving, don't bounce — let the current route
      // (usually the '/' spinner) render until we know where to send them.
      if (session.loading) return null;

      // ── Not signed in → only the auth pages are reachable. ──
      if (!session.isAuthenticated) {
        return isAuthRoute ? null : '/signin';
      }

      // ── Signed in: walk the onboarding funnel profile → couple → app. ──
      // This now runs on EVERY route (including /app), so a half-onboarded
      // user can never slip straight into the app and get stuck.
      final needsProfile =
          session.profile == null || !session.profile!.isOnboarded;
      final needsCouple = session.couple == null;

      if (needsProfile) {
        return path == '/welcome' ? null : '/welcome';
      }
      if (needsCouple) {
        // Stay on /couple while linking (Create shows the invite code there).
        return path == '/couple' ? null : '/couple';
      }

      // Fully set up → keep them out of the auth + onboarding routes.
      if (isAuthRoute ||
          path == '/welcome' ||
          path == '/couple' ||
          path == '/') {
        return '/app';
      }

      return null;
    },
    routes: [
      GoRoute(
        path: '/signin',
        builder: (context, state) => SignInPage(
          redirect: state.uri.queryParameters['redirect'],
        ),
      ),
      GoRoute(
        path: '/signup',
        builder: (context, state) => const SignUpPage(),
      ),
      GoRoute(
        path: '/welcome',
        builder: (context, state) => const WelcomePage(),
      ),
      GoRoute(
        path: '/couple',
        builder: (context, state) => const CouplePage(),
      ),
      GoRoute(
        path: '/app',
        builder: (context, state) => const AppShell(),
      ),
      GoRoute(
        path: '/app/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/app/capsule',
        builder: (context, state) => const CapsuleListScreen(),
      ),
      GoRoute(
        path: '/app/capsule/new',
        builder: (context, state) => const CapsuleCreateScreen(),
      ),
      GoRoute(
        path: '/app/capsule/view',
        builder: (context, state) =>
            CapsuleDetailScreen(capsule: state.extra! as Capsule),
      ),
      GoRoute(
        path: '/app/capsule/fill',
        builder: (context, state) =>
            CapsuleFillScreen(capsule: state.extra! as Capsule),
      ),
      GoRoute(
        path: '/app/intimacy',
        builder: (context, state) => const IntimacyScreen(),
      ),
      GoRoute(
        path: '/app/intimacy/prefs',
        builder: (context, state) => const IntimacyPrefsScreen(),
      ),
      GoRoute(
        path: '/app/vault',
        builder: (context, state) => const VaultGateScreen(),
      ),
      GoRoute(
        path: '/app/touch',
        builder: (context, state) => const TouchMapScreen(),
      ),
      GoRoute(
        path: '/app/together',
        builder: (context, state) => const TogetherScreen(),
      ),
      GoRoute(
        path: '/call',
        builder: (context, state) => const CallScreen(),
      ),
      GoRoute(
        path: '/app/rituals',
        builder: (context, state) => const RitualsScreen(),
      ),
      GoRoute(
        path: '/app/prompt',
        builder: (context, state) => const DailyPromptScreen(),
      ),
      GoRoute(
        path: '/app/timeline',
        builder: (context, state) => const TimelineScreen(),
      ),
      GoRoute(
        path: '/app/closer/touch-trace',
        builder: (context, state) => const TouchTraceScreen(),
      ),
      GoRoute(
        path: '/app/closer/mood-lamp',
        builder: (context, state) => const MoodLampScreen(),
      ),
      GoRoute(
        path: '/app/closer/desire',
        builder: (context, state) => const DesireTempScreen(),
      ),
      GoRoute(
        path: '/app/closer/vault',
        builder: (context, state) => const PrivateVaultScreen(),
      ),
      GoRoute(
        path: '/app/closer/afterglow',
        builder: (context, state) => const AfterglowScreen(),
      ),
      GoRoute(
        path: '/app/closer/afterglow/new',
        builder: (context, state) => const AfterglowFormScreen(),
      ),
      GoRoute(
        path: '/app/closer/memory-threads',
        builder: (context, state) => const MemoryThreadsScreen(),
      ),
      GoRoute(
        path: '/app/closer/memory-threads/propose',
        builder: (context, state) => const ProposeMemoryScreen(),
      ),
      GoRoute(
        path: '/app/closer/fantasy-jar',
        builder: (context, state) => const FantasyJarScreen(),
      ),
      GoRoute(
        path: '/app/closer/body-map',
        builder: (context, state) => const BodyMapScreen(),
      ),
      GoRoute(
        path: '/app/closer/pick-for-us',
        builder: (context, state) => const PickForUsScreen(),
      ),
      // Catch-all / → show loading spinner while session initialises,
      // then the redirect logic will push to /signin or /app.
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: CircularProgressIndicator(),
          ),
        ),
      ),
    ],
  );
}

/// Bridges Riverpod state to GoRouter's refreshListenable so the router
/// re-evaluates redirects whenever the session changes.
class _SessionListenable extends ChangeNotifier {
  _SessionListenable(this.ref) {
    ref.listen<SessionState>(sessionProvider, (_, __) => notifyListeners());
  }
  final Ref ref;
}

/// Provider for the router.
final routerProvider = Provider<GoRouter>(buildRouter);
