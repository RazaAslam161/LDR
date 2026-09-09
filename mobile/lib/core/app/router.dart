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
import 'package:miles/features/closer/memory_threads/memory_threads_screen.dart';
import 'package:miles/features/closer/memory_threads/propose_memory_screen.dart';
import 'package:miles/features/closer/mood_lamp/mood_lamp_screen.dart';
import 'package:miles/features/closer/pick_for_us/pick_for_us_screen.dart';
import 'package:miles/features/closer/touch_trace/touch_trace_screen.dart';
import 'package:miles/features/closer/warmth/warmth_meter_screen.dart';
import 'package:miles/features/closer/wish_jar/wish_jar_screen.dart';
import 'package:miles/features/cycle/cycle_screen.dart';
import 'package:miles/features/daily_prompt/daily_prompt_history_screen.dart';
import 'package:miles/features/daily_prompt/daily_prompt_screen.dart';
import 'package:miles/features/disguise/disguise_picker_screen.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:miles/features/disguise/entry/cover_entry_recorder_screen.dart';
import 'package:miles/features/gallery/gallery_screen.dart';
import 'package:miles/features/games/games_screen.dart';
import 'package:miles/features/games/synced_card_game_screen.dart';
import 'package:miles/features/games/truth_dare_screen.dart';
import 'package:miles/features/heartbeat/heartbeat_screen.dart';
import 'package:miles/features/home/location_map_screen.dart';
import 'package:miles/features/legal/terms_gate.dart';
import 'package:miles/features/legal/terms_screen.dart';
import 'package:miles/features/profile/partner_profile_screen.dart';
import 'package:miles/features/reasons/reasons_screen.dart';
import 'package:miles/features/reels/reel_queue_screen.dart';
import 'package:miles/features/rituals/rituals_screen.dart';
import 'package:miles/features/routines/routine_screen.dart';
import 'package:miles/features/safety/severance_state.dart';
import 'package:miles/features/settings/export_screen.dart';
import 'package:miles/features/settings/settings_screen.dart';
import 'package:miles/features/shell/app_shell.dart';
import 'package:miles/features/timeline/timeline_screen.dart';
import 'package:miles/features/unlink/unlink_screen.dart';
import 'package:miles/features/unlink/unlink_state.dart';
import 'package:miles/features/vault/vault_gate_screen.dart';
import 'package:miles/features/watch/watch_together_screen.dart';

/// The live observer, so app lifecycle changes can clear the published screen.
///
/// Null until the router is first built — which does not happen at all while
/// the disguise cover is up, and the lifecycle handler runs from the very first
/// frame. Backgrounding from the cover must not throw.
PresenceRouteObserver? presenceRouteObserver;

/// What is still reachable while the unlinking ritual is open.
///
/// The whole access policy, in one pure function, because the alternative is
/// a condition spread across a redirect and every screen that has to agree
/// with it. Everything not named here resolves to the ritual.
///
/// Two groups, and each is here for a reason that outranks the ritual:
///
///  * THE EXITS. Deleting the account and the permanent leave are never gated
///    on the ceremony — that is assertion #4 of 20260829120000, it is Play
///    policy, and trapping somebody inside a screen about leaving is the
///    precise failure this feature exists to stop being. /rewrap and /call go
///    with them: a phone that cannot read its own history must always be able
///    to fix that.
///  * THEIR MEMORIES. Export stays open to both of them at every stage. A
///    ritual that holds your photographs hostage is a threat, not a pause.
///
/// There was a third: chat, for the partner only. It is GONE, and it must not
/// come back in that shape. The initiator was locked out of chat, so the
/// partner's "Talk to them" opened a room the other person could not enter —
/// messages nobody would read until the ritual was already over, with message
/// pushes switched off so not even a notification escaped. A button promising
/// a conversation and delivering a monologue.
///
/// The note is the channel, and unlike chat it actually arrives: the partner
/// writes it, and it renders on the initiator's screen beside the Re-link
/// button. One channel that works beats two where one is theatre.
///
/// Takes only the path now. Both roles get the same set, so the row and the
/// uid stopped deciding anything the moment chat left.
@visibleForTesting
bool unlinkAllows(String path) {
  if (path == '/unlink') return true;
  const always = {
    '/app/settings/export',
    '/app/settings/account',
    '/rewrap',
    '/call',
  };
  return always.contains(path);
}

