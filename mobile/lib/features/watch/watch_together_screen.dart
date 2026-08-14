import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/core/services/server_clock.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';
import 'package:miles/features/shell/app_drawer.dart';
import 'package:miles/features/watch/watch_protocol.dart';
import 'package:miles/features/watch/watch_source.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';


/// Watch & listen together — paste any video link. YouTube plays inline;
/// anything else opens in the browser on both phones. Play, pause and seek stay
/// synced via a broadcast channel: whoever touches the controls drives, the
/// other follows.
class WatchTogetherScreen extends ConsumerStatefulWidget {
  const WatchTogetherScreen({super.key});

  @override
  ConsumerState<WatchTogetherScreen> createState() =>
      _WatchTogetherScreenState();
}

/// Nothing in youtube_player_flutter ever times out: if the iframe API never
/// calls back, isReady stays false forever and every command is silently
/// dropped. This is the bound that makes that state visible.
const Duration kReadyTimeout = Duration(seconds: 8);

/// How long a command may still be echoed back by the player. A backstop, not
/// the mechanism: a command whose echo never arrives must not gag real
/// gestures forever.
const Duration kEchoWindow = Duration(milliseconds: 1500);

class _WatchTogetherScreenState extends ConsumerState<WatchTogetherScreen> {
  YoutubePlayerController? _controller;
  ManagedSubscription? _channel;
  final _urlInput = TextEditingController();
  String? _coupleId;
  String? _myUid;
  String? _videoId;
  Timer? _heartbeat;

  /// Per-sender counter. Identity for every intent this device emits.
  int _seq = 0;

  /// The highest seq seen from the partner, so a duplicated or reordered
  /// delivery is dropped by identity rather than by a wall-clock window.
  int _peerSeq = -1;

  /// Who is driving. Null until anybody acts.
  String? _leader;
  int _leaderSeq = -1;

  bool get _isLeader => _leader != null && _leader == _myUid;

  /// True for the synchronous duration of a command we issue ourselves.
  ///
  /// Only covers the call itself. The state change it provokes lands later and
  /// is matched by [_isEcho] instead — see [_applyLocal] for why a flag alone
  /// was never enough.
  bool _applying = false;

  bool _lastPlaying = false;
  int _lastPosMs = 0;

  /// The follower's held correction — playback is paused until this passes.
  DateTime? _holdUntil;

  /// When the partner last told us anything, for stall detection.
  DateTime? _heardAt;
  bool _peerStalled = false;

  /// A load that arrived before the player could accept it.
  String? _pendingId;
  Duration _pendingStart = Duration.zero;

  /// Non-null when playback is impossible and we owe the user a sentence.
  String? _fault;

  /// A link we cannot play inline, held so the card can offer the browser.
  WatchSource? _handoff;

  Timer? _watchdog;

  /// What we last commanded the player to do, so its echo is recognised by
  /// identity rather than by a stopwatch. See [_applyLocal].
  int? _expectPosMs;
  bool? _expectPlaying;
  DateTime? _expectUntil;

  bool get _isFollowerHeld => _holdUntil != null && !_isLeader;

  @override
  void initState() {
    super.initState();
    _bind(ref.read(sessionProvider));
    _heartbeat = Timer.periodic(kBeatInterval, (_) => _tick());
  }

  /// Subscribe once the couple is known, and re-subscribe if it changes.
  ///
  /// The old build read the session once in initState. On a cold start the
  /// couple resolves asynchronously, so opening this screen first meant
  /// _coupleId was null, the channel was never created, and the screen sat
  /// there looking healthy and synchronising with nobody — permanently, and
  /// with nothing on screen to say so.
  void _bind(SessionState session) {
    final couple = session.couple?.id;
    _myUid = session.profile?.id;
    if (couple == null || couple == _coupleId) return;
    _coupleId = couple;
    _channel?.dispose();
    _channel = ManagedSubscription.start(() => SupabaseService.client
        .channel('watch:$couple', opts: RealtimeChannelConfig(private: true))
        .onBroadcast(event: 'watch', callback: _onMsg)
        .subscribe(),);
    // Ask what is already playing rather than announcing position zero.
    _send(WatchIntent.hello);
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    _watchdog?.cancel();
    _channel?.dispose();
    _controller?.dispose();
    _urlInput.dispose();
    super.dispose();
  }

