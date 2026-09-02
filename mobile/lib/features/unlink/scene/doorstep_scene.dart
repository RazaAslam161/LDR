import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:miles/core/services/server_clock.dart';
import 'package:miles/core/services/sound/cue.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/unlink/scene/conversation.dart';
import 'package:miles/features/unlink/scene/film_library.dart';
import 'package:miles/features/unlink/scene/scene_assets.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';
import 'package:miles/features/unlink/unlink_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

/// Where each stage's action object sits — image fractions, read off grids
/// over the shipped stills. Mapped through the SAME cover math the painter
/// uses, or the objects drift off their spots as the crop changes with the
/// screen aspect.
enum _StageGeom {
  outM(
    actionAt: Offset(0.315, 0.44), photo: false,
    companionAt: Offset(0.70, 0.21),
    characterAt: Offset(0.51, 0.49),
    lampAt: Offset(0.67, 0.26),
    slamAt: 1.05,
  ),
  outF(
    actionAt: Offset(0.755, 0.50), photo: false,
    companionAt: Offset(0.365, 0.25),
    characterAt: Offset(0.645, 0.46),
    lampAt: Offset(0.365, 0.36),
    slamAt: 2.10,
  ),
  inM(
    actionAt: Offset(0.145, 0.615), photo: true,
    companionAt: Offset(0.333, 0.47),
    characterAt: Offset(0.594, 0.33),
    lampAt: Offset(0.13, 0.30),
    slamAt: 0.15,
  ),
  inF(
    actionAt: Offset(0.145, 0.635), photo: true,
    companionAt: Offset(0.375, 0.45),
    characterAt: Offset(0.625, 0.32),
    lampAt: Offset(0.20, 0.24),
    slamAt: 0.15,
  );

  const _StageGeom({
    required this.actionAt,
    required this.photo,
    required this.companionAt,
    required this.characterAt,
    required this.lampAt,
    required this.slamAt,
  });

  /// Where the companion's head is, and where the character's is — image
  /// fractions read off the four shipped stages at 480x853. The talk hangs
  /// off THESE, not off the bottom of the screen: a chat log pinned to the
  /// lower third is two people texting over a photograph, which is exactly
  /// what it looked like on the handset. A bubble at the bird's beak and a
  /// bubble at the character's head is a conversation.
  final Offset companionAt;
  final Offset characterAt;

  /// The dominant warm source, for the glow that breathes on it.
  final Offset lampAt;

  /// Seconds into this stage's intro film at which the door is shut —
  /// measured frame by frame off the shipped clips, not guessed, because a
  /// slam heard half a second late is worse than a silent one.
  final double slamAt;

  final Offset actionAt;

  /// True: the action object is the framed photo. False: the key.
  final bool photo;

  static _StageGeom of(SceneRole role, PuppetVariant v) =>
      switch ((role, v)) {
        (SceneRole.outside, PuppetVariant.female) => outF,
        (SceneRole.outside, _) => outM,
        (SceneRole.inside, PuppetVariant.female) => inF,
        (SceneRole.inside, _) => inM,
      };
}

/// The Doorstep, Act II — the owner's story: the slam already happened, and
/// now somebody is sitting with what they did while a small creature keeps
/// them company through the window before the way back opens.
///
/// The initiator gets the porch: their character by the door, the bird on the
/// lamp. The partner gets the room: their character by the sofa, the cat.
/// The conversation each companion holds is paced by `conversation.dart`'s
/// pure arithmetic against the row's own gate timestamp, so the talk, the
/// countdown and the rising button can never disagree — and closing the app
/// mid-sentence loses nothing, because nothing is stored.
///
/// Poses are the RESTORED standing set for now (worried/calm); the sitting,
/// sofa, cat and extra bird poses swap in when the owner's generation batch
/// passes intake. The cat until then is a drawn silhouette — the same
/// placeholder law the touch map uses for an unset avatar.
class DoorstepScene extends StatefulWidget {
  const DoorstepScene({
    required this.row,
    required this.role,
    required this.variant,
    this.talkBottomInset = 12,
    this.talkAvoid,
    this.onAction,
    this.actionArmed = false,
    this.phoneGlow = false,
    this.actionTorn = false,
    this.phoneLine,
    super.key,
  });

  /// The stage's ONE diegetic control — the owner's symbols:
  ///  * OUTSIDE, a brass key appears by the door when the way back opens.
  ///    Using the key is coming home; the tap plays the reunion.
  ///  * INSIDE, the framed photo of the two of them on the side table
  ///    becomes touchable when the partner's gate opens. Tearing the photo
  ///    is agreeing to end it — a thing nobody does by accident, which is
  ///    exactly the weight that action must carry.
  /// Null [onAction] or a false [actionArmed] and the object is scenery.
  final VoidCallback? onAction;
  final bool actionArmed;

  /// A text from them landed in the last few seconds. The phone bubble
  /// breathes while this holds, so a message found a second late is
  /// still obviously the new thing on the stage.
  final bool phoneGlow;

  /// The photo's after-state: the halves. Flashed by the screen for a breath
  /// between the confirm and the parting, so the act is SEEN, not implied.
  final bool actionTorn;

  /// The latest message from the other phone, shown in the scene as their
  /// text arriving — a phone bubble, visually distinct from the companion's
  /// spoken lines. Null shows nothing.
  final String? phoneLine;

  final UnlinkRow row;
  final SceneRole role;
  final PuppetVariant variant;

