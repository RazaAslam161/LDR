import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/realtime/presence_route_observer.dart';
import 'package:miles/features/auth/couple_page.dart';
import 'package:miles/features/auth/new_password_page.dart';
import 'package:miles/features/auth/offline_screen.dart';
import 'package:miles/features/auth/rewrap_screen.dart';
import 'package:miles/features/auth/role_setup_screen.dart';
import 'package:miles/features/auth/sign_in_page.dart';
import 'package:miles/features/auth/sign_up_page.dart';
import 'package:miles/features/auth/welcome_page.dart';
import 'package:miles/features/breath/breath_sync_screen.dart';
import 'package:miles/features/call/call_screen.dart';
import 'package:miles/features/capsule/capsule_create_screen.dart';
import 'package:miles/features/capsule/capsule_detail_screen.dart';
import 'package:miles/features/capsule/capsule_fill_screen.dart';
import 'package:miles/features/capsule/capsule_list_screen.dart';
import 'package:miles/features/capsule/capsule_repository.dart';
import 'package:miles/features/care/care_screen.dart';
import 'package:miles/features/chat/camera/rapid_camera_screen.dart';
import 'package:miles/features/closer/warmth/warmth_meter_screen.dart';
import 'package:miles/features/closer/wish_jar/wish_jar_screen.dart';
import 'package:miles/features/closer/memory_threads/memory_threads_screen.dart';
import 'package:miles/features/closer/memory_threads/propose_memory_screen.dart';
import 'package:miles/features/closer/mood_lamp/mood_lamp_screen.dart';
import 'package:miles/features/closer/pick_for_us/pick_for_us_screen.dart';
import 'package:miles/features/gallery/gallery_screen.dart';
import 'package:miles/features/reels/reel_queue_screen.dart';
import 'package:miles/features/routines/routine_screen.dart';
import 'package:miles/features/closer/touch_trace/touch_trace_screen.dart';
import 'package:miles/features/cycle/cycle_screen.dart';
import 'package:miles/features/daily_prompt/daily_prompt_screen.dart';
import 'package:miles/features/disguise/disguise_picker_screen.dart';
import 'package:miles/features/games/games_screen.dart';
import 'package:miles/features/games/synced_card_game_screen.dart';
import 'package:miles/features/games/truth_dare_screen.dart';
import 'package:miles/features/heartbeat/heartbeat_screen.dart';
import 'package:miles/features/home/location_map_screen.dart';
import 'package:miles/features/legal/terms_gate.dart';
import 'package:miles/features/legal/terms_screen.dart';
import 'package:miles/features/profile/partner_profile_screen.dart';
import 'package:miles/features/reasons/reasons_screen.dart';
import 'package:miles/features/rituals/rituals_screen.dart';
import 'package:miles/features/settings/settings_screen.dart';
import 'package:miles/features/shell/app_shell.dart';
import 'package:miles/features/timeline/timeline_screen.dart';
import 'package:miles/features/touch_map/touch_map_screen.dart';
import 'package:miles/features/vault/vault_gate_screen.dart';
import 'package:miles/features/watch/watch_together_screen.dart';

/// The live observer, so app lifecycle changes can clear the published screen.
///
/// Null until the router is first built — which does not happen at all while
/// the disguise cover is up, and the lifecycle handler runs from the very first
/// frame. Backgrounding from the cover must not throw.
PresenceRouteObserver? presenceRouteObserver;

