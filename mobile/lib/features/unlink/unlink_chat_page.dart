import 'package:flutter/material.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/features/chat/chat_screen.dart';

/// Chat, on its own, for the partner who did not start the unlinking.
///
/// The shell owns the Scaffold for every room in the app, so ChatScreen has
/// none of its own and cannot simply be routed to. This is the smallest thing
/// that makes it standable-alone: the same screen, a Scaffold, and a way back
/// to the ritual.
///
/// Reachable ONLY through `unlinkAllows`, which grants it to the partner and
/// refuses it to the initiator. Nothing else about chat changes — the same
/// widget, the same realtime, the same keys.
class UnlinkChatPage extends StatelessWidget {
  const UnlinkChatPage({super.key});

  @override
  Widget build(BuildContext context) {
    return EmberBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          // Not "Chat". The person reading this arrived here from a screen
          // that told them their partner needs space; naming the room after
          // what it is FOR is the whole reason the door is open.
          title: Text('Talk to them', style: MilesType.fraunces(fontSize: 18)),
        ),
        body: const SafeArea(top: false, child: ChatScreen()),
      ),
    );
  }
}
