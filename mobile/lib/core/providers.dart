import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/models.dart';
import 'package:miles/core/session_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Granular, read-only views over the bundled [sessionProvider]. Features should
/// watch the narrowest provider they need so they only rebuild when that slice
/// changes.

/// The current Supabase auth session (null when signed out).
final authStateProvider = Provider<Session?>(
  (ref) => ref.watch(sessionProvider).session,
);

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

/// True once both members are present in the couple.
final isPairedProvider = Provider<bool>(
  (ref) => ref.watch(sessionProvider).couple != null,
);

/// A short-lived invite code captured from a deep link (tethered://join?code=…),
/// consumed by the pairing screen to pre-fill the join field.
final pendingInviteCodeProvider = StateProvider<String?>((ref) => null);

/// The selected bottom-nav tab index in the AppShell (0 = Home). A provider so
/// the Home screen's quick actions can switch tabs (e.g. open Chat).
final shellTabProvider = StateProvider<int>((ref) => 0);
