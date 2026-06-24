import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/providers.dart';
import 'package:miles/core/services/presence_service.dart';

/// Bottom-nav tab labels, indexed by [shellTabProvider].
const List<String> kTabScreens = [
  'Home',
  'Chat',
  'Reunion',
  'Sky',
  'Breath',
  'Closer',
];

/// Tell the partner which feature/section this user is in.
void reportScreen(WidgetRef ref, String? name) {
  final couple = ref.read(currentCoupleProvider);
  if (couple != null) PresenceService.setScreen(couple.id, name);
}

/// Re-report the active bottom-nav tab — used when a pushed screen closes.
void reportActiveTab(WidgetRef ref) {
  final i = ref.read(shellTabProvider).clamp(0, kTabScreens.length - 1);
  reportScreen(ref, kTabScreens[i]);
}
