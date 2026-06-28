import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/providers.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';

/// Bottom-nav tab labels, indexed by [shellTabProvider]. Index 2 (Camera) is a
/// push button, not a persisted tab, but kept here so the indices line up.
const List<String> kTabScreens = [
  'Home',
  'Chat',
  'Camera',
  'Breath',
  'Closer',
];

/// Tell the partner which feature/section this user is in. Three layers:
/// 1) durable DB write (presence.current_screen, + app activity), 2) local
/// [myScreenProvider] so the "partner is here" badge knows our screen, and
/// 3) an instant broadcast so the partner sees us arrive within ~1s.
void reportScreen(WidgetRef ref, String? name) {
  final couple = ref.read(currentCoupleProvider);
  if (couple == null) return;
  PresenceService.setScreen(couple.id, name);
  ref.read(myScreenProvider.notifier).state = name;
  ref.read(partnerScreenProvider.notifier).announce(name);
}

/// Re-report the active bottom-nav tab — used when a pushed screen closes.
void reportActiveTab(WidgetRef ref) {
  final i = ref.read(shellTabProvider).clamp(0, kTabScreens.length - 1);
  reportScreen(ref, kTabScreens[i]);
}