  /// Height reserved under the conversation stack, so the talk lands above
  /// whatever the screen parks on the stage's lower edge.
  final double talkBottomInset;

  /// A rectangle of chrome the talk must not run under, in widget space —
  /// today the clock plate in the top corner. The plate paints AFTER the
  /// stage, so without this it simply covers whatever is speaking: the owner's
  /// handset showed the cat's line cut off mid-word behind it.
  final Rect? talkAvoid;

  /// Same contract the Doorstep and the Distance both honoured: no stage when
  /// animations are off or the text scale needs the room.
  static bool fits(BuildContext context) =>
      !MilesMotion.off(context) &&
      MediaQuery.textScalerOf(context).scale(1) < 1.3;

  @override
  State<DoorstepScene> createState() => _DoorstepSceneState();
}

class _DoorstepSceneState extends State<DoorstepScene>
    with TickerProviderStateMixin {
  Timer? _tick;
  final ValueNotifier<int> _clock = ValueNotifier(0);

  VideoPlayerController? _film;
  bool _filmDone = true;

  /// The stage's own pulse. A held still is a photograph, and a photograph
  /// with text on it is what the ceremony looked like on a real handset —
  /// "a stuck screen". This drives the slow camera drift, the lamp's
  /// breathing and the drifting night, so the scene is never once frozen.
  late final AnimationController _ambient;

  /// A line arriving. Words that blink into existence do not read as
  /// speech; words that rise and settle do.
  late final AnimationController _enter;

  /// The key, or the photo, coming into the world at the gate.
  late final AnimationController _gate;

  /// The newest line already announced — so a line is spoken once, and
  /// reopening the app mid-conversation does not fire a burst of chirps for
  /// everything said while it was closed.
  String? _spoken;
  bool _slamFired = false;
  bool _wasArmed = false;

  late final Listenable _repaint;

  /// Once per CEREMONY per device, latched BEFORE the first frame plays —
  /// the law the Opening established: if the process dies mid-film, the film
  /// is spent, and nobody is ever made to wait out a clip they have seen.
  /// Keyed on started_at so a new ceremony gets its own single showing.
  String get _latchKey =>
      'doorstep_intro_${widget.row.startedAt.millisecondsSinceEpoch}_'
      '${widget.role.name}';

  @override
  void initState() {
    super.initState();
    unawaited(SceneArt.ensureLoaded().then((_) {
      if (mounted) _clock.value++;
    }).catchError((Object e) {
      // The stage is the ornament; the ceremony's words and buttons live in
      // the screen and survive any decode failure. Named, then stepped over.
      debugPrint('doorstep: art failed to decode, stage stays dark: $e');
    }),);
    final stagePath =
        FilmLibrary.stage(role: widget.role, me: widget.variant);
    if (stagePath != null) {
      unawaited(FilmLibrary.ensureStill(stagePath).then((_) {
        if (mounted) _clock.value++;
      }),);
    }
    // The action objects and clock bodies ride the same still cache — decoded
    // here or they exist only as their drawn stand-ins forever.
    for (final p in [
      FilmLibrary.keyRelink,
      FilmLibrary.photoFrame,
      FilmLibrary.photoTorn,
      FilmLibrary.clockPorch,
      FilmLibrary.clockRoom,
    ]) {
      unawaited(FilmLibrary.ensureStill(p).then((_) {
        if (mounted) _clock.value++;
      }),);
    }
    // A clock cadence, not motion: the conversation's truth is arithmetic on
    // ServerClock — this tick only asks the widget to LOOK again. One second
    // matches the countdown's own cadence elsewhere on the screen.
    _ambient = AnimationController(vsync: this, duration: MilesMotion.sceneLoop);
    _enter = AnimationController(vsync: this, duration: MilesMotion.spokenWord);
    _gate = AnimationController(vsync: this, duration: MilesMotion.reveal);
    _repaint = Listenable.merge([_clock, _ambient, _enter, _gate]);
    // Night air under the whole ceremony. The scene shipped in total silence
    // — no bed, no cue, nothing — and silence is what the owner heard first.
    unawaited(MilesSound.startBed());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) _clock.value++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePlayIntro());
  }

  Future<void> _maybePlayIntro() async {
    if (!mounted) return;
    // Reduce-motion never sees a film — same as it never sees the stage.
    if (MilesMotion.off(context)) return;
    final path = FilmLibrary.intro(role: widget.role, me: widget.variant);
    if (path == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_latchKey) ?? false) return;
    // Latched BEFORE playback — see _latchKey.
    await prefs.setBool(_latchKey, true);
    if (!mounted) return;
    final c = VideoPlayerController.asset(path);
    try {
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      c.addListener(_watchFilmEnd);
      await c.play();
      setState(() {
        _film = c;
        _filmDone = false;
      });
    } catch (e) {
      // OpeningScreen's hardened path, same shape: recover first, dispose
      // never awaited — a throwing dispose once stranded a user on black
      // and must not get a second chance here.
      debugPrint('doorstep: intro failed to play, stage stands: $e');
      unawaited(c.dispose().catchError((Object _) {}));
    }
  }

  void _watchFilmEnd() {
    final c = _film;
    if (c == null || !c.value.isInitialized) return;
    // The door. Fired off the film's OWN playhead rather than a timer, so it
    // cannot drift from the picture on a phone that stutters mid-clip. The
    // films carry no audio track — every sound in this ceremony is a cue, so
    // mute and the server's sound-kill keep working.
    final geom = _StageGeom.of(widget.role, widget.variant);
    if (!_slamFired &&
        c.value.position.inMilliseconds >= (geom.slamAt * 1000).round()) {
      _slamFired = true;
      MilesSound.cue(Cue.seal);
    }
    if (c.value.position >= c.value.duration && !c.value.isPlaying) {
      _endFilm();
    }
  }

  /// Ends the film and RELEASES the controller: the stage that follows is a
  /// decoded still, so nothing keeps a video decoder warm for a 24-hour
  /// ceremony.
  void _endFilm() {
    final c = _film;
    if (c == null) return;
    setState(() {
      _film = null;
      _filmDone = true;
    });
    c.removeListener(_watchFilmEnd);
    unawaited(c.dispose().catchError((Object _) {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    _ambient.dispose();
    _enter.dispose();
    _gate.dispose();
    unawaited(MilesSound.stopBed());
    _clock.dispose();
    _film?.removeListener(_watchFilmEnd);
    _film?.dispose();
    super.dispose();
  }

  ({List<Exchange> lines, String? late, Speaker? pending, int? ageMs})
      _talk() {
    final row = widget.row;
    final outside = widget.role == SceneRole.outside;
    final gateAt = outside ? row.relinkOpensAt : row.partnerGateOpensAt;
    final window = gateAt.difference(row.startedAt);
    final elapsed = ServerClock.now().difference(row.startedAt);
    final script = outside ? birdScript : catScript;
    if (elapsed <= window) {
      final said =
          visibleExchanges(script,
              elapsed: elapsed, window: window, within: spokenLinger,);
      return (
        lines: said,
        late: null,
        pending: pendingSpeaker(script, elapsed: elapsed, window: window),
        ageMs: said.isEmpty
            ? null
            : elapsed.inMilliseconds -
                (said.last.at * window.inMilliseconds).round(),
      );
    }
    return (
      lines: const [],
      late: companionshipLine(
        outside ? birdCompanionship : catCompanionship,
        sinceGate: elapsed - window,
      ),
      pending: null,
      ageMs: null,
    );
  }

  /// A line arriving gets a voice and a movement. Run AFTER the frame, never
  /// during build: firing a controller mid-build is how a scene starts
  /// throwing instead of speaking.
  void _announce(String? newest, {required bool companion, int? ageMs}) {
    if (!mounted || newest == _spoken) return;
    final firstSight = _spoken == null;
    _spoken = newest;
    if (newest == null) return;
    _enter.forward(from: 0);
    // Only speak what was JUST said. Reopening at minute twelve replays two
    // lines of history on screen, and history must arrive silently.
    final fresh = ageMs != null && ageMs.abs() <= 8000;
    if (fresh && !firstSight) {
      MilesSound.cue(companion ? Cue.chime : Cue.tap);
    }
  }

  /// How long the gate has been open, in seconds. Negative before it opens.
  /// Arithmetic on the row like everything else here, so closing the app and
  /// coming back does not re-run the hint.
  int _sinceGateSeconds() {
    final gate = widget.role == SceneRole.outside
        ? widget.row.relinkOpensAt
        : widget.row.partnerGateOpensAt;
    return ServerClock.now().difference(gate).inSeconds;
  }

  void _armGate({required bool armed}) {
    if (!mounted || armed == _wasArmed) return;
    _wasArmed = armed;
    if (!armed) return;
    // The gate opening is the loudest moment in the ceremony and it happened
    // in silence, with an object appearing in a still: the owner watched it
    // and could not tell anything had changed.
    _gate.forward(from: 0);
    MilesSound.cue(Cue.unlock);
  }

  @override
  Widget build(BuildContext context) {
    final model = SceneModel.of(
      widget.row,
      role: widget.role,
      slamPlayed: true,
    );
    return AnimatedBuilder(
              animation: _repaint,
              builder: (context, _) {
                final talk = _talk();
                final film = _film;
                final stagePath = FilmLibrary.stage(
                  role: widget.role,
                  me: widget.variant,
                );
                final still =
                    stagePath == null ? null : FilmLibrary.still(stagePath);
                final geom = _StageGeom.of(widget.role, widget.variant);
                return LayoutBuilder(
                  builder: (context, box) {
                    final canvas = box.biggest;
                    Offset? mapPoint(Offset frac) =>
                        _mapPoint(still, canvas, frac);

                    final armed = widget.actionArmed &&
                        widget.onAction != null &&
                        _filmDone;
                    final actionC = armed ? mapPoint(geom.actionAt) : null;
                    final motionOff = MilesMotion.off(context);

                    // Everything that must happen because of this frame, run
                    // after it. Sound and controllers during build is how a
                    // scene throws instead of playing.
                    final newest = talk.late ??
                        (talk.lines.isEmpty ? null : talk.lines.last.line);
                    final fromCompanion = talk.late != null ||
                        (talk.lines.isNotEmpty &&
                            talk.lines.last.speaker == Speaker.companion);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      if (!motionOff && !_ambient.isAnimating) _ambient.repeat();
                      if (motionOff && _ambient.isAnimating) _ambient.stop();
                      _announce(newest,
                          companion: fromCompanion, ageMs: talk.ageMs,);
                      _armGate(armed: armed);
                    });

                    // The camera never quite holds still. A 1% drift over
                    // eight seconds is below the threshold of "something is
                    // moving" and above the threshold of "this is a photo" —
                    // which is the whole difference the owner reported. It
                    // stops dead under the film, whose own camera is moving,
                    // and under reduce-motion.
                    final drifting = _filmDone && !motionOff;
                    final theta = _ambient.value * 2 * math.pi;
                    final zoom =
                        drifting ? 1.004 + 0.009 * (1 - math.cos(theta)) / 2 : 1.0;
                    final dx = drifting ? 5.0 * math.sin(theta) : 0.0;
                    final dy = drifting ? 3.5 * math.sin(theta * 0.5) : 0.0;
                    final glowPulse = motionOff
                        ? 0.75
                        : 0.62 +
                            0.24 * (0.5 + 0.5 * math.sin(theta * 3.1)) +
                            0.14 * (0.5 + 0.5 * math.sin(theta * 7.7 + 1.9));

                    return Transform.translate(
                      offset: Offset(dx, dy),
                      child: Transform.scale(
                      scale: zoom,
                      child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CustomPaint(
                      painter: _StagePainter(
                        role: widget.role,
                        variant: widget.variant,
                        dawn: model.dawn,
                        still: still,
                        actionAt: actionC,
                        actionIsPhoto: geom.photo,
                        torn: widget.actionTorn,
                        glowAt: mapPoint(geom.lampAt),
                        glowPulse: glowPulse,
                        arrive: motionOff ? 1.0 : _gate.value,
                      ),
                    ),
                    // WHAT THE OBJECT IS. It arrived as a small picture in
                    // a still frame with no sound and no words, and the owner
                    // watched the gate open without knowing anything had
                    // happened. The hint is diegetic, brief, and timed off
                    // the gate itself, so it says its piece and leaves.
                    if (actionC != null && _sinceGateSeconds() < 30)
                      Positioned(
                        left: 12,
                        right: 12,
                        top: actionC.dy + canvas.shortestSide * 0.10,
                        child: Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              // scrim over the stage — one line of guidance
                              // has to survive lamplight behind it.
                              color: MilesColors.nightDeep
                                  .withValues(alpha: 0.66),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 6,),
                              child: Text(
                                geom.photo
                                    ? 'Tear it, and you agree.'
                                    : 'The door still opens.',
                                style: MilesType.inter(
                                  fontSize: 12,
                                  color: MilesColors.gilt,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (actionC != null)
                      Positioned(
                        left: actionC.dx - 30,
                        top: actionC.dy - 30,
                        width: 60,
                        height: 60,
                        child: Semantics(
                          button: true,
                          label: geom.photo
                              ? 'I need space too'
                              : 'Open the door',
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: widget.onAction,
                          ),
                        ),
                      ),
                    // The talk waits for the film: bubbles over a slamming
                    // door would be two scenes fighting for one stage.
                    if (_filmDone)
                      _TalkLayer(
                        lines: talk.lines,
                        lateLine: talk.late,
                        phoneLine: widget.phoneLine,
                        pending: talk.pending,
                        companionAt: mapPoint(geom.companionAt),
                        characterAt: mapPoint(geom.characterAt),
                        canvas: canvas,
                        bottomInset: widget.talkBottomInset,
                        avoid: widget.talkAvoid,
                        enter: motionOff ? 1.0 : _enter.value,
                        pulse: motionOff ? 1.0 : _ambient.value,
                        phoneGlow: widget.phoneGlow && !motionOff,
                      ),
                    if (film != null && film.value.isInitialized) ...[
                      FittedBox(
                        fit: BoxFit.cover,
                        clipBehavior: Clip.hardEdge,
                        child: SizedBox(
                          width: film.value.size.width,
                          height: film.value.size.height,
                          child: VideoPlayer(film),
                        ),
                      ),
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Semantics(
                          button: true,
                          label: 'Skip',
                          child: TextButton(
                            onPressed: _endFilm,
                            child: Text(
                              'Skip',
                              style: MilesType.inter(
                                fontSize: 12,
                                color: MilesColors.cream50
                                    .withValues(alpha: 0.8),
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                      ),
                      ),
                    );
                  },
                );
              },
    );
  }
}

/// An image fraction to a widget point, through the SAME cover fit the
/// painter draws with. Every anchored thing on this stage — the key, the
/// photo, the lamp's glow, both speakers' words — goes through here, so a
/// change of screen aspect moves all of them together or none of them.
Offset? _mapPoint(ui.Image? still, Size canvas, Offset frac) {
  if (still == null) return null;
  final iw = still.width.toDouble();
  final ih = still.height.toDouble();
  final scale = canvas.width / iw > canvas.height / ih
      ? canvas.width / iw
      : canvas.height / ih;
  return Offset(
    (canvas.width - iw * scale) / 2 + frac.dx * iw * scale,
    (canvas.height - ih * scale) / 2 + frac.dy * ih * scale,
  );
}

/// The talk, hung on the people having it.
///
/// The first build of this was a chat log pinned to the bottom of the screen:
/// companion left, character right, newest at the floor. On a handset that
/// reads as a messaging app laid over a photograph — the owner's words were
/// "some overlay of some chat on a stuck screen", and they were right. A
/// conversation is legible as one only when the words are attached to the
/// mouths making them, so each side's lines hang off that speaker's own head:
/// the bird's at the lamp, the character's at their shoulder, tail pointing
/// home. A head near the top of the frame hangs its words below it; a head
/// low in the frame stacks them above.
class _TalkLayer extends StatelessWidget {
  const _TalkLayer({
    required this.lines,
    required this.lateLine,
    required this.phoneLine,
    required this.pending,
    required this.companionAt,
    required this.characterAt,
    required this.canvas,
    required this.bottomInset,
    required this.enter,
    required this.pulse,
    this.avoid,
    this.phoneGlow = false,
  });

  /// Chrome the words must not run under. See [DoorstepScene.talkAvoid].
  final Rect? avoid;

  final bool phoneGlow;

  final List<Exchange> lines;
  final String? lateLine;
  final String? phoneLine;

  /// Who is a few seconds from speaking. Three dots at their head is the
  /// difference between a silence and a stall.
  final Speaker? pending;

  final Offset? companionAt;
  final Offset? characterAt;
  final Size canvas;
  final double bottomInset;
  final double enter;
  final double pulse;

  @override
  Widget build(BuildContext context) {
    final all = <({Speaker who, String line, bool phone})>[
      for (final e in lines) (who: e.speaker, line: e.line, phone: false),
      if (lateLine != null)
        (who: Speaker.companion, line: lateLine!, phone: false),
      // Their real text, last and always: a living person outranks a script.
      if (phoneLine != null)
        (who: Speaker.character, line: phoneLine!, phone: true),
    ];
    if (all.isEmpty && pending == null) return const SizedBox.shrink();
    final newestWho = all.isEmpty ? null : all.last.who;

    // Without a decoded stage there is no measured head to speak from; the
    // drawn fallback gets the same layout off plain fractions.
    final cAt =
        companionAt ?? Offset(canvas.width * 0.30, canvas.height * 0.34);
    final kAt =
        characterAt ?? Offset(canvas.width * 0.62, canvas.height * 0.52);

    // Each speaker's words go on the side of their head FACING AWAY from the
    // other speaker, which is what keeps two columns from meeting in the
    // middle of the stage. The first cut placed them by absolute height and
    // the inside stages — where the cat's head and the character's are barely
    // a hundred points apart — piled one bubble straight through the other.
    final companionHigher = cAt.dy < kAt.dy;
    return Stack(
      children: [
        ..._column(Speaker.companion, cAt, all, newestWho,
            below: !companionHigher,),
        ..._column(Speaker.character, kAt, all, newestWho,
            below: companionHigher,),
      ],
    );
  }

  List<Widget> _column(
    Speaker who,
    Offset at,
    List<({Speaker who, String line, bool phone})> all,
    Speaker? newestWho, {
    required bool below,
  }) {
    final mine = [for (final e in all) if (e.who == who) e];
    final dots = pending == who;
    if (mine.isEmpty && !dots) return const [];

    // ONE thing said per person. Stacking a speaker's history under their own
    // head rebuilt the chat log a bubble at a time and put three overlapping
    // panels on a 500-point stage. What a conversation actually shows is the
    // last thing each of them said — which, with two speakers, is two
    // bubbles: a dialogue.
    final latest = mine.isEmpty ? null : mine.last;

    final companion = who == Speaker.companion;
    var width = math.min(canvas.width * 0.62, _maxTalkWidth);
    final rightward = at.dx <= canvas.width / 2;

    // Pushed away from the other speaker, unless that walks off the frame.
    var hangs = below;
    if (!hangs && at.dy - 24 - _talkRoom < 8) hangs = true;
    if (hangs && at.dy + 24 + _talkRoom > canvas.height - bottomInset) {
      hangs = false;
    }

    // The band this column will occupy once it has laid itself out. Only an
    // estimate — the text has not been measured yet — but _talkRoom is the
    // same figure the side-choice above trusts, and it only has to be right
    // enough to know whether the chrome is in the way.
    final top = hangs ? at.dy + 24 : at.dy - 24 - _talkRoom;
    final bottom = hangs ? at.dy + 24 + _talkRoom : at.dy - 24;
    final box = avoid;
    // Narrow, never move: a bubble slid out from under its own speaker is a
    // worse lie than a short one. If there is no room left to be a sentence,
    // the words go to the other side of the plate instead.
    var maxRight = canvas.width - 10;
    if (box != null && bottom > box.top && top < box.bottom) {
      maxRight = math.min(maxRight, box.left - 8);
    }

    final rawLeft = rightward ? at.dx - 18 : at.dx + 18 - width;
    var left = rawLeft.clamp(10.0, math.max(10.0, canvas.width - width - 10))
        .toDouble();
    if (left + width > maxRight) {
      if (maxRight - left >= _minTalkWidth) {
        width = maxRight - left;
      } else {
        left = math.max(10, maxRight - width);
        if (left + width > maxRight) width = math.max(_minTalkWidth, maxRight - left);
      }
    }

    final parts = <Widget>[
      if (latest != null)
        _Bubble(
          text: latest.line,
          companion: companion,
          phone: latest.phone,
          glow: latest.phone && phoneGlow ? pulse : null,
          tail: !(dots && hangs),
          tailUp: hangs,
          tailRight: !rightward,
          enter: who == newestWho ? enter : 1.0,
        ),
      if (dots)
        _Dots(companion: companion, pulse: pulse, tailRight: !rightward),
    ];

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          rightward ? CrossAxisAlignment.start : CrossAxisAlignment.end,
      children: hangs ? parts.reversed.toList() : parts,
    );

    return [
      if (hangs)
        Positioned(left: left, top: at.dy + 24, width: width, child: column)
      else
        Positioned(
          left: left,
          width: width,
          bottom: math.max(bottomInset + 8, canvas.height - (at.dy - 24)),
          child: column,
        ),
    ];
  }
}

/// Wide enough for a sentence, narrow enough that a bubble never spans the
/// stage and becomes a banner again.
const _maxTalkWidth = 264.0;

/// Head-room a bubble is assumed to need when deciding which side of a head
/// it can live on. Two or three lines of 13pt with its padding and tail.
const _talkRoom = 92.0;

/// Below this a bubble stops being a sentence and becomes a column of
/// syllables, so the words move out from under the chrome instead of
/// shrinking any further.
const _minTalkWidth = 120.0;

/// One spoken thing. Gilt edge and starlight for the companion, cream for the
/// character's own voice, ember for a real message off their phone.
class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.text,
    required this.companion,
    required this.phone,
    required this.glow,
    required this.tail,
    required this.tailUp,
    required this.tailRight,
    required this.enter,
  });

  final String text;
  final bool companion;
  final bool phone;

  /// The ambient phase while this bubble is a freshly-landed text, else null.
  final double? glow;

  final bool tail;
  final bool tailUp;
  final bool tailRight;
  final double enter;

  @override
  Widget build(BuildContext context) {
    const alpha = 1.0;
    final edge = phone
        ? MilesColors.ember
        : companion
            ? MilesColors.gilt
            : MilesColors.cream50;
    final ink = companion ? MilesColors.starlight : MilesColors.cream100;
    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        // scrim over the stage — the words sit on the art itself, and the
        // 0.72 floor is what keeps them readable over lamplight.
        color: MilesColors.nightDeep.withValues(alpha: 0.72 * alpha),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: edge.withValues(
            alpha: (phone ? 0.55 : 0.28) * alpha +
                (glow == null
                    ? 0
                    : 0.4 * (0.5 + 0.5 * math.sin(glow! * 6 * math.pi))),
          ),
          width: glow == null ? 1 : 1.4,
        ),
      ),
      child: Text(
        text,
        style: MilesType.inter(
          fontSize: 13,
          height: 1.3,
          color: ink,
          decoration: TextDecoration.none,
        ),
      ),
    );
    final tailBit = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: CustomPaint(
        size: const Size(13, 7),
        painter: _Tail(
          up: tailUp,
          color: MilesColors.nightDeep.withValues(alpha: 0.72 * alpha),
        ),
      ),
    );
    // Words rise into place. A line that simply exists on the next frame
    // reads as a caption; a line that arrives reads as speech.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Opacity(
        opacity: enter.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, (1 - enter) * MilesMotion.rise * 0.6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: tailRight
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (tail && tailUp) tailBit,
              body,
              if (tail && !tailUp) tailBit,
            ],
          ),
        ),
      ),
    );
  }
}

