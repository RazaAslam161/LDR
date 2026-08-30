import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:miles/core/services/sound/cue.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/tilt_parallax.dart';
import 'package:miles/features/unlink/scene/bird.dart';
import 'package:miles/features/unlink/scene/character_puppet.dart';
import 'package:miles/features/unlink/scene/scene_assets.dart';
import 'package:miles/features/unlink/scene/scene_painters.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';
import 'package:miles/features/unlink/unlink_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Doorstep — the stage the ritual plays on.
///
/// One controller, EmberBackground's laws throughout: the ticker drives a
/// 24fps frame quantizer (`ValueNotifier<int>`), the painter repaints off
/// that notifier alone (`shouldRepaint => false`), sprites are baked once per
/// process, everything that moves is a transform, and `MilesMotion.off`
/// means the settled scene painted once with ZERO tickers. The screen above
/// this rebuilds at 1Hz for its clocks; the stage's shell rebuild is free
/// because paint is gated behind the RepaintBoundary and the notifier.
///
/// The stage NEVER uses `Expanded` — the layout law anchors on the file's
/// first `Expanded(` in unlink_screen.dart, and scenery is never allowed to
/// move a control. At large text scales the ritual's words need the room
/// more than the street does: past [collapseScale] the stage yields entirely
/// and the calm layout stands alone.
class RitualScene extends StatefulWidget {
  const RitualScene({
    required this.row,
    required this.role,
    required this.variant,
    required this.quoteText,
    required this.quoteAuthor,
    this.letterCard,
    super.key,
  });

  final UnlinkRow row;
  final SceneRole role;
  final PuppetVariant variant;
  final String quoteText;
  final String quoteAuthor;

  /// The partner's words, unfolded when the envelope on the doorstep is
  /// tapped. Built by the screen (it owns the note states and the measure
  /// law); the stage only stages it.
  final Widget? letterCard;

  /// Past this text scale the stage collapses: Re-link tappable on a 360x800
  /// phone at 2.0 scale outranks scenery, always.
  static const double collapseScale = 1.6;

  /// Whether the stage should render at all in this context.
  static bool fits(BuildContext context) =>
      !MilesMotion.off(context) &&
      MediaQuery.textScalerOf(context).scale(1) < collapseScale;

  @override
  State<RitualScene> createState() => _RitualSceneState();
}