/// Routes the user based on auth + onboarding state.
GoRouter buildRouter(Ref ref) {
  return GoRouter(
    refreshListenable: Listenable.merge([
      _SessionListenable(ref),
      CryptoCore.keyless,
      TermsGate.accepted,
      // Read by the redirect below. Without it the /rewrap allowance is
      // decided once, against whatever was loaded when the router was built,
      // and a state that arrives afterwards never reopens the route.
      SeveranceState.held,
      // The unlinking ritual takes the app away, and gives it back the instant
      // somebody taps Re-link. Both directions have to move the router, and
      // both arrive asynchronously — realtime on the far phone, the RPC's own
      // reload on the near one.
      UnlinkState.current,
    ],),
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
        // One exception, and only one: the key ceremony, when there is
        // genuinely somebody who can answer it.
        //
        // This gate used to be unconditional, and the keyless check below was
        // placed under it with the reason "an account with no partner has
        // nobody to ask". That was true until 20260826180000. A dissolved
        // couple inside its window now has two members who can still run the
        // ceremony, and a phone that reinstalled during that window has
        // nothing but the account password between it and history it can never
        // read again.
        //
        // NOT hoisted above this gate, which would have been the smaller diff
        // and the wrong one: a fresh keyless account that never had a couple
        // would then be sent to /rewrap with nobody to ask — exactly the
        // deadlock the old ordering avoided. The allowance is conditional on
        // SeveranceState, so it opens only for somebody who has a counterpart.
        //
        // ALLOWED, never redirected TO. /rewrap is reached with push() from
        // the reconnect sheet, so it keeps its back button; forcing an
        // unpaired account onto it would cut them off from /couple, which is
        // where sign-out and the permanent erase live.
        if (path == '/rewrap' &&
            CryptoCore.keyless.value &&
            SeveranceState.held.value != null) {
          return null;
        }
        // Two routes an unpaired account keeps, because neither of them is the
        // couple's. The vault is owner_id-keyed, stored under auth.uid() in its
        // own bucket, sealed with a key derived from this account's own seed,
        // and purge_couple() names four buckets and deliberately excludes it.
        // The gallery archive resolves server-side through archived_couple_id()
        // and returns nothing for anyone who has moved on. Neither has ever
        // needed a partner; sending a person who had just unlinked to a pairing
        // screen and calling their own things gone was the whole of the report.
        // The data never moved. This line did.
        //
        // ALLOWED, never redirected TO, exactly like /rewrap above: the doors
        // are on /couple, which is also where sign-out and the permanent erase
        // live, so neither ends up behind a photo grid.
        if (path == '/app/vault' || path == '/app/gallery') return null;
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
      // partner and no dissolved couple has nobody to ask — the needsCouple
      // gate above carves out the case where there is somebody.
      //
      // '/call' is the one exception: the ceremony's own instructions are to
      // get on a call, and blocking that is a deadlock, not a guard.
      if (CryptoCore.keyless.value && path != '/rewrap' && path != '/call') {
        return '/rewrap';
      }

      // ── The unlinking ritual takes the app away. ──
      //
      // This is the difference between the ceremony people ignored and a
      // ceremony. The shipped version left both of them inside the app behind
      // a 4mm banner, and the tap that is meant to be the heaviest in the
      // product read as nothing happening at all.
      //
      // A redirect, not an AppShell push behind a SharedPreferences latch: a
      // latch is dismissible, survives one viewing, and raced the shell's own
      // lifecycle. This is the TermsGate shape — one `if`, above thirty-five
      // routes, unskippable — and the same reasoning applies, that checking at
      // each screen is how thirty-four end up unchecked.
      //
      // Below the keyless gate on purpose: a phone that cannot read a word of
      // the history has a worse problem than a countdown, and /rewrap is
      // reachable from the ritual anyway.
      final ceremony = UnlinkState.current.value;
      if (ceremony != null &&
          session.profile != null &&
          !unlinkAllows(path)) {
        return '/unlink';
      }

      // A couple of ONE is not "fully set up", and the sweep below used to
      // treat it as if it were.
      //
      // If both partners press "Create & get a code" — the obvious move when
      // neither was told who goes first — create_pairing_invite mints each of
      // them a couple of one. From the next relaunch loadProfile fills
      // session.couple, so needsCouple is false and '/couple' was swept to
      // '/app' forever. The only field in the whole app that redeems a code
      // lives on that route, and the invite deep link goes there too, so
      // neither of them could type the other's code or even open the other's
      // link. The recorded recovery was deleting an account.
      //
      // ALLOWED, never redirected TO: the funnel does not send a couple-holder
      // here, so the code screen on Home stays the landing. The server half has
      // been waiting since 20260601006000 — redeem_pairing_invite retires the
      // caller's empty couple — and this is the client half it was paired with.
      // The moment a partner actually lands, the session refresh puts '/couple'
      // back under the sweep, so nobody who is genuinely paired keeps it.
      if (path == '/couple' && session.partner == null) return null;

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
      // becomes an empty screen nobody can explain. The funnel moves an
      // unpaired account on to /couple UNLESS a dissolved couple is still
      // inside its window, in which case there is somebody to ask and the
      // ceremony is worth reaching.
      GoRoute(
        path: '/rewrap',
        builder: (context, state) => const RewrapScreen(),
      ),
      // The unlinking ritual. It HAS a redirect branch and a refreshListenable
      // entry now (both above) — the note in this place used to say it
      // deliberately had neither, which was true of a banner and is the reason
      // the ceremony read as nothing happening. After the couple dissolves the
      // needsCouple gate sweeps this route to /couple like any other.
      GoRoute(
        path: '/unlink',
        builder: (context, state) => const UnlinkScreen(),
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
        path: '/app/settings/export',
        builder: (context, state) => const ExportScreen(),
      ),
      // The three settings subpages. Recovered from build 52's binary, which
      // carried these exact paths — they are what let fourteen flat sections
      // become five groups. Each is the SAME screen in a different page, so
      // every handler stays where it already lives.
      GoRoute(
        path: '/app/settings/profile',
        builder: (context, state) =>
            const SettingsScreen(page: SettingsPage.profile),
      ),
      GoRoute(
        path: '/app/settings/notifications',
        builder: (context, state) =>
            const SettingsScreen(page: SettingsPage.notifications),
      ),
      GoRoute(
        path: '/app/settings/account',
        builder: (context, state) =>
            const SettingsScreen(page: SettingsPage.account),
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
      // The move recorder, for the cover named in the query. Only the picker
      // and the Settings row push it, always with a real name; an unknown
      // one records for the default cover rather than red-screening a route.
      GoRoute(
        path: '/app/disguise/entry',
        builder: (context, state) {
          // `none` is the absence of a cover, so there is nothing to record a
          // move on: it would draw the recorder over an empty box.
          final named =
              DisguiseCover.values.asNameMap()[state.uri.queryParameters['cover']];
          return CoverEntryRecorderScreen(
            cover: named == null || named == DisguiseCover.none
                ? kDefaultDisguise.cover
                : named,
          );
        },
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
      // No '/app/touch' route. TouchMapScreen is reached in production as a tab
      // body inside AppShell, which is what applies the adult check in front of
      // it; a top-level GoRoute rendered the same intimate surface with that
      // check nowhere in the tree. Nothing in lib/ ever pushed it — the only
      // references were test path fixtures and the presence name lookup, which
      // is a pure string map and still carries the entry for the tab. If Touch
      // ever needs a real route, it needs the gate written into the builder in
      // the same change.
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
        path: kCallRoute,
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
        path: '/app/prompt/history',
        builder: (context, state) => const DailyPromptHistoryScreen(),
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

/// The one route the call lives at. Named so the two places that push it and
/// the one that suppresses the floating window cannot drift apart.
const String kCallRoute = '/call';

/// The matched location of every route on the stack, bottom first.
///
/// Both predicates below read the router's own stack rather than any widget's
/// state, because the whole class of bug they exist for IS state that resets.
/// `_AppShellState._lastCallState` is per-State-instance, and the disguise
/// cover swaps the entire `MaterialApp`, so the rebuilt shell starts again at
/// `idle` while the GoRouter — a plain Provider, never invalidated — still has
/// `/call` on its stack. The router is the one thing a remount cannot lie
/// about.
///
/// `currentConfiguration.uri` is NOT the answer, which is worth stating because
/// it looks like it: an imperative `push` appends an `ImperativeRouteMatch` and
/// leaves `uri` at the BASE location, so a pushed `/call` still reports
/// `uri == '/app'`. The matches are what carry it.
List<String> _routeStack(GoRouter router) => router
    .routerDelegate.currentConfiguration.matches
    .map((m) => m.matchedLocation)
    .toList(growable: false);

/// True when the call screen is the top route — the one actually being looked
/// at. Used to hide the floating call window, which must never draw the same
/// `textureId` as a call screen already on screen.
bool isOnCallRoute(GoRouter router) {
  final stack = _routeStack(router);
  return stack.isNotEmpty && stack.last == kCallRoute;
}

/// True when a call screen is mounted ANYWHERE on the stack, visible or not.
///
/// Deliberately broader than [isOnCallRoute]: a `/call` buried under another
/// pushed route is not being painted, but its widgets are still mounted, so
/// pushing another would still leave two of them.
bool hasCallRoute(GoRouter router) => _routeStack(router).contains(kCallRoute);

/// Push the call screen, unless one is already mounted.
///
/// Both push sites — the shell's call-state listener and the floating window's
/// tap — must go through this. A second `/call` mounts a second [CallScreen],
/// and both copies then draw the SAME two `textureId`s, because the renderers
/// live on the controller and outlive every screen. That is what the
/// duplicated, overlapping video was: not one view drawing badly, but N views
/// drawing one texture — with another added on every disguise-cover cycle,
/// which is to say every time the sharer left the app and came back.
void pushCallRoute(GoRouter router) {
  if (hasCallRoute(router)) return;
  router.push(kCallRoute);
}