/// Someone is about to speak. Rides the ambient phase, so it breathes on both
/// phones on the same second without owning a controller of its own.
class _Dots extends StatelessWidget {
  const _Dots({
    required this.companion,
    required this.pulse,
    required this.tailRight,
  });

  final bool companion;
  final double pulse;
  final bool tailRight;

  @override
  Widget build(BuildContext context) {
    final tint = companion ? MilesColors.gilt : MilesColors.cream50;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: tailRight ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            // scrim over the stage — same floor as the bubbles it precedes.
            color: MilesColors.nightDeep.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2.5),
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: tint.withValues(
                        alpha: 0.25 +
                            0.55 *
                                (0.5 +
                                    0.5 *
                                        math.sin(
                                          pulse * 4 * math.pi - i * 0.9,
                                        )),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tail extends CustomPainter {
  const _Tail({required this.up, required this.color});

  final bool up;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (up) {
      path
        ..moveTo(size.width / 2, 0)
        ..lineTo(0, size.height)
        ..lineTo(size.width, size.height);
    } else {
      path
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width / 2, size.height);
    }
    canvas.drawPath(path..close(), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_Tail old) => old.up != up || old.color != color;
}

/// Preview seams: the stage owns a live clock and ServerClock cannot be moved
/// by a golden, so previews drive the painter and the stack at chosen moments.
@visibleForTesting
CustomPainter stagePainterForTest({
  required SceneRole role,
  required PuppetVariant variant,
  required double dawn,
  ui.Image? still,
}) =>
    _StagePainter(role: role, variant: variant, dawn: dawn, still: still);

@visibleForTesting
Widget conversationStackForTest({
  required List<Exchange> lines,
  required String? lateLine,
  required bool outside,
  String? phoneLine,
  Speaker? pending,
  Size canvas = const Size(360, 700),
  bool phoneGlow = false,
  PuppetVariant? variant,
  Rect? avoid,
}) {
  // Given a real stage, the preview hangs the talk exactly where the shipped
  // scene hangs it — through the same geometry and the same cover fit. Given
  // none, it falls back to the plain fractions the drawn stage uses.
  final role = outside ? SceneRole.outside : SceneRole.inside;
  final v = variant ?? PuppetVariant.male;
  final geom = _StageGeom.of(role, v);
  final still = FilmLibrary.still(FilmLibrary.stage(role: role, me: v) ?? '');
  return _TalkLayer(
    lines: lines,
    lateLine: lateLine,
    phoneLine: phoneLine,
    pending: pending,
    companionAt: variant == null
        ? Offset(canvas.width * 0.30, canvas.height * 0.30)
        : _mapPoint(still, canvas, geom.companionAt),
    characterAt: variant == null
        ? Offset(canvas.width * 0.62, canvas.height * 0.52)
        : _mapPoint(still, canvas, geom.characterAt),
    canvas: canvas,
    bottomInset: 0,
    enter: 1,
    pulse: 0.5,
    phoneGlow: phoneGlow,
    avoid: avoid,
  );
}

class _StagePainter extends CustomPainter {
  const _StagePainter({
    required this.role,
    required this.variant,
    required this.dawn,
    this.still,
    this.actionAt,
    this.actionIsPhoto = false,
    this.torn = false,
    this.glowAt,
    this.glowPulse = 0.75,
    this.arrive = 1,
  });

