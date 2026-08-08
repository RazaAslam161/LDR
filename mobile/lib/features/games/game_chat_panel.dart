import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/content_language.dart';
import 'package:miles/core/realtime_service.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';

/// A compact, real-time answer strip embedded in every game. Both partners type
/// here and see each other's answers live (ephemeral broadcast — it's in-game
/// banter, not saved chat). Each game gets its own channel via [gameKey].
class GameChatPanel extends ConsumerStatefulWidget {
  const GameChatPanel({
    super.key,
    required this.coupleId,
    required this.gameKey,
  });

  final String coupleId;
  final String gameKey;

  @override
  ConsumerState<GameChatPanel> createState() => _GameChatPanelState();
}

class _GameMsg {
  _GameMsg(this.fromMe, this.text);
  final bool fromMe;
  final String text;
}

class _GameChatPanelState extends ConsumerState<GameChatPanel> {
  ManagedSubscription? _ch;
  final _msgs = <_GameMsg>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  String? _myUid;
  String _myName = 'Me';

  @override
  void initState() {
    super.initState();
    final s = ref.read(sessionProvider);
    _myUid = s.profile?.id;
    _myName = s.profile?.displayName ?? 'Me';
    _ch = ManagedSubscription.start(() => SupabaseService.client
        .channel('gchat:${widget.gameKey}:${widget.coupleId}')
        .onBroadcast(event: 'msg', callback: _onMsg)
        .subscribe());
  }

  @override
  void dispose() {
    _ch?.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onMsg(Map<String, dynamic> payload) {
    if (payload['from'] == _myUid || !mounted) return;
    setState(
        () => _msgs.add(_GameMsg(false, payload['text']?.toString() ?? '')));
    _scrollDown();
  }

  void _send() {
    final t = _input.text.trim();
    if (t.isEmpty) return;
    setState(() => _msgs.add(_GameMsg(true, t)));
    _ch?.channel?.sendBroadcastMessage(
      event: 'msg',
      payload: {'from': _myUid, 'name': _myName, 'text': t},
    );
    _input.clear();
    _scrollDown();
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: MilesColors.surface1,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MilesColors.gilt.withValues(alpha: 0.12)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 84,
            child: _msgs.isEmpty
                ? const Center(
                    child: Text('Yahaan ek dusre ko jawab do — live 💬',
                        style:
                            TextStyle(color: MilesColors.taupe, fontSize: 12)),
                  )
                : ListView.builder(
                    controller: _scroll,
                    itemCount: _msgs.length,
                    itemBuilder: (_, i) => _bubble(_msgs[i]),
                  ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  style:
                      const TextStyle(color: MilesColors.cream50, fontSize: 14),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: ref.watch(contentLanguageProvider) ==
                            ContentLanguage.english
                        ? 'Type your answer…'
                        : 'Apna jawab likho…',
                    hintStyle:
                        const TextStyle(color: MilesColors.taupe, fontSize: 13),
                    filled: true,
                    fillColor: MilesColors.surface2,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send_rounded, color: MilesColors.blush),
                onPressed: _send,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bubble(_GameMsg m) {
    return Align(
      alignment: m.fromMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        constraints: const BoxConstraints(maxWidth: 250),
        decoration: BoxDecoration(
          color: m.fromMe
              ? MilesColors.blush.withValues(alpha: 0.25)
              : MilesColors.surface2,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(m.text,
            style: const TextStyle(color: MilesColors.cream50, fontSize: 13)),
      ),
    );
  }
}