/// Routes the user based on auth + onboarding state.
GoRouter buildRouter(Ref ref) {
  return GoRouter(
    refreshListenable: Listenable.merge(
        [_SessionListenable(ref), CryptoCore.keyless, TermsGate.accepted],),
    // Presence is published from here rather than from each screen, so every
    // route reports — including the 31 that never did, and any added later.
    observers: [presenceRouteObserver = PresenceRouteObserver(ref)],
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      final path = state.uri.path;

      final isAuthRoute = path == '/signin' || path == '/signup';

      // A recovery link signs the user in with a short-lived session, so the
      // onboarding funnel below would otherwise sweep them straight to /app
      // (or /couple) and they would never reach the password field they came
      // here to fill in. Recovery outranks the funnel.
      if (path == '/new-password') return null;

      // While the session is resolving, don't bounce — let the current route
      // render until we know where to send them.
      if (session.loading) return null;

      // ── Not signed in → only the auth pages are reachable. ──
      if (!session.isAuthenticated) {
        return isAuthRoute ? null : '/signin';
      }

      // ── Signed in: the terms, before anything can be posted. ──
      // This one `if` is the whole enforcement. There are around thirty-five
      // paths that put content into this app; checking at each of them is how
      // thirty-four end up unchecked, and how the next one added is the
      // thirty-fifth. Above the onboarding funnel because agreeing to the terms
      // precedes having a profile or a partner, and because a brand-new account
      // is exactly the one that has agreed to nothing.
      //
      // Enforced only here, client-side, this release: build 31 has never heard
      // of tos_acceptances, and a server-side gate would lock it out of its own
      // account with no update channel to escape through.
      if (TermsGate.needsAcceptance) {
        return path == '/terms' ? null : '/terms';
      }

      // ── Signed in, but the last profile load FAILED. ──
      // Above the funnel, because the funnel reads a null profile as a
      // brand-new account. For a paired user cold-starting offline that
      // reading is destructive, not just wrong: the welcome form they landed
      // on upserts a blank name, timezone and date of birth over their real
      // ones the moment connectivity returns. A failed fetch waits on a screen
      // that says so and retries; only a server that ANSWERED "no row" may
      // send anyone to onboarding.
      if (session.profileLoadFailed) {
        return path == '/offline' ? null : '/offline';
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

      // Paired but hasn't set their gender yet → one-time role setup (Issue 4).
      final needsRole = session.profile != null && !session.profile!.genderSet;
      if (needsRole) {
        return path == '/role-setup' ? null : '/role-setup';
      }

      // This device cannot read a line of what the two of them wrote. Sending
      // it into the app is how that becomes blank encrypted screens with no
      // explanation and no route back — and the route back has to be decided
      // here, because the sign-in page is unmounted by this very redirect
      // before its own navigation can run, and a relaunch (the ordinary case,
      // since the cover backgrounds the app and Android kills it) never passes
      // through that page at all. Below the funnel because an account with no
      // partner has nobody to ask.
      //
      // '/call' is the one exception: the ceremony's own instructions are to
      // get on a call, and blocking that is a deadlock, not a guard.
      if (CryptoCore.keyless.value && path != '/rewrap' && path != '/call') {
        return '/rewrap';
      }

      // Fully set up → keep them out of the auth + onboarding routes.
      if (isAuthRoute ||
          path == '/welcome' ||
          path == '/couple' ||
          path == '/role-setup' ||
          path == '/terms' ||
          path == '/offline' ||
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
        path: '/new-password',
        builder: (context, state) => const NewPasswordPage(),
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
        path: '/role-setup',
        builder: (context, state) => const RoleSetupScreen(),
      ),
      GoRoute(
        path: '/terms',
        builder: (context, state) => const TermsScreen(),
      ),
      // Where a failed profile load waits — see the redirect above. In the
      // funnel's sweep list, so the moment a retry answers, the session state
      // moves the user on without this screen doing any navigating of its own.
      GoRoute(
        path: '/offline',
        builder: (context, state) => const OfflineScreen(),
      ),
      // Deliberately outside the funnel's sweep-to-/app list: a phone that
      // reached here has no key, and bouncing it into the app is how that
      // becomes an empty screen nobody can explain. The funnel still moves an
      // unpaired account on to /couple, where there is nobody to ask anyway.
      GoRoute(
        path: '/rewrap',
        builder: (context, state) => const RewrapScreen(),
      ),
      GoRoute(
        path: '/app',
        builder: (context, state) => const AppShell(),
      ),
      GoRoute(
        path: '/app/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      // No partner id in the path. The screen reads the session, so a link that
      // outlives a sign-out opens the new account's partner or nothing at all —
      // never the previous one's.
      GoRoute(
        path: '/app/partner',
        builder: (context, state) => const PartnerProfileScreen(),
      ),
      GoRoute(
        path: '/app/disguise',
        builder: (context, state) => DisguisePickerScreen(
          isOnboarding: state.uri.queryParameters['onboarding'] == '1',
        ),
      ),
      GoRoute(
        path: '/app/rapid-camera',
        builder: (context, state) {
          final extra = (state.extra as Map?) ?? const {};
          return RapidCameraScreen(
            coupleId: (extra['coupleId'] ?? '') as String,
            myUid: (extra['myUid'] ?? '') as String,
            returnFile: extra['mode'] == 'checkin',
          );
        },
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
        path: '/app/vault',
        builder: (context, state) => const VaultGateScreen(),
      ),
      GoRoute(
        path: '/app/breath',
        builder: (context, state) => const BreathSyncScreen(),
      ),
      GoRoute(
        path: '/app/touch',
        builder: (context, state) => const TouchMapScreen(),
      ),
      GoRoute(
        path: '/app/reasons',
        builder: (context, state) => const ReasonsScreen(),
      ),
      GoRoute(
        path: '/app/care',
        builder: (context, state) => const CareScreen(),
      ),
      GoRoute(
        path: '/app/watch',
        builder: (context, state) => const WatchTogetherScreen(),
      ),
      GoRoute(
        path: '/app/cycle',
        builder: (context, state) => const CycleScreen(),
      ),
      GoRoute(
        path: '/app/heartbeat',
        builder: (context, state) => const HeartbeatScreen(),
      ),
      GoRoute(
        path: '/app/games',
        builder: (context, state) => const GamesScreen(),
      ),
      GoRoute(
        path: '/app/games/truth-dare',
        builder: (context, state) => const TruthDareScreen(),
      ),
      GoRoute(
        path: '/app/games/would-you-rather',
        builder: (context, state) =>
            const SyncedCardGameScreen(deck: CardDeck.wouldYouRather),
      ),
      GoRoute(
        path: '/app/games/never-have-i-ever',
        builder: (context, state) =>
            const SyncedCardGameScreen(deck: CardDeck.neverHaveIEver),
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
        path: '/app/location-map',
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>? ?? {};
          return LocationMapScreen(
            coupleId: extra['coupleId'] as String? ?? '',
            partnerName: extra['partnerName'] as String? ?? 'Partner',
          );
        },
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
        path: '/app/closer/warmth',
        builder: (context, state) => const WarmthMeterScreen(),
      ),
      // The shared gallery that replaces the vault's grid. Both routes exist
      // during the changeover: the vault still holds the couple's existing
      // encrypted items, and removing its route would make them unreachable
      // before anything has migrated them.
      GoRoute(
        path: '/app/gallery',
        builder: (context, state) => const GalleryScreen(),
      ),
      GoRoute(
        path: '/app/routines',
        builder: (context, state) => const RoutineScreen(),
      ),
      GoRoute(
        path: '/app/watch-list',
        builder: (context, state) => const ReelQueueScreen(),
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
        path: '/app/closer/wish-jar',
        builder: (context, state) => const WishJarScreen(),
      ),
      GoRoute(
        path: '/app/closer/pick-for-us',
        builder: (context, state) => const PickForUsScreen(),
      ),
      // Boot location. The News cover is the real cold-start; if the real app
      // ever mounts at '/', funnel straight into the auth flow (the global
      // redirect then sends signed-in + paired users on to /app).
      GoRoute(
        path: '/',
        redirect: (_, __) => '/signin',
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