  /// The stage's warm source, pre-mapped like [actionAt]. A lamp that never
  /// wavers is the tell that a scene is a photograph.
  final Offset? glowAt;
  final double glowPulse;

  /// 0 to 1 as the key, or the photo, comes into the world. The gate opening
  /// used to be a silent pop in a still frame — nothing announced the single
  /// most important moment in the ceremony.
  final double arrive;

  final bool torn;

  /// Widget-space point for the armed action object, pre-mapped by the scene
  /// through the cover fit. Null = nothing armed, nothing drawn.
  final Offset? actionAt;
  final bool actionIsPhoto;

  final SceneRole role;
  final PuppetVariant variant;
  final double dawn;

  /// The film's own held last frame. When present it IS the stage — the
  /// painted composite below survives as the fallback for a missing still,
  /// a neutral-gender profile, and decode failure.
  final ui.Image? still;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = MilesColors.night);
    final held = still;
    if (held != null) {
      _cover(canvas, size, held);
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..color = MilesColors.nightDeep.withValues(alpha: 0.28 * dawn),
      );
      final lamp = glowAt;
      if (lamp != null) {
        final r = size.shortestSide * 0.42;
        canvas.drawCircle(
          lamp,
          r,
          Paint()
            ..blendMode = BlendMode.plus
            ..shader = ui.Gradient.radial(lamp, r, [
              MilesColors.gilt.withValues(alpha: 0.085 * glowPulse),
              MilesColors.ember.withValues(alpha: 0.035 * glowPulse),
              MilesColors.gilt.withValues(alpha: 0),
            ], const [0.0, 0.45, 1.0],),
        );
      }
      final at = actionAt;
      if (at != null) {
        // The owner's 3D object when it has shipped; the drawn stand-in
        // otherwise. The glow stays code either way — it is state, not art.
        final asset = FilmLibrary.still(
          actionIsPhoto
              ? (torn ? FilmLibrary.photoTorn : FilmLibrary.photoFrame)
              : FilmLibrary.keyRelink,
        );
        final a = arrive.clamp(0.0, 1.0);
        if (asset != null) {
          final h = size.shortestSide *
              (actionIsPhoto ? 0.16 : 0.14) *
              (0.7 + 0.3 * a);
          // The glint overshoots on arrival and settles: the eye is drawn to
          // change, and the gate is the one moment that must not be missed.
          canvas.drawCircle(
            at,
            h * 0.75 * (1 + 0.9 * (1 - a)),
            Paint()
              ..shader = ui.Gradient.radial(
                at,
                h * 0.75 * (1 + 0.9 * (1 - a)),
                [
                  MilesColors.gilt.withValues(
                    alpha: (actionIsPhoto ? 0.25 : 0.5) * (0.4 + 0.6 * a),
                  ),
                  MilesColors.gilt.withValues(alpha: 0),
                ],
              ),
          );
          final w = h * asset.width / asset.height;
          canvas.drawImageRect(
            asset,
            Rect.fromLTWH(
              0,
              0,
              asset.width.toDouble(),
              asset.height.toDouble(),
            ),
            Rect.fromCenter(center: at, width: w, height: h),
            Paint()..filterQuality = FilterQuality.medium,
          );
        } else if (actionIsPhoto) {
          _drawPhoto(canvas, at, size.shortestSide * 0.055);
        } else {
          _drawKey(canvas, at, size.shortestSide * 0.05);
        }
      }
      return;
    }
    if (!SceneArt.ready) return;
    final outside = role == SceneRole.outside;

    _cover(canvas, size, outside ? SceneArt.backdropOut! : SceneArt.backdropIn!);

    if (outside) {
      // The lamp on the right, the bird up on it — the perch the whole
      // conversation happens from.
      final lamp = SceneArt.lamp!;
      _sprite(canvas, size, lamp, feetX: 0.84, feetY: 0.94, height: 0.42);
      _sprite(canvas, size, SceneArt.bird!,
          feetX: 0.845, feetY: 0.545, height: 0.075, mirror: true,);
    }

    final figure = SceneArt.charFor(variant, CharMood.worried);
    if (figure != null) {
      _sprite(
        canvas, size, figure,
        // Outside: BESIDE the doorway (its span is x .362-.612), not inside
        // its darkness — standing in the doorway read as never having left.
        feetX: outside ? 0.27 : 0.42,
        feetY: 0.94,
        height: 0.34,
      );
    }

    if (!outside) _placeholderCat(canvas, size);

    // The night wearing on: the same dawn value the countdown reads.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = MilesColors.nightDeep.withValues(alpha: 0.28 * dawn),
    );
  }

  void _cover(Canvas canvas, Size size, ui.Image img) {
    final scale = size.width / img.width > size.height / img.height
        ? size.width / img.width
        : size.height / img.height;
    final w = img.width * scale;
    final h = img.height * scale;
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH((size.width - w) / 2, (size.height - h) / 2, w, h),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  void _sprite(
    Canvas canvas,
    Size size,
    ui.Image img, {
    required double feetX,
    required double feetY,
    required double height,
    bool mirror = false,
  }) {
    final h = size.height * height;
    final w = h * img.width / img.height;
    final cx = size.width * feetX;
    final ground = size.height * feetY;
    if (mirror) {
      canvas
        ..save()
        ..translate(cx, 0)
        ..scale(-1, 1)
        ..translate(-cx, 0);
    }
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(cx - w / 2, ground - h, w, h),
      Paint()..filterQuality = FilterQuality.medium,
    );
    if (mirror) canvas.restore();
  }

  /// The key, drawn until the owner's 3D body arrives: bow, shaft, two
  /// teeth, hanging by the door in a pool of warm light. The way home should
  /// look inviting — this is the one control the app WANTS pressed.
  void _drawKey(Canvas canvas, Offset at, double s) {
    canvas.drawCircle(
      at,
      s * 1.7,
      Paint()
        ..shader = ui.Gradient.radial(
          at,
          s * 1.7,
          [
            MilesColors.gilt.withValues(alpha: 0.50),
            MilesColors.gilt.withValues(alpha: 0),
          ],
        ),
    );
    final brass = Paint()
      ..color = const Color(0xFFD9B472)
      ..strokeWidth = s * 0.28
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas
      ..drawCircle(Offset(at.dx - s * 0.55, at.dy), s * 0.42, brass)
      ..drawLine(
        Offset(at.dx - s * 0.13, at.dy),
        Offset(at.dx + s * 0.95, at.dy),
        brass,
      )
      ..drawLine(
        Offset(at.dx + s * 0.60, at.dy),
        Offset(at.dx + s * 0.60, at.dy + s * 0.38),
        brass,
      )
      ..drawLine(
        Offset(at.dx + s * 0.95, at.dy),
        Offset(at.dx + s * 0.95, at.dy + s * 0.50),
        brass,
      );
  }

  /// The framed photo of the two of them, drawn until the owner's asset
  /// arrives: a small frame on the side table, glowing only faintly. Tearing
  /// it is the agreement — the object must read as PRECIOUS, not as a
  /// button, which is why its light is half the key's.
  void _drawPhoto(Canvas canvas, Offset at, double s) {
    canvas.drawCircle(
      at,
      s * 1.5,
      Paint()
        ..shader = ui.Gradient.radial(
          at,
          s * 1.5,
          [
            MilesColors.gilt.withValues(alpha: 0.25),
            MilesColors.gilt.withValues(alpha: 0),
          ],
        ),
    );
    final frame = Rect.fromCenter(
      center: at,
      width: s * 1.7,
      height: s * 2.1,
    );
    canvas
      ..drawRRect(
        RRect.fromRectAndRadius(frame, Radius.circular(s * 0.14)),
        Paint()..color = const Color(0xFF5A4030),
      )
      ..drawRect(
        frame.deflate(s * 0.22),
        Paint()..color = MilesColors.cream100.withValues(alpha: 0.9),
      )
      // Two small heads close together — the photo is OF them.
      ..drawCircle(
        Offset(at.dx - s * 0.28, at.dy - s * 0.1),
        s * 0.22,
        Paint()..color = const Color(0xFF6B4A38),
      )
      ..drawCircle(
        Offset(at.dx + s * 0.24, at.dy - s * 0.05),
        s * 0.26,
        Paint()..color = const Color(0xFF4A3328),
      );
  }

  /// The cat, until the real one arrives from the owner's batch: a curled
  /// silhouette beside the character. Deliberately quiet — a placeholder that
  /// tried to be a cat would read as a defect; a shape that suggests one
  /// reads as dusk.
  void _placeholderCat(Canvas canvas, Size size) {
    final cx = size.width * 0.58;
    final cy = size.height * 0.925;
    final r = size.height * 0.030;
    final body = Paint()..color = const Color(0xFF2E2027);
    canvas
      ..drawOval(
        Rect.fromCenter(
          center: Offset(cx, cy),
          width: r * 3.1,
          height: r * 1.6,
        ),
        body,
      )
      ..drawCircle(Offset(cx + r * 1.25, cy - r * 0.55), r * 0.72, body)
      // Ears: two small triangles, the one thing that says "cat".
      ..drawPath(
        Path()
          ..moveTo(cx + r * 0.85, cy - r * 1.05)
          ..lineTo(cx + r * 1.05, cy - r * 1.6)
          ..lineTo(cx + r * 1.30, cy - r * 1.1)
          ..close()
          ..moveTo(cx + r * 1.45, cy - r * 1.15)
          ..lineTo(cx + r * 1.70, cy - r * 1.62)
          ..lineTo(cx + r * 1.85, cy - r * 1.02)
          ..close(),
        body,
      );
  }

  @override
  bool shouldRepaint(_StagePainter old) =>
      old.role != role ||
      old.variant != variant ||
      old.dawn != dawn ||
      old.actionAt != actionAt ||
      old.torn != torn ||
      old.glowPulse != glowPulse ||
      old.arrive != arrive ||
      old.glowAt != glowAt ||
      !identical(old.still, still);
}