  void _loadVideo(String id, {bool broadcast = true, Duration? startAt}) {
    _videoId = id;
    _fault = null;
    _pendingId = null;
    if (_controller == null) {
      _controller = YoutubePlayerController(
        initialVideoId: id,
        // autoPlay:false is deliberate and is the whole reason the spinner can
        // no longer be permanent. The package hides its play button behind
        // `!flags.autoPlay || state == playing || state == paused`, so with
        // autoPlay on, a video that never reaches a playing state leaves a bare
        // progress wheel and NOTHING to tap. Off, the button appears the moment
        // the player is ready — and _onReady below still starts playback, so
        // nothing is lost.
        //
        // hideThumbnail closes an Image.network to i3.ytimg.com issued by the
        // app's own HTTP stack, outside the webview: an unencrypted disclosure
        // of what the couple is watching, from an app built around a disguise.
        flags: YoutubePlayerFlags(
          autoPlay: false,
          hideThumbnail: true,
          startAt: (startAt ?? Duration.zero).inSeconds,
        ),
      )..addListener(_onControllerChange);
      setState(() {});
    } else if (_controller!.value.isReady) {
      _controller!.load(id, startAt: (startAt ?? Duration.zero).inSeconds);
    } else {
      // load() routes through _callMethod, which silently drops every call
      // before the player is ready. The old code advanced _videoId and told the
      // partner about a video it had just thrown away — permanent, unsignalled
      // desync. Hold it and drain on ready instead.
      _pendingId = id;
      _pendingStart = startAt ?? Duration.zero;
    }
    _armWatchdog();
    if (broadcast) {
      _takeLead();
      _send(WatchIntent.load);
    }
  }

