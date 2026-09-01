import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';

/// The doorstep's eight films and four held stages, addressed by story facts.
///
/// The clip that plays is decided by WHO started the ceremony and what they
/// look like — the initiator's gender picks the porch film and, later, which
/// of them walks back in through the door. Both phones therefore always show
/// the SAME film for the shared beats (reunion, parting), because both derive
/// it from the same row.
class FilmLibrary {
  FilmLibrary._();

  // Literal paths, one per line: the asset-hygiene orphan rule matches on
  // them. (scene_assets.dart learned this; every loader since inherits it.)
  static const outM = 'assets/unlink_films/out_m.mp4';
  static const outF = 'assets/unlink_films/out_f.mp4';
  static const inM = 'assets/unlink_films/in_m.mp4';
  static const inF = 'assets/unlink_films/in_f.mp4';
  static const reunionMEnters = 'assets/unlink_films/reunion_m_enters.mp4';
  static const reunionFEnters = 'assets/unlink_films/reunion_f_enters.mp4';
  static const partingOutM = 'assets/unlink_films/parting_out_m.mp4';
  static const partingOutF = 'assets/unlink_films/parting_out_f.mp4';
  static const stageOutM = 'assets/unlink_films/stage_out_m.webp';
  static const stageOutF = 'assets/unlink_films/stage_out_f.webp';
  static const stageInM = 'assets/unlink_films/stage_in_m.webp';
  static const stageInF = 'assets/unlink_films/stage_in_f.webp';
  static const clockPorch = 'assets/unlink_films/clock_porch.webp';
  static const clockRoom = 'assets/unlink_films/clock_room.webp';
  static const keyRelink = 'assets/unlink_films/key_relink.webp';
  static const photoFrame = 'assets/unlink_films/photo_frame.webp';
  static const photoTorn = 'assets/unlink_films/photo_torn.webp';

  /// The intro film for THIS phone: my role on the porch or the sofa, wearing
  /// my own character. Neutral gender has no film — the scene opens on the
  /// painted fallback stage, which is a designed state, not an error.
  static String? intro({required SceneRole role, required PuppetVariant me}) =>
      switch ((role, me)) {
        (_, PuppetVariant.neutral) => null,
        (SceneRole.outside, PuppetVariant.male) => outM,
        (SceneRole.outside, PuppetVariant.female) => outF,
        (SceneRole.inside, PuppetVariant.male) => inM,
        (SceneRole.inside, PuppetVariant.female) => inF,
      };

  /// The held stage that the intro film hands off to — its own true last
  /// frame, extracted at build time, byte-for-byte the pose the film ends on.
  static String? stage({required SceneRole role, required PuppetVariant me}) =>
      switch ((role, me)) {
        (_, PuppetVariant.neutral) => null,
        (SceneRole.outside, PuppetVariant.male) => stageOutM,
        (SceneRole.outside, PuppetVariant.female) => stageOutF,
        (SceneRole.inside, PuppetVariant.male) => stageInM,
        (SceneRole.inside, PuppetVariant.female) => stageInF,
      };

  /// The shared endings: whoever was OUTSIDE is the one who walks back in
  /// (reunion) or away (parting), so the initiator's gender picks the film —
  /// identically on both phones.
  static String reunion({required bool initiatorMale}) =>
      initiatorMale ? reunionMEnters : reunionFEnters;

  static String parting({required bool initiatorMale}) =>
      initiatorMale ? partingOutM : partingOutF;

  static final Map<String, ui.Image> _stills = {};
  static final Map<String, Future<void>> _loading = {};

  static ui.Image? still(String path) => _stills[path];

  /// One still, decoded at the width it is drawn at. Idempotent per path.
  static Future<void> ensureStill(String path) =>
      _loading[path] ??= _decode(path);

  static Future<void> _decode(String path) async {
    try {
      final bytes = await rootBundle.load(path);
      final codec = await ui.instantiateImageCodec(
        bytes.buffer.asUint8List(),
        targetWidth: 720,
      );
      _stills[path] = (await codec.getNextFrame()).image;
    } catch (e) {
      // The painted composite stage is the designed fallback; the failure
      // still gets named.
      debugPrint('films: $path failed to decode, painted stage stands: $e');
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _stills.clear();
    _loading.clear();
  }
}