class _RitualSceneState extends State<RitualScene>
    with SingleTickerProviderStateMixin {
  static const _fps = 24;

  AnimationController? _c;
  final _frame = ValueNotifier<int>(0);
  final _sceneFrame = SceneFrame();
  final _sequencer = BeatSequencer();

  /// The beat currently performing, with the loop-time it started at.
  SceneBeatEvent? _playing;
  double _beatT0 = 0;

  /// Monotonic seconds since the ticker started: whole laps of the loop plus
  /// the current fraction. The controller's value is the only clock the
  /// stage reads — never the wall clock, which the hygiene rules ban here.
  double _elapsed = 0;
  double _lastValue = 0;
  int _laps = 0;

  /// Once per ceremony, persisted: a cold start six hours in must open on
  /// the settled street, not a replay of the worst moment of the day.
  static const _slamLatchKey = 'miles_unlink_slam_v1';
  bool? _slamPlayed;

  /// The ceremony was seconds old when this stage mounted — so a slam is
  /// about to play, and the door must already be OPEN in the first painted
  /// frame. Read once at mount, never per frame: the stage's only clock is
  /// its controller.
  ///
  /// Without it the latch's async read costs a frame or two of the SETTLED
  /// street, and the leaf then pops open before it slams — a jump, on the
  /// first frame of the screen that matters most.
  late final bool _freshAtMount =
      DateTime.now().toUtc().difference(widget.row.startedAt).inSeconds < 45;

  /// The thought cloud, surfaced to the widget layer (the quote is real text
  /// — it must scale and it must obey the measure law). The cloud opens when
  /// this turns true; the WORDS arrive on [_spokenWords].
  final _bubbleVisible = ValueNotifier<bool>(false);

  /// How many words of the quote have been said so far. The speak beat walks
  /// this up one word per [MilesMotion.spokenWord]; a static block of text
  /// appearing at once is exactly what the owner asked this not to be.
  final _spokenWords = ValueNotifier<int>(0);

  late final List<String> _words = widget.quoteText.split(' ');

  /// -1 before the bird exists, 0..1 while arriving, 1 perched for good.
  double _birdFlight = -1;

  /// The envelope rests on the doorstep and can be tapped (widget layer needs
  /// it for the hit target, so it lives beside the painters' frame).
  final _letterResting = ValueNotifier<bool>(false);

  /// The letter, unfolded over the street.
  final _noteOpen = ValueNotifier<bool>(false);

  late final CustomPainter _painter = widget.role == SceneRole.outside
      ? DoorstepPainter(repaint: _frame, frame: _sceneFrame)
      : HearthPainter(repaint: _frame, frame: _sceneFrame);

  /// The current pose, the one it is fading from, and when the fade began —
  /// the crossfade the bitmap cast acts through.
  CharMood _mood = CharMood.worried;
  CharMood _moodPrev = CharMood.worried;
  double _moodT0 = -10;

  @override
  void initState() {
    super.initState();
    UnlinkState.current.addListener(_onRow);
    // The owner's art decodes once per process (~50ms from the bundle); the
    // painted world stands in until then, and this bump swaps the bitmaps in
    // even when animations are off and no ticker is running.
    unawaited(SceneArt.ensureLoaded().then((_) {
      if (mounted) _frame.value++;
    }).catchError((Object e) {
      // The painted world is the designed fallback; the failure still gets
      // named.
      debugPrint('unlink scene: art failed to decode, painted world stays: $e');
    }));
    _loadLatch();
  }

  Future<void> _loadLatch() async {
    final prefs = await SharedPreferences.getInstance();
    final key =
        '${widget.row.coupleId}|${widget.row.startedAt.toIso8601String()}';
    if (!mounted) return;
    setState(() => _slamPlayed = prefs.getString(_slamLatchKey) == key);
    _pushModel();
  }

  Future<void> _writeLatch() async {
    _slamPlayed = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _slamLatchKey,
      '${widget.row.coupleId}|${widget.row.startedAt.toIso8601String()}',
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final off = MilesMotion.off(context);
    if (off) {
      _c?.stop();
      // The finished state, one frame, zero tickers.
      _composeSettledFrame();
      _frame.value++;
      return;
    }
    if (_c == null) {
      _c = AnimationController(vsync: this, duration: MilesMotion.sceneLoop)
        ..addListener(_tick)
        ..repeat();
    } else if (!_c!.isAnimating) {
      _c!.repeat();
    }
  }

  void _onRow() {
    if (!mounted) return;
    _pushModel();
  }

  void _pushModel() {
    final row = UnlinkState.current.value ?? widget.row;
    final played = _slamPlayed;
    if (played == null) return; // latch still loading; first push follows it
    final model = SceneModel.of(
      row,
      role: widget.role,
      slamPlayed: played,
    );
    _sequencer.push(model);
  }

  /// The one clock. Advances the loop, performs the current beat, composes
  /// the frame the painters read, and bumps the quantizer only when the 24fps
  /// index moved — the EmberBackground frame cap, verbatim.
  void _tick() {
    final c = _c;
    if (c == null) return;
    if (c.value < _lastValue) _laps++;
    _lastValue = c.value;
    _elapsed =
        (_laps + c.value) * MilesMotion.sceneLoop.inMilliseconds / 1000;
    final loop = c.value;

    _playing ??= _startNextBeat();
    _compose(loop);

    final f = (loop * MilesMotion.sceneLoop.inSeconds * _fps).floor();
    if (f != _frame.value) {
      // Once a second, on the frame clock: re-derive the model so the
      // time-gated truths move without a row change — the handle glow at
      // +15m, dawn's slow walk. Pure recompute; the sequencer dedupes.
      if (f % _fps == 0) _pushModel();
      if (_letterResting.value != _sceneFrame.letterRest) {
        _letterResting.value = _sceneFrame.letterRest;
      }
      _frame.value = f;
    }
  }

  SceneBeatEvent? _startNextBeat() {
    final next = _sequencer.take();
    if (next == null) return null;
    _beatT0 = _now();
    switch (next.beat) {
      case SceneBeat.slam:
        MilesSound.cue(Cue.seal);
        unawaited(_writeLatch());
      case SceneBeat.speak:
        MilesSound.cue(Cue.chime);
      case SceneBeat.letter:
        MilesSound.cue(
          widget.role == SceneRole.outside ? Cue.receive : Cue.send,
        );
      case SceneBeat.bolt:
        MilesSound.cue(Cue.tap);
    }
    return next;
  }

  /// Monotonic seconds since mount, derived from the controller's laps.
  double _now() => _elapsed;

  /// How far into the playing beat we are, 0..1 against its token duration.
  double _beatProgress(Duration d) {
    final t = (_now() - _beatT0) / (d.inMilliseconds / 1000);
    return t.clamp(0.0, 1.0);
  }

  void _compose(double loop) {
    final model = _sequencer.model;
    final f = _sceneFrame
      ..loop = loop
      ..dawn = model?.dawn ?? 0
      ..handleGlow =
          ((model?.handleGlow ?? false) || (model?.gateOpen ?? false)) ? 1 : 0
      ..windowLit = 1
      ..lampFlicker = 1
      ..shake = Offset.zero
      // Steady bolt state: shut for the whole last call.
      ..bolt = model?.act == SceneAct.lastCall ? 1 : 0
      ..doorOpen = 0
      ..letterT = -1
      // The envelope rests on the doorstep whenever a letter exists —
      // including a cold start, where its ARRIVAL deliberately never
      // replays. Outside view only; inside, the letter went under the door.
      ..letterRest = model?.letterAt != null &&
          widget.role == SceneRole.outside &&
          _playing?.beat != SceneBeat.letter;

    // Held open until the latch answers — see [_freshAtMount].
    if (_slamPlayed == null && _freshAtMount) f.doorOpen = 0.7;

    // ── The pose. Outside: worry, glancing back at the door on the loop's
    // second half — until a letter exists, which softens them (somebody
    // reached out). Inside: calm shading to worried, holding the letter
    // while it slides, worried for the whole last call. Pose changes
    // crossfade on the quick token.
    final CharMood target;
    if (widget.role == SceneRole.outside) {
      target = _playing?.beat == SceneBeat.slam
          ? CharMood.worried
          : model?.letterAt != null
              ? CharMood.calm
              : loop < 0.5
                  ? CharMood.worried
                  : CharMood.glance;
    } else {
      target = _playing?.beat == SceneBeat.letter
          ? CharMood.letter
          : model?.act == SceneAct.lastCall
              ? CharMood.worried
              : loop < 0.5
                  ? CharMood.calm
                  : CharMood.worried;
    }
    if (target != _mood) {
      _moodPrev = _mood;
      _mood = target;
      _moodT0 = _now();
    }
    f
      ..mood = _mood
      ..moodPrev = _moodPrev
      ..moodFade = ((_now() - _moodT0) /
              (MilesMotion.quick.inMilliseconds / 1000))
          .clamp(0.0, 1.0);

    final playing = _playing;
    if (playing != null) {
      switch (playing.beat) {
        case SceneBeat.slam:
          final t = _beatProgress(MilesMotion.slam);
          // Door swings shut fast (open -> 0) on the strike curve, then the
          // shake and a lamp flicker ride the tail.
          final swing = 1 - MilesMotion.strike.transform(math.min(1, t * 1.6));
          f.doorOpen = swing * 0.7;
          if (t >= 0.6) {
            final st = ((t - 0.6) / 0.4).clamp(0.0, 1.0);
            final decay = 1 - st;
            f
              ..shake = Offset(
                math.sin(st * math.pi * 7) * 5 * decay,
                math.cos(st * math.pi * 5) * 3 * decay,
              )
              ..lampFlicker = 0.7 + 0.3 * st;
          }
          if (t >= 1) _endBeat();
        case SceneBeat.speak:
          // Fly in, land, THEN speak — the cloud belongs to the bird, and a
          // cloud with nobody under it is a caption.
          final flightSecs =
              MilesMotion.birdFlight.inMilliseconds / 1000;
          final wordSecs = MilesMotion.spokenWord.inMilliseconds / 1000;
          final elapsed = _now() - _beatT0;
          final fl = (elapsed / flightSecs).clamp(0.0, 1.0);
          _birdFlight = fl == 0 ? 0.001 : fl;
          if (fl >= 1) {
            _bubbleVisible.value = true;
            // +1: the first word lands WITH the cloud. Opening an empty
            // bubble and filling it a beat later reads as loading, and an
            // empty box on this screen has been rejected once already.
            final said = (1 + (elapsed - flightSecs) / wordSecs)
                .floor()
                .clamp(0, _words.length);
            if (said != _spokenWords.value) _spokenWords.value = said;
            if (said >= _words.length) _endBeat();
          }
        case SceneBeat.letter:
          final t = _beatProgress(MilesMotion.letterSlide);
          f.letterT = t;
          if (widget.role == SceneRole.outside) {
            // The door cracks just enough for an envelope, and settles as
            // the letter drifts to the doorstep.
            final crack = t < 0.35
                ? MilesMotion.enter.transform(t / 0.35)
                : t > 0.65
                    ? 1 - MilesMotion.enter.transform((t - 0.65) / 0.35)
                    : 1.0;
            f.doorOpen = 0.12 * crack;
          }
          if (t >= 1) _endBeat();
        case SceneBeat.bolt:
          final t = _beatProgress(MilesMotion.boltSlide);
          f.bolt = MilesMotion.strike.transform(t);
          if (t >= 1) _endBeat();
      }
    }
  }

  void _endBeat() {
    _playing = null;
  }

  /// The settled scene with every one-shot already finished — what `off()`
  /// and the collapsed states paint.
  void _composeSettledFrame() {
    _pushModel();
    // Drain the queue: with animations off there are no performances, and
    // the latch must still be written so turning animations ON later does
    // not replay the slam.
    for (var e = _sequencer.take(); e != null; e = _sequencer.take()) {
      if (e.beat == SceneBeat.slam) unawaited(_writeLatch());
    }
    _birdFlight = 1;
    _bubbleVisible.value = true;
    _spokenWords.value = _words.length;
    _compose(0.3); // one presentable mid-loop frame — the EmberBackground move
    _letterResting.value = _sceneFrame.letterRest;
  }

  @override
  void dispose() {
    UnlinkState.current.removeListener(_onRow);
    _c?.dispose();
    _frame.dispose();
    _bubbleVisible.dispose();
    _spokenWords.dispose();
    _letterResting.dispose();
    _noteOpen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The root ember field burns a vsync loop behind this fully opaque
    // screen for up to 24 hours; the stage is the one place that knows.
    return Stack(
      children: [
        const EmberBackgroundHidden(),
        AspectRatio(
          aspectRatio: 4 / 5,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: RepaintBoundary(
              child: ValueListenableBuilder<int>(
                valueListenable: _frame,
                builder: (context, _, child) => Transform.translate(
                  offset: _sceneFrame.shake,
                  child: child,
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const DecoratedBox(
                      decoration: BoxDecoration(color: MilesColors.nightDeep),
                    ),
                    // Depth off the accelerometer: the world leans against
                    // the tilt, the cast with it — a few pixels of disparity
                    // that read as a diorama. The 2% overscale hides the
                    // world's travel at the stage's edges.
                    TiltParallax(
                      depth: 3,
                      invert: true,
                      child: Transform.scale(
                        scale: 1.02,
                        child:
                            CustomPaint(painter: _painter, size: Size.infinite),
                      ),
                    ),
                    TiltParallax(
                      depth: 5,
                      child: _ActorLayer(
                        frame: _frame,
                        sceneFrame: _sceneFrame,
                        variant: widget.variant,
                        role: widget.role,
                        birdFlightOf: () => _birdFlight,
                      ),
                    ),
                    // The character's thought cloud: real text (measure law,
                    // user scale), anchored ABOVE the figure with a dot trail
                    // down toward their head, and SAID — the words arrive one
                    // at a time on the spokenWord cadence, because a quote
                    // that pops in whole is a poster, not a voice.
                    // Top-LEFT on the street — the one corner with nothing
                    // but sky, so the cloud can never cover the lamp or the
                    // bird saying it. Inside, right of the window for the
                    // same reason. The dot trail runs toward the speaker.
                    Align(
                      // Outside: the dark brick band between the lit window
                      // and the door's lintel — the LOOK found the old
                      // top-left spot sitting square on the window. Inside:
                      // the wall right of the window.
                      alignment: widget.role == SceneRole.outside
                          ? const Alignment(-0.85, -0.28)
                          : const Alignment(0.62, -0.46),
                      child: ValueListenableBuilder<bool>(
                        valueListenable: _bubbleVisible,
                        builder: (context, visible, child) => AnimatedScale(
                          scale: visible ? 1 : 0,
                          alignment: Alignment.bottomRight,
                          duration: MilesMotion.off(context)
                              ? Duration.zero
                              : MilesMotion.quick,
                          curve: MilesMotion.enter,
                          child: child,
                        ),
                        child: ValueListenableBuilder<int>(
                          valueListenable: _spokenWords,
                          builder: (context, said, _) => _ThoughtCloud(
                            words: _words,
                            said: said,
                            author: widget.quoteAuthor,
                            trailToward: widget.role == SceneRole.outside
                                ? _CloudTail.right   // toward the lamp bird
                                : _CloudTail.left, // toward the window bird
                          ),
                        ),
                      ),
                    ),
                    // The envelope's tap target: an invisible 44dp square
                    // over the doorstep, live only while the letter rests
                    // there. The painter draws; this listens.
                    if (widget.letterCard != null)
                      ValueListenableBuilder<bool>(
                        valueListenable: _letterResting,
                        builder: (context, resting, _) => resting
                            ? Align(
                                alignment: const Alignment(0.06, 0.86),
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    MilesSound.cue(Cue.tap);
                                    _noteOpen.value = true;
                                  },
                                  child: const SizedBox(
                                    width: 48,
                                    height: 44,
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    // The letter, unfolded: the screen's own note card,
                    // staged over the street. Tapping anywhere folds it
                    // away — the scene is still the room.
                    if (widget.letterCard != null)
                      ValueListenableBuilder<bool>(
                        valueListenable: _noteOpen,
                        builder: (context, open, child) => open
                            ? GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _noteOpen.value = false,
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: child,
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                        child: widget.letterCard,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The living things, painted over the world off the same frame notifier.
class _ActorLayer extends StatelessWidget {
  const _ActorLayer({
    required this.frame,
    required this.sceneFrame,
    required this.variant,
    required this.role,
    required this.birdFlightOf,
  });

  final ValueNotifier<int> frame;
  final SceneFrame sceneFrame;
  final PuppetVariant variant;
  final SceneRole role;
  final double Function() birdFlightOf;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _ActorPainter(
        repaint: frame,
        sceneFrame: sceneFrame,
        variant: variant,
        role: role,
        birdFlightOf: birdFlightOf,
      ),
      size: Size.infinite,
    );
  }
}

class _ActorPainter extends CustomPainter {
  _ActorPainter({
    required Listenable repaint,
    required this.sceneFrame,
    required this.variant,
    required this.role,
    required this.birdFlightOf,
  }) : super(repaint: repaint);

  final SceneFrame sceneFrame;
  final PuppetVariant variant;
  final SceneRole role;
  final double Function() birdFlightOf;

  @override
  void paint(Canvas canvas, Size size) {
    if (SceneArt.ready) {
      _paintCast(canvas, size);
      return;
    }
    _paintDrawn(canvas, size);
  }

  /// The owner's cast, over the bitmap world. The stills act through
  /// transforms: a breath on the spine, a slow sway, a crossfade whenever
  /// the mood changes — and the bird is mirrored on the street so it faces
  /// the person it is talking to.
  void _paintCast(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final loop = sceneFrame.loop;
    final outside = role == SceneRole.outside;

    // ── The bird, before the character so it sits behind them if they ever
    // overlap.
    final bf = birdFlightOf();
    if (bf >= 0) {
      final perch =
          outside ? SceneGeom.lampPerch(size) : SceneGeom.sillPerch(size);
      final bh = outside ? w * 0.095 : w * 0.080;
      Offset at;
      if (bf < 1) {
        final dir = outside ? 1.0 : -1.0;
        at = Offset(
          perch.dx + dir * bh * 4.5 * (1 - bf),
          perch.dy - bh * 2.2 * math.sin(bf * math.pi) + bh * 0.9 * (1 - bf),
        );
      } else {
        // Perched: the breath bob and the occasional hop, same life the
        // painted bird had.
        const hopStart = 0.72;
        const hopSpan = 0.06;
        final hop = (loop >= hopStart && loop <= hopStart + hopSpan)
            ? 0.35 * math.sin((loop - hopStart) / hopSpan * math.pi)
            : 0.0;
        at = perch +
            Offset(
              0,
              -bh * 0.04 * math.sin(loop * 2 * math.pi) - hop * bh * 0.3,
            );
      }
      // The sprite faces right; on the street it must face LEFT — toward
      // the door and the person on its step.
      _sprite(
        canvas,
        SceneArt.bird!,
        feet: at + Offset(0, bh * 0.5),
        height: bh,
        mirror: outside,
      );
    }

    // ── The character. Crossfade between moods; breathe and sway always.
    final img = SceneArt.charFor(variant, sceneFrame.mood);
    final feet =
        outside ? Offset(w * 0.665, h * 0.945) : Offset(w * 0.42, h * 0.93);
    final charH = outside ? h * 0.27 : h * 0.30;
    if (img == null) {
      // The neutral figure keeps the drawn silhouette — half a cast in
      // bitmaps beside a differently-styled stranger would be worse.
      _paintFigure(
        canvas,
        box: Rect.fromLTWH(
          feet.dx - w * 0.065,
          feet.dy - charH,
          w * 0.13,
          charH,
        ),
        loop: loop,
        lampSide: outside ? 1 : -1,
      );
    } else {
      final breathe = 1 + 0.012 * math.sin(loop * 4 * math.pi);
      final sway = 0.010 * math.sin(loop * 2 * math.pi);
      canvas
        ..save()
        ..translate(feet.dx, feet.dy)
        ..rotate(sway)
        ..scale(1, breathe)
        ..translate(-feet.dx, -feet.dy);
      final fade = sceneFrame.moodFade;
      if (fade < 1) {
        final prev = SceneArt.charFor(variant, sceneFrame.moodPrev);
        if (prev != null) {
          _sprite(canvas, prev, feet: feet, height: charH, alpha: 1 - fade);
        }
      }
      _sprite(canvas, img, feet: feet, height: charH, alpha: fade);
      canvas.restore();
    }

    // ── The letter, against the bitmap door's geometry: out through the
    // knob-side seam to the doorstep, or from the character's hand under
    // the door at the frame's right edge.
    final lt = sceneFrame.letterT;
    // On the top step, left of the character — the LOOK found the first
    // spot half-hidden against his leg.
    final rest = Offset(w * 0.53, h * 0.925);
    if (lt >= 0) {
      if (outside) {
        final from = Offset(w * 0.59, h * 0.915);
        final p = MilesMotion.enter.transform(lt);
        final at = Offset.lerp(from, rest, p)! -
            Offset(0, h * 0.035 * math.sin(p * math.pi));
        _paintEnvelope(canvas, w, at, rotation: (1 - p) * 0.5);
      } else {
        final from = Offset(w * 0.48, h * 0.88);
        final to = Offset(w * 0.945, h * 0.895);
        final p = MilesMotion.enter.transform(lt);
        final alpha = lt > 0.8 ? (1 - (lt - 0.8) / 0.2) : 1.0;
        _paintEnvelope(canvas, w, Offset.lerp(from, to, p)!, alpha: alpha);
      }
    } else if (sceneFrame.letterRest) {
      final breathe = 0.5 + 0.5 * math.sin(loop * 2 * math.pi);
      _paintEnvelope(canvas, w, rest, glow: 0.25 + 0.35 * breathe);
    }
  }

  /// Stamps one sprite standing on [feet], [height] tall, width from its own
  /// aspect. [alpha] rides the paint colour; [mirror] flips about the feet.
  void _sprite(
    Canvas canvas,
    ui.Image img, {
    required Offset feet,
    required double height,
    double alpha = 1,
    bool mirror = false,
  }) {
    final sw = height * img.width / img.height;
    if (mirror) {
      canvas
        ..save()
        ..translate(feet.dx, 0)
        ..scale(-1, 1)
        ..translate(-feet.dx, 0);
    }
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(feet.dx - sw / 2, feet.dy - height, sw, height),
      Paint()
        ..filterQuality = FilterQuality.low
        ..color = Colors.white.withValues(alpha: alpha),
    );
    if (mirror) canvas.restore();
  }

  /// The drawn puppet, boxed — shared by the pre-load frame and the neutral
  /// variant over the bitmap world.
  void _paintFigure(
    Canvas canvas, {
    required Rect box,
    required double loop,
    required double lampSide,
  }) {
    const poses = PuppetPose.worry;
    final seg = (loop * poses.length) % poses.length;
    final i = seg.floor() % poses.length;
    final j = (i + 1) % poses.length;
    final ft = MilesMotion.breathe.transform(seg - seg.floorToDouble());
    var pose = poses[i].lerpTo(poses[j], ft);
    final noise = math.sin(loop * 11 * math.pi) * 0.012;
    pose = pose.lerpTo(
      PuppetPose(lean: pose.lean + noise, headTilt: pose.headTilt - noise),
      0.5,
    );
    paintPuppet(
      canvas,
      box: box,
      pose: pose,
      build: PuppetBuild.of(variant),
      lampSide: lampSide,
    );
  }

  /// The pre-load world: the painted street's actors, exactly as before the
  /// owner's art arrived.
  void _paintDrawn(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final loop = sceneFrame.loop;

    final outside = role == SceneRole.outside;
    // The bird: absent until its beat, then flight in, then perch life. On
    // the lamp's crossarm outside; at the window sill, glass between you,
    // inside — arriving from the street side, which is the left. Sized to be
    // SEEN: the first cut was ~11px on a 344px stage and read as no bird at
    // all.
    final bf = birdFlightOf();
    if (bf >= 0) {
      BirdPainter.paint(
        canvas,
        perch: outside
            ? Offset(w * 0.750, h * 0.222)
            : Offset(w * 0.225, h * 0.445),
        size: outside ? w * 0.052 : w * 0.042,
        flight: bf,
        loop: loop,
        dir: outside ? 1 : -1,
      );
    }
    // Feet on the ground line, head below the door's lintel: a person is
    // smaller than their door, or the whole street reads as a toy. Inside,
    // they stand nearer the middle of the room, lit from the window.
    _paintFigure(
      canvas,
      box: outside
          ? Rect.fromLTWH(w * 0.54, h * 0.62, w * 0.13, h * 0.24)
          : Rect.fromLTWH(w * 0.40, h * 0.62, w * 0.13, h * 0.24),
      loop: loop,
      lampSide: outside ? 1 : -1,
    );

    // ── The letter.
    final lt = sceneFrame.letterT;
    final rest = Offset(w * 0.505, h * 0.845);
    if (lt >= 0) {
      if (role == SceneRole.outside) {
        // Out through the crack, a small arc down to the doorstep.
        final from = Offset(w * 0.405, h * 0.815);
        final p = MilesMotion.enter.transform(lt);
        final at = Offset.lerp(from, rest, p)! -
            Offset(0, h * 0.05 * math.sin(p * math.pi));
        _paintEnvelope(canvas, w, at, rotation: (1 - p) * 0.5);
      } else {
        // Slid from the character's side under the door, gone at the seam —
        // which sits right of frame in the hearth view.
        final from = Offset(w * 0.50, h * 0.845);
        final to = Offset(w * 0.655, h * 0.850);
        final p = MilesMotion.enter.transform(lt);
        final alpha = lt > 0.8 ? (1 - (lt - 0.8) / 0.2) : 1.0;
        _paintEnvelope(
          canvas,
          w,
          Offset.lerp(from, to, p)!,
          alpha: alpha,
        );
      }
    } else if (sceneFrame.letterRest) {
      // Resting on the doorstep, with a slow gilt breath inviting the tap.
      final breathe = 0.5 + 0.5 * math.sin(loop * 2 * math.pi);
      _paintEnvelope(canvas, w, rest, glow: 0.25 + 0.35 * breathe);
    }
  }

  /// A small cream envelope with a gilt flap — drawn, not baked: it is two
  /// rects and two lines, cheaper than the sprite lookup would be.
  void _paintEnvelope(
    Canvas canvas,
    double w,
    Offset center, {
    double rotation = 0,
    double alpha = 1,
    double glow = 0,
  }) {
    final env = SceneArt.envelope;
    final ew = env == null ? w * 0.062 : w * 0.095;
    final eh = env == null ? ew * 0.68 : ew * 270 / 360;
    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..rotate(rotation);
    final rect = Rect.fromCenter(center: Offset.zero, width: ew, height: eh);
    if (glow > 0) {
      canvas.drawOval(
        rect.inflate(ew * 0.28),
        Paint()
          ..shader = RadialGradient(
            colors: [
              MilesColors.gilt.withValues(alpha: 0.5 * glow),
              MilesColors.gilt.withValues(alpha: 0),
            ],
          ).createShader(rect.inflate(ew * 0.4)),
      );
    }
    if (env != null) {
      // The owner's envelope — wax seal and all; the glow behind it is the
      // same painted invitation.
      canvas.drawImageRect(
        env,
        Rect.fromLTWH(0, 0, env.width.toDouble(), env.height.toDouble()),
        rect,
        Paint()
          ..filterQuality = FilterQuality.low
          ..color = Colors.white.withValues(alpha: alpha),
      );
    } else {
      canvas
        ..drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(ew * 0.06)),
          Paint()..color = MilesColors.cream50.withValues(alpha: alpha),
        )
        ..drawLine(
          rect.topLeft,
          rect.center + Offset(0, eh * 0.12),
          Paint()
            ..color = MilesColors.gilt.withValues(alpha: alpha)
            ..strokeWidth = math.max(1, ew * 0.045),
        )
        ..drawLine(
          rect.topRight,
          rect.center + Offset(0, eh * 0.12),
          Paint()
            ..color = MilesColors.gilt.withValues(alpha: alpha)
            ..strokeWidth = math.max(1, ew * 0.045),
        );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ActorPainter oldDelegate) => false;
}

/// The quote, thought aloud.
///
/// A small cloud above the character, dot trail down toward their head, and
/// the words arriving one at a time. Unspoken words are laid out TRANSPARENT
/// rather than absent, so the cloud takes its final size on the first frame
/// and never resizes mid-sentence — a bubble that grows word by word reads
/// as loading, not speaking. The author fades in only once the last word has
/// been said.
enum _CloudTail { left, right }

class _ThoughtCloud extends StatelessWidget {
  const _ThoughtCloud({
    required this.words,
    required this.said,
    required this.author,
    required this.trailToward,
  });

  final List<String> words;
  final int said;
  final String author;
  final _CloudTail trailToward;

  @override
  Widget build(BuildContext context) {
    final done = said >= words.length;
    final spans = <TextSpan>[
      const TextSpan(text: '“'),
      for (var i = 0; i < words.length; i++)
        TextSpan(
          text: i == words.length - 1 ? words[i] : '${words[i]} ',
          style: TextStyle(
            color: i < said
                ? MilesColors.cream50
                : MilesColors.cream50.withValues(alpha: 0),
          ),
        ),
      TextSpan(
        text: '”',
        style: TextStyle(
          color: done
              ? MilesColors.cream50
              : MilesColors.cream50.withValues(alpha: 0),
        ),
      ),
    ];
    final trailRight = trailToward == _CloudTail.right;
    return Column(
      crossAxisAlignment:
          trailRight ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 158),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: MilesColors.surface1,
              // All corners generous: a thought cloud, not a chat bubble.
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: MilesColors.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                RichText(
                  text: TextSpan(
                    // TextDecoration.none: the root-Stack law — the stage can
                    // be mounted with no Material ancestor (the preview is),
                    // and text without one grows double yellow underlines.
                    style: MilesType.inter(
                      fontSize: 12,
                      height: 1.4,
                      fontStyle: FontStyle.italic,
                      color: MilesColors.cream50,
                    ).copyWith(decoration: TextDecoration.none),
                    children: spans,
                  ),
                ),
                const SizedBox(height: 4),
                AnimatedOpacity(
                  opacity: done ? 1 : 0,
                  duration: MilesMotion.off(context)
                      ? Duration.zero
                      : MilesMotion.quick,
                  child: Text(
                    author,
                    style: MilesType.inter(
                      color: MilesColors.faint,
                      fontSize: 10,
                      letterSpacing: 0.5,
                    ).copyWith(decoration: TextDecoration.none),
                  ),
                ),
              ],
            ),
          ),
        ),
        // The trail: two shrinking thought-dots stepping down toward the
        // character's head.
        Padding(
          padding: EdgeInsets.only(
            top: 3,
            left: trailRight ? 0 : 18,
            right: trailRight ? 18 : 0,
          ),
          child: _dot(7),
        ),
        Padding(
          padding: EdgeInsets.only(
            top: 3,
            left: trailRight ? 0 : 8,
            right: trailRight ? 8 : 0,
          ),
          child: _dot(4),
        ),
      ],
    );
  }

  Widget _dot(double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: MilesColors.surface1,
          shape: BoxShape.circle,
          border: Border.all(color: MilesColors.hairline, width: 0.8),
        ),
      );
}