  /// Nothing in the package times out, so a video that never becomes ready
  /// spins for as long as the user is willing to stare at it. This is what
  /// turns that into a sentence and a way out.
  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(kReadyTimeout, () {
      if (!mounted) return;
      if (_controller?.value.isReady ?? false) return;
      setState(() => _fault = "This video won't start. It may be blocked from "
          'playing outside YouTube, or private.');
    });
  }

  void _onReady() {
    _watchdog?.cancel();
    final queued = _pendingId;
    if (queued != null) {
      _pendingId = null;
      _controller?.load(queued, startAt: _pendingStart.inSeconds);
      _pendingStart = Duration.zero;
    }
    // autoPlay is off so the button exists; playback still starts by itself.
    if (!_isFollowerHeld) _controller?.play();
  }

  /// Paste the clipboard link and play it (robust against the paste menu not
  /// showing on some keyboards).
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    _urlInput.text = text;
    _accept(text);
  }

  void _onUrlSubmit() => _accept(_urlInput.text);

  /// One entry point for every link, however it arrived.
  void _accept(String text) {
    final source = resolveWatchLink(text);
    if (source == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("That doesn't look like a link.")),
      );
      return;
    }

    _urlInput.clear();
    if (mounted) FocusScope.of(context).unfocus();

    switch (source.kind) {
      case WatchKind.youtube:
        setState(() => _handoff = null);
        _loadVideo(source.key, startAt: source.startAt);
      case WatchKind.media:
      case WatchKind.handoff:
      case WatchKind.blocked:
        // Not playable in the YouTube surface. Say which it is and why, rather
        // than rejecting the paste as invalid — he pasted it for a reason.
        setState(() {
          _handoff = source;
          _fault = null;
        });
    }
  }

  Future<void> _openInBrowser(WatchSource source) async {
    final uri = Uri.tryParse(source.key);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Run a command we issued ourselves, and remember what we asked for.
  ///
  /// The old guard was a bool set and cleared in the same synchronous turn,
  /// while the state change it was guarding arrives asynchronously — so it was
  /// already false when the listener fired and the follower re-broadcast the
  /// leader's own instruction back at it, taking the lead in the process. The
  /// two phones then fought each other for control.
  ///
  /// Matching on the EXPECTED STATE rather than on a timer is what avoids the
  /// original sin here too: a 600ms window both swallowed real gestures inside
  /// it and let stale ones through outside it. An echo is recognised because it
  /// is what we asked for, not because it arrived quickly.
  void _applyLocal(void Function() command, {int? expectPosMs, bool? playing}) {
    _applying = true;
    command();
    _applying = false;
    _expectPosMs = expectPosMs;
    _expectPlaying = playing;
    _expectUntil = DateTime.now().add(kEchoWindow);
  }

  /// True when [pos]/[playing] is the echo of a command we just issued.
  bool _isEcho(int pos, bool playing) {
    final until = _expectUntil;
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _expectUntil = null;
      return false;
    }
    final wantPlaying = _expectPlaying;
    if (wantPlaying != null && wantPlaying != playing) return false;
    final wantPos = _expectPosMs;
    if (wantPos != null && (pos - wantPos).abs() > kNudgeMs) return false;
    // Consumed: a second, genuinely new gesture must not be swallowed too.
    _expectUntil = null;
    return true;
  }

  /// A local gesture. Anything the USER did makes this device the leader.
  void _onControllerChange() {
    final c = _controller;
    if (c == null || _applying) return;
    final playing = c.value.isPlaying;
    final pos = c.value.position.inMilliseconds;

    if (_isEcho(pos, playing)) {
      _lastPlaying = playing;
      _lastPosMs = pos;
      return;
    }

    if (playing != _lastPlaying) {
      _lastPlaying = playing;
      _lastPosMs = pos;
      _takeLead();
      _send(playing ? WatchIntent.play : WatchIntent.pause);
      return;
    }

    // A seek shows up as position moving further than wall-clock time could
    // account for. The old build watched isPlaying only, so dragging the
    // scrubber transmitted NOTHING and the two phones simply parted company —
    // while a footer told the user seeking stayed in sync.
    final expected = _lastPosMs + (playing ? kBeatInterval.inMilliseconds : 0);
    if ((pos - expected).abs() > kSeekMs) {
      _lastPosMs = pos;
      _takeLead();
      _send(WatchIntent.seek);
      return;
    }
    _lastPosMs = pos;
  }

  void _takeLead() {
    _leader = _myUid;
    _leaderSeq = _seq + 1;
  }

  /// Emit one intent.
  void _send(WatchIntent intent) {
    final c = _controller;
    final msg = WatchMessage(
      intent: intent,
      from: _myUid ?? '',
      seq: ++_seq,
      // The shared clock, so the other side can work out where this puts it by
      // the time it arrives. DateTime.now() would be this handset's own idea of
      // the time, and these two have been measured seconds apart.
      atMs: ServerClock.now().millisecondsSinceEpoch,
      videoId: _videoId,
      posMs: c?.value.position.inMilliseconds ?? 0,
      playing: c?.value.isPlaying ?? false,
      leader: _leader,
    );
    _channel?.channel
        ?.sendBroadcastMessage(event: 'watch', payload: msg.toJson());
  }

  /// The periodic tick: the leader reports, the follower corrects.
  void _tick() {
    final c = _controller;
    if (c == null || _videoId == null) return;

    // Released BEFORE the leader branch, not after it. A follower that paused
    // itself to shed drift and then became the leader — by the user pressing
    // play, which is exactly when it happens — skipped this release forever and
    // sat paused with nothing left to start it again.
    final hold = _holdUntil;
    if (hold != null && !DateTime.now().isBefore(hold)) {
      _holdUntil = null;
      if (_lastPlaying) _applyLocal(() => c.play());
    }

    if (_isLeader) {
      _send(WatchIntent.beat);
      return;
    }

    // Still inside a correction: nothing else to do until it expires.
    if (_holdUntil != null) return;

    // The partner has gone quiet mid-playback.
    final heard = _heardAt;
    if (heard != null &&
        _lastPlaying &&
        DateTime.now().difference(heard) > kStallAfter) {
      if (!_peerStalled && mounted) setState(() => _peerStalled = true);
    }
  }

  void _onMsg(Map<String, dynamic> payload) {
    if (!mounted) return;
    final msg = WatchMessage.fromJson(payload);
    if (msg.from.isEmpty || msg.from == _myUid) return;
    // Identity, not a timer. A duplicate or a reordered delivery is dropped
    // because it is old, not because it arrived inside some window.
    if (msg.seq <= _peerSeq) return;
    _peerSeq = msg.seq;
    _heardAt = DateTime.now();
    if (_peerStalled) setState(() => _peerStalled = false);

    // Someone asking what is on. Only the leader answers, and only with what
    // is actually loaded — a newcomer must never be able to reset the film.
    if (msg.intent == WatchIntent.hello) {
      if (_isLeader && _videoId != null) _send(WatchIntent.beat);
      return;
    }

    // Whoever acted most recently drives. Both sides run the same comparison
    // on the same numbers, so they cannot disagree about who that is.
    if (msg.intent != WatchIntent.beat) {
      _leader = leaderBetween(
        a: _myUid ?? '',
        aSeq: _leaderSeq,
        b: msg.from,
        bSeq: msg.seq,
      );
      if (_leader == msg.from) _leaderSeq = msg.seq;
    }
    if (_isLeader && msg.intent == WatchIntent.beat) return;

    final id = msg.videoId;
    if (id != null && id != _videoId) {
      _applyLocal(() => _loadVideo(id, broadcast: false));
    }

    final c = _controller;
    if (c == null) return;

    // Each branch records what it asked the player for, so the state change it
    // provokes is recognised as our own echo when it arrives a beat later —
    // rather than being mistaken for the user reaching for the controls.
    switch (msg.intent) {
      case WatchIntent.pause:
        _lastPlaying = false;
        _applyLocal(
          () => c
            ..seekTo(Duration(milliseconds: msg.posMs))
            // seekTo() calls play() unconditionally in this package, so a pause
            // that seeks has to put it back down or the follower resumes on
            // every correction.
            ..pause(),
          expectPosMs: msg.posMs,
          playing: false,
        );
      case WatchIntent.play:
      case WatchIntent.seek:
      case WatchIntent.load:
        _lastPlaying = msg.playing;
        final target = msg.projectedPosMs();
        _applyLocal(
          () {
            c.seekTo(Duration(milliseconds: target));
            if (!msg.playing) c.pause();
          },
          expectPosMs: target,
          playing: msg.playing,
        );
      case WatchIntent.beat:
        _applyDrift(c, msg);
      case WatchIntent.stall:
        _lastPlaying = false;
        _applyLocal(c.pause, playing: false);
      case WatchIntent.ready:
        if (msg.playing) _applyLocal(c.play, playing: true);
      case WatchIntent.hello:
        break;
    }
  }

  /// The follower's correction, and the only place a correction happens.
  ///
  /// Positive drift means this device is AHEAD. Both sides correcting toward
  /// each other is a feedback loop — each acts on the other's stale position
  /// and reports a new one that makes the other act again.
  void _applyDrift(YoutubePlayerController c, WatchMessage msg) {
    if (!msg.playing || !c.value.isPlaying) return;
    final drift = c.value.position.inMilliseconds - msg.projectedPosMs();
    switch (correctionFor(drift)) {
      case WatchCorrection.none:
        break;
      case WatchCorrection.hold:
        // Shed the lead by standing still for exactly it. YouTube's IFrame API
        // rounds unsupported playback rates toward 1.0, so the rate-nudge every
        // other product uses is not available here; a micro-pause sheds the
        // same time and costs no rebuffer.
        if (drift > 0) {
          _applyLocal(c.pause, playing: false);
          _holdUntil =
              DateTime.now().add(Duration(milliseconds: drift.clamp(0, kSeekMs)));
        } else {
          final target = msg.projectedPosMs();
          _applyLocal(() => c.seekTo(Duration(milliseconds: target)),
              expectPosMs: target,);
        }
      case WatchCorrection.seek:
        final target = msg.projectedPosMs();
        _applyLocal(() => c.seekTo(Duration(milliseconds: target)),
            expectPosMs: target,);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Re-bind rather than reading the session once in initState: on a cold
    // start the couple resolves after this screen is already up.
    ref.listen<SessionState>(sessionProvider, (_, next) => _bind(next));
    final partnerName =
        ref.watch(sessionProvider).partner?.displayName ?? 'them';
    final controller = _controller;
    return Scaffold(
      backgroundColor: MilesColors.night,
      drawer: const AppDrawer(),
      appBar: AppBar(
        actions: const [PartnerHereAction()],
        title: const Text('Watch Together'),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlInput,
                    style: const TextStyle(color: MilesColors.cream50),
                    decoration: const InputDecoration(
                      hintText: 'Paste any video link…',
                      prefixIcon:
                          Icon(Icons.link, color: MilesColors.taupe, size: 20),
                    ),
                    onSubmitted: (_) => _onUrlSubmit(),
                  ),
                ),
                IconButton(
                  tooltip: 'Paste link',
                  icon: const Icon(Icons.content_paste,
                      color: MilesColors.emberSoft,),
                  onPressed: _paste,
                ),
                FilledButton(
                    onPressed: _onUrlSubmit, child: const Text('Play'),),
              ],
            ),
          ),
          if (_handoff != null)
            _LinkCard(
              source: _handoff!,
              onOpen: () => _openInBrowser(_handoff!),
              onDismiss: () => setState(() => _handoff = null),
            )
          else if (_fault != null)
            _LinkCard.fault(
              message: _fault!,
              onDismiss: () => setState(() {
                _fault = null;
                _controller?.dispose();
                _controller = null;
                _videoId = null;
              }),
            )
          else if (controller != null)
            YoutubePlayer(
              controller: controller,
              showVideoProgressIndicator: true,
              progressIndicatorColor: MilesColors.ember,
              onReady: _onReady,
            )
          else
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'Paste a YouTube link and press Play —\n'
                    'you and $partnerName watch it in sync.',
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(color: MilesColors.taupe, fontSize: 13),
                  ),
                ),
              ),
            ),
          if (controller != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  // Says who is driving, because with one leader that is a real
                  // thing the user can now be told. The old footer asserted
                  // that seeking stayed in sync while the code transmitted no
                  // seek at all.
                  Text(
                    _peerStalled
                        ? '$partnerName is buffering…'
                        : _leader == null
                            ? 'Press play — whoever plays first leads.'
                            : _isLeader
                                ? "You're driving. $partnerName follows."
                                : '$partnerName is driving.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: MilesColors.taupe, fontSize: 12,),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Play, pause and seek carry across. 🍿',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: MilesColors.faint, fontSize: 11),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// What the user sees instead of a spinner that never resolves.
///
/// Three cases share it: a link that plays somewhere else (hand-off), a link
/// nothing can play (DRM), and a video that failed to start. All three used to
/// be the same thing on screen — a wheel — and none of them told the user
/// anything or offered a way out.
class _LinkCard extends StatelessWidget {
  const _LinkCard({
    required this.source,
    required this.onOpen,
    required this.onDismiss,
  }) : message = null;

  const _LinkCard.fault({required String this.message, required this.onDismiss})
      : source = null,
        onOpen = null;

  final WatchSource? source;
  final String? message;
  final VoidCallback? onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final s = source;
    final canOpen = s != null && s.kind != WatchKind.blocked;
    return Expanded(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                s == null
                    ? Icons.error_outline
                    : s.kind == WatchKind.blocked
                        ? Icons.lock_outline
                        : Icons.open_in_new,
                color: MilesColors.taupe,
                size: 36,
              ),
              const SizedBox(height: 14),
              if (s?.site != null) ...[
                Text(
                  s!.site!,
                  style: const TextStyle(
                    color: MilesColors.cream50,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 6),
              ],
              Text(
                message ?? s?.reason ?? 'This link cannot be played here.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: MilesColors.taupe,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: onDismiss,
                    child: const Text('Try another link'),
                  ),
                  if (canOpen) ...[
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: onOpen,
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('Open in browser'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
