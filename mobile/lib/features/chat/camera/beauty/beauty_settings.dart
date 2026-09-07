import 'package:flutter/foundation.dart';

/// The retouch layer's settings — one value type shared by the camera, the call
/// and Settings.
///
/// It composes WITH the eleven colour presets in camera_filters.dart, never
/// replaces them. Those are a whole-frame colour grade; this is a per-face,
/// per-pixel transform applied before the grade. `_selectedFilter` keeps its
/// exact current meaning.
///
/// Everything here is a plain number or a string id, so the whole struct is
/// const-constructible and the preset list below is a genuine `const List`,
/// the same shape as `kCameraFilters`.
@immutable
class BeautySettings {
  const BeautySettings({
    this.enabled = false,
    this.amount = 1,
    this.presetId = 'natural',
    this.retouch = const RetouchParams(),
    this.reshape = const ReshapeParams(),
    this.makeup = const MakeupParams(),
  });

  /// Master switch. When false the engine is not started at all.
  final bool enabled;

  /// How much of the look to apply, 0..1. Multiplied into every axis on the way
  /// to the engine — per-axis values define the CHARACTER of a look, this
  /// defines how much of it. It is also the only control that fits under a
  /// 60dp button during a call.
  final double amount;

  /// Which named preset produced these values; null once any slider moved, so
  /// the UI can honestly say "Custom" instead of naming a preset it no longer
  /// matches.
  final String? presetId;

  final RetouchParams retouch;
  final ReshapeParams reshape;
  final MakeupParams makeup;

  BeautySettings copyWith({
    bool? enabled,
    double? amount,
    String? presetId,
    bool clearPreset = false,
    RetouchParams? retouch,
    ReshapeParams? reshape,
    MakeupParams? makeup,
  }) {
    return BeautySettings(
      enabled: enabled ?? this.enabled,
      amount: amount ?? this.amount,
      presetId: clearPreset ? null : (presetId ?? this.presetId),
      retouch: retouch ?? this.retouch,
      reshape: reshape ?? this.reshape,
      makeup: makeup ?? this.makeup,
    );
  }

  /// The payload the native engine receives.
  ///
  /// Flat, primitive and pre-multiplied, for three reasons that each cost
  /// something to get wrong:
  /// - Flat keys, so the Kotlin side does one lookup and no null-map dance.
  /// - `bool`/`int`/`double` only. Nothing else survives StandardMessageCodec
  ///   cleanly, and a Color certainly does not.
  /// - [amount] is folded in HERE, so the engine receives numbers and no
  ///   policy, and the arithmetic is unit-testable without a device.
  ///
  /// Disabled sends one key. The "off" command must not depend on the engine
  /// reading a flag it might ignore.
  Map<String, Object?> toChannelMap() {
    if (!enabled) return const {'enabled': false};
    final a = amount.clamp(0.0, 1.0);
    return {
      'enabled': true,
      'smooth': retouch.smooth * a,
      'tone': retouch.tone * a,
      'brighten': retouch.brighten * a,
      // Detail is a counterweight to smoothing, not an effect — scaling it by
      // amount would make a light touch plasticky, which is backwards.
      'detail': retouch.detail,
      'jaw': reshape.jaw * a,
      'chin': reshape.chin * a,
      'eyes': reshape.eyes * a,
      'nose': reshape.nose * a,
      'lipsArgb': makeup.lips.argb ?? 0,
      'lipsAmount': makeup.lips.effectiveIntensity * a,
      'blushArgb': makeup.blush.argb ?? 0,
      'blushAmount': makeup.blush.effectiveIntensity * a,
      'browsArgb': makeup.brows.argb ?? 0,
      'browsAmount': makeup.brows.effectiveIntensity * a,
      'eyeshadowArgb': makeup.eyeshadow.argb ?? 0,
      'eyeshadowAmount': makeup.eyeshadow.effectiveIntensity * a,
    };
  }

