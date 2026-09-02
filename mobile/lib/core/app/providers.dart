import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/features/disguise/disguise_cover_host.dart'
    show DisguiseCoverHost;

/// Granular, read-only views over the bundled [sessionProvider]. Features should
/// watch the narrowest provider they need so they only rebuild when that slice
/// changes.

/// The signed-in user's profile (null until loaded / onboarded).
final currentProfileProvider = Provider<Profile?>(
  (ref) => ref.watch(sessionProvider).profile,
);

/// The couple this user belongs to (null until paired).
final currentCoupleProvider = Provider<Couple?>(
  (ref) => ref.watch(sessionProvider).couple,
);

/// The partner's profile (null until the partner has joined).
final partnerProfileProvider = Provider<Profile?>(
  (ref) => ref.watch(sessionProvider).partner,
);

/// A short-lived invite code captured from a deep link (tethered://join?code=…),
/// consumed by the pairing screen to pre-fill the join field.
final pendingInviteCodeProvider = StateProvider<String?>((ref) => null);

/// The selected bottom-nav tab in the AppShell, stored as the ROOM's identity
/// ('home', 'chat', 'touch', 'closer') — never as a bar index. A bar index's
/// meaning changes when the modest/adult flags rebuild the bar, and those
/// flags can change while NO shell exists (the disguise cover replaces the
/// whole tree on every background), so any remap baseline held in shell
/// State dies exactly when it is needed. Identity is flag-independent by
/// construction: whatever room the user was in is the room the next shell
/// mounts into, and a room that no longer exists resolves to Home.
final shellTabProvider = StateProvider<String>((ref) => 'home');

/// Set when a password-reset link opens a recovery session, so the app can
/// route to /new-password instead of letting the onboarding funnel swallow it.
final passwordRecovery = ValueNotifier<bool>(false);

/// Set when tethered://auth-callback arrives — an email confirmation or a
/// password-reset link.
///
/// Reading the link means opening a mail app, which backgrounds this one and
/// drops it to the cover. The link then wakes it behind that cover, where the
/// router does not exist: supabase_flutter redeems the token, the session goes
/// valid, and the user is looking at a calculator with nothing to say it
/// worked. Watched by [DisguiseCoverHost], same as an incoming call.
final pendingAuthLink = ValueNotifier<bool>(false);