  /// The persisted shape — the AUTHORED values, with [amount] NOT folded in.
  ///
  /// Round-tripping the channel payload instead would bake the master amount
  /// into every axis and drift a little further on every save.
  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'amount': amount,
        'presetId': presetId,
        'smooth': retouch.smooth,
        'tone': retouch.tone,
        'brighten': retouch.brighten,
        'detail': retouch.detail,
        'jaw': reshape.jaw,
        'chin': reshape.chin,
        'eyes': reshape.eyes,
        'nose': reshape.nose,
        'lips': makeup.lips.toJson(),
        'blush': makeup.blush.toJson(),
        'brows': makeup.brows.toJson(),
        'eyeshadow': makeup.eyeshadow.toJson(),
      };

  /// Rebuilds from storage, clamping every number and validating every id.
  ///
  /// Anything unrecognised falls back to the default rather than throwing: a
  /// preset a later build stopped shipping must not strand the UI on a value
  /// no tap can reach.
  factory BeautySettings.fromJson(Map<String, Object?> j) {
    final preset = j['presetId'];
    final validPreset =
        preset is String && kBeautyPresets.any((p) => p.id == preset)
            ? preset
            : null;
    return BeautySettings(
      enabled: j['enabled'] == true,
      amount: _unit(j['amount'], 1),
      presetId: validPreset,
      retouch: RetouchParams(
        smooth: _unit(j['smooth'], 0),
        tone: _unit(j['tone'], 0),
        brighten: _unit(j['brighten'], 0),
        detail: _unit(j['detail'], 0.5),
      ),
      reshape: ReshapeParams(
        jaw: _signed(j['jaw']),
        chin: _signed(j['chin']),
        eyes: _signed(j['eyes']),
        nose: _signed(j['nose']),
      ),
      makeup: MakeupParams(
        lips: MakeupLayer.fromJson(j['lips']),
        blush: MakeupLayer.fromJson(j['blush']),
        brows: MakeupLayer.fromJson(j['brows']),
        eyeshadow: MakeupLayer.fromJson(j['eyeshadow']),
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BeautySettings &&
      other.enabled == enabled &&
      other.amount == amount &&
      other.presetId == presetId &&
      other.retouch == retouch &&
      other.reshape == reshape &&
      other.makeup == makeup;

  @override
  int get hashCode =>
      Object.hash(enabled, amount, presetId, retouch, reshape, makeup);
}

/// Skin work. All 0..1.
@immutable
class RetouchParams {
  const RetouchParams({
    this.smooth = 0,
    this.tone = 0,
    this.brighten = 0,
    this.detail = 0.5,
  });

  final double smooth;
  final double tone;
  final double brighten;

  /// How much high-frequency skin texture survives smoothing. Defaults to the
  /// middle rather than zero because it is the counterweight that keeps a
  /// strong smooth from reading as plastic.
  final double detail;

  @override
  bool operator ==(Object other) =>
      other is RetouchParams &&
      other.smooth == smooth &&
      other.tone == tone &&
      other.brighten == brighten &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(smooth, tone, brighten, detail);
}

/// Geometry. All SIGNED, -1..1, centre-detented at 0.
///
/// Signed because a jaw slider that can only narrow is half a control. Every
/// preset except `defined` leaves all four at 0.
@immutable
class ReshapeParams {
  const ReshapeParams({
    this.jaw = 0,
    this.chin = 0,
    this.eyes = 0,
    this.nose = 0,
  });

  final double jaw;
  final double chin;
  final double eyes;
  final double nose;

  bool get isIdentity => jaw == 0 && chin == 0 && eyes == 0 && nose == 0;

  @override
  bool operator ==(Object other) =>
      other is ReshapeParams &&
      other.jaw == jaw &&
      other.chin == chin &&
      other.eyes == eyes &&
      other.nose == nose;

  @override
  int get hashCode => Object.hash(jaw, chin, eyes, nose);
}

/// One makeup channel.
///
/// Stores a SHADE ID, never a raw colour. A stored ARGB int outlives every
/// palette change; an id is validated against the shades this build actually
/// ships, so a dropped shade degrades to "no shade" instead of to a colour
/// nothing in the UI can select.
@immutable
class MakeupLayer {
  const MakeupLayer({this.shadeId, this.intensity = 0});

  final String? shadeId;
  final double intensity;

  /// Zero unless a shade this build knows is selected — so an unknown id can
  /// never paint black on someone's lips.
  double get effectiveIntensity =>
      kMakeupShades.containsKey(shadeId) ? intensity : 0.0;

  int? get argb => kMakeupShades[shadeId];

  Map<String, Object?> toJson() => {'shade': shadeId, 'intensity': intensity};

  factory MakeupLayer.fromJson(Object? raw) {
    if (raw is! Map) return const MakeupLayer();
    final shade = raw['shade'];
    return MakeupLayer(
      shadeId: shade is String && kMakeupShades.containsKey(shade) ? shade : null,
      intensity: _unit(raw['intensity'], 0),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MakeupLayer &&
      other.shadeId == shadeId &&
      other.intensity == intensity;

  @override
  int get hashCode => Object.hash(shadeId, intensity);
}

@immutable
class MakeupParams {
  const MakeupParams({
    this.lips = const MakeupLayer(),
    this.blush = const MakeupLayer(),
    this.brows = const MakeupLayer(),
    this.eyeshadow = const MakeupLayer(),
  });

  final MakeupLayer lips;
  final MakeupLayer blush;
  final MakeupLayer brows;
  final MakeupLayer eyeshadow;

  bool get isEmpty =>
      lips.effectiveIntensity == 0 &&
      blush.effectiveIntensity == 0 &&
      brows.effectiveIntensity == 0 &&
      eyeshadow.effectiveIntensity == 0;

  @override
  bool operator ==(Object other) =>
      other is MakeupParams &&
      other.lips == lips &&
      other.blush == blush &&
      other.brows == brows &&
      other.eyeshadow == eyeshadow;

  @override
  int get hashCode => Object.hash(lips, blush, brows, eyeshadow);
}

/// The shade palette, keyed `<channel>.<name>`.
///
/// Constants, not assets. `assets/` has 1.4MB of headroom under the 12MB
/// ceiling asset_hygiene_test enforces, and every shipped asset must be
/// referenced from lib/ — a makeup atlas would be referenced from Kotlin and
/// would fail that test on arrival. Makeup is drawn procedurally instead,
/// which is also resolution-independent and recolourable.
const Map<String, int> kMakeupShades = {
  'lips.rose': 0xFFC96A72,
  'lips.berry': 0xFF9E3B5A,
  'lips.clay': 0xFFB4675A,
  'lips.plum': 0xFF7C3F58,
  'lips.soft': 0xFFCE8F86,
  'blush.peach': 0xFFE0977F,
  'blush.rose': 0xFFD2757F,
  'blush.warm': 0xFFC97F63,
  'brows.soft': 0xFF6B4A3A,
  'brows.deep': 0xFF3E2A22,
  'eyeshadow.bronze': 0xFFA97449,
  'eyeshadow.taupe': 0xFF8A7566,
  'eyeshadow.slate': 0xFF6A6E7A,
};

/// A named look. Tapping one replaces the whole struct.
@immutable
class BeautyPreset {
  const BeautyPreset({
    required this.id,
    required this.label,
    required this.settings,
  });

  final String id;
  final String label;
  final BeautySettings settings;
}

/// The ordered preset list. Index 0 is the identity, the same law
/// `kCameraFilters` states for its own first entry.
const List<BeautyPreset> kBeautyPresets = [
  BeautyPreset(
    id: 'off',
    label: 'Off',
    settings: BeautySettings(presetId: 'off'),
  ),
  // Everything below is deliberately STRONG. The first set was authored at
  // roughly a fifth of these values and read as "nothing happened" on a real
  // face: every axis is attenuated twice more after this point — once by
  // [BeautySettings.amount] and again by the skin mask in the shader — so a
  // preset that looks bold here lands as something believable on screen.
  BeautyPreset(
    id: 'natural',
    label: 'Natural',
    settings: BeautySettings(
      enabled: true,
      presetId: 'natural',
      retouch: RetouchParams(smooth: 0.85, tone: 0.55, brighten: 0.25),
    ),
  ),
  BeautyPreset(
    id: 'smooth',
    label: 'Smooth',
    settings: BeautySettings(
      enabled: true,
      presetId: 'smooth',
      // The silky one. Detail stays high on purpose: the guided filter removes
      // the blemish, and putting pore texture back is what keeps this from
      // reading as plastic.
      retouch: RetouchParams(smooth: 1, tone: 0.6, brighten: 0.3, detail: 0.55),
    ),
  ),
  BeautyPreset(
    id: 'bright',
    label: 'Bright',
    settings: BeautySettings(
      enabled: true,
      presetId: 'bright',
      retouch: RetouchParams(smooth: 0.7, tone: 0.75, brighten: 0.8),
    ),
  ),
  BeautyPreset(
    id: 'fresh',
    label: 'Fresh',
    settings: BeautySettings(
      enabled: true,
      presetId: 'fresh',
      retouch: RetouchParams(smooth: 0.8, tone: 0.7, brighten: 0.45),
      makeup: MakeupParams(
        blush: MakeupLayer(shadeId: 'blush.peach', intensity: 0.55),
      ),
    ),
  ),
  BeautyPreset(
    id: 'glow',
    label: 'Glow',
    settings: BeautySettings(
      enabled: true,
      presetId: 'glow',
      retouch: RetouchParams(smooth: 0.85, tone: 0.6, brighten: 0.7),
      makeup: MakeupParams(
        blush: MakeupLayer(shadeId: 'blush.warm', intensity: 0.5),
      ),
    ),
  ),
  BeautyPreset(
    id: 'porcelain',
    label: 'Porcelain',
    settings: BeautySettings(
      enabled: true,
      presetId: 'porcelain',
      retouch: RetouchParams(smooth: 1, tone: 0.85, brighten: 0.6, detail: 0.35),
    ),
  ),
  BeautyPreset(
    id: 'defined',
    label: 'Defined',
    settings: BeautySettings(
      enabled: true,
      presetId: 'defined',
      retouch: RetouchParams(smooth: 0.65, tone: 0.5, detail: 0.7),
      reshape: ReshapeParams(jaw: 0.55, chin: 0.3, nose: 0.35),
      makeup: MakeupParams(
        brows: MakeupLayer(shadeId: 'brows.deep', intensity: 0.45),
      ),
    ),
  ),
  BeautyPreset(
    id: 'polished',
    label: 'Polished',
    settings: BeautySettings(
      enabled: true,
      presetId: 'polished',
      retouch: RetouchParams(smooth: 0.9, tone: 0.7, brighten: 0.4),
      reshape: ReshapeParams(jaw: 0.35, eyes: 0.3),
      makeup: MakeupParams(
        lips: MakeupLayer(shadeId: 'lips.soft', intensity: 0.6),
        blush: MakeupLayer(shadeId: 'blush.peach', intensity: 0.5),
        brows: MakeupLayer(shadeId: 'brows.soft', intensity: 0.4),
      ),
    ),
  ),
  BeautyPreset(
    id: 'rose',
    label: 'Rose',
    settings: BeautySettings(
      enabled: true,
      presetId: 'rose',
      retouch: RetouchParams(smooth: 0.85, tone: 0.65, brighten: 0.4),
      reshape: ReshapeParams(eyes: 0.25),
      makeup: MakeupParams(
        lips: MakeupLayer(shadeId: 'lips.rose', intensity: 0.75),
        blush: MakeupLayer(shadeId: 'blush.rose', intensity: 0.55),
      ),
    ),
  ),
  BeautyPreset(
    id: 'evening',
    label: 'Evening',
    settings: BeautySettings(
      enabled: true,
      presetId: 'evening',
      retouch: RetouchParams(smooth: 0.9, tone: 0.65, brighten: 0.35),
      reshape: ReshapeParams(jaw: 0.4, eyes: 0.35),
      makeup: MakeupParams(
        lips: MakeupLayer(shadeId: 'lips.berry', intensity: 0.9),
        blush: MakeupLayer(shadeId: 'blush.rose', intensity: 0.6),
        brows: MakeupLayer(shadeId: 'brows.soft', intensity: 0.5),
        eyeshadow: MakeupLayer(shadeId: 'eyeshadow.bronze', intensity: 0.65),
      ),
    ),
  ),
  BeautyPreset(
    id: 'bold',
    label: 'Bold',
    settings: BeautySettings(
      enabled: true,
      presetId: 'bold',
      retouch: RetouchParams(smooth: 0.95, tone: 0.7, brighten: 0.4),
      reshape: ReshapeParams(jaw: 0.5, eyes: 0.4, chin: 0.2),
      makeup: MakeupParams(
        lips: MakeupLayer(shadeId: 'lips.plum', intensity: 1),
        blush: MakeupLayer(shadeId: 'blush.warm', intensity: 0.6),
        brows: MakeupLayer(shadeId: 'brows.deep', intensity: 0.6),
        eyeshadow: MakeupLayer(shadeId: 'eyeshadow.slate', intensity: 0.75),
      ),
    ),
  ),
];

/// A number in 0..1, or [fallback] if the stored value is not a number.
double _unit(Object? v, double fallback) =>
    v is num ? v.toDouble().clamp(0.0, 1.0) : fallback;

/// A number in -1..1, or 0.
double _signed(Object? v) => v is num ? v.toDouble().clamp(-1.0, 1.0) : 0.0;
