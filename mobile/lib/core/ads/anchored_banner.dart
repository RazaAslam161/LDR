import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:miles/core/ads/ads_service.dart';
import 'package:miles/core/app/release_gate.dart';

/// A banner slot that never moves the screen underneath it.
///
/// The band claims its full height on the FIRST frame and keeps it whether an
/// ad loads, fails, or is suppressed. That is the whole reason this is a widget
/// instead of an inline `if (loaded) AdWidget(...)`: a banner that appears late
/// pushes everything below it down, and on the screen this ships to, the thing
/// that moves is a photograph someone has their finger on. Google asks for
/// reserved space for the same reason.
///
/// It also owns the gap and the rule beneath it, so a later edit cannot delete
/// the separation and leave an ad flush against a tappable control.
class AnchoredBannerBand extends StatefulWidget {
  const AnchoredBannerBand({this.suppressed = false, super.key});

  /// Hide the creative but keep the space. Passed for screen MODES — adjust,
  /// draw, reaction — not for individual gestures: each flip disposes and
  /// reloads, so a per-frame source would churn requests.
  final bool suppressed;

  /// [AdSize.banner] is 320x50 and is deliberately not adaptive. An adaptive
  /// height is only known after a platform round trip, which means either a
  /// reflow when the answer arrives or a guess that clips the creative — and it
  /// can reach 15% of the screen, which this layout (two photos, chips, a
  /// warmth meter and a chat strip) does not have to give. Fifty is the
  /// documented floor, so nothing is ever cut off.
  static const adHeight = 50.0;

  /// Dead space between the creative and whatever the screen puts below it.
  static const gap = 12.0;

  /// Floor between two requests, across the whole process.
  ///
  /// The shell rebuilds this screen on every tab change rather than keeping it
  /// alive, so without this each visit to Touch is a fresh ad request. With a
  /// two-person audience, a burst of requests against almost no viewable
  /// impressions is the shape of traffic AdMob assesses accounts for.
  static const minRequestInterval = Duration(seconds: 30);

  static DateTime? _lastRequest;

  /// Process-wide, so a suite cannot observe a second request without it.
  @visibleForTesting
  static void resetRequestThrottle() => _lastRequest = null;

  @override
  State<AnchoredBannerBand> createState() => _AnchoredBannerBandState();
}

class _AnchoredBannerBandState extends State<AnchoredBannerBand> {
  BannerAd? _ad;
  bool _loaded = false;

  /// Bumped by anything that invalidates an in-flight load. A callback that
  /// arrives carrying a stale generation is from an ad nobody is waiting for
  /// any more, and touching `_ad` on its behalf is how a failing request
  /// strands a healthy one.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    ReleaseGate.revision.addListener(_onGateChanged);
    _maybeLoad();
  }

  @override
  void didUpdateWidget(AnchoredBannerBand old) {
    super.didUpdateWidget(old);
    if (widget.suppressed == old.suppressed) return;
    if (widget.suppressed) {
      _drop();
    } else {
      _maybeLoad();
    }
  }

  /// The server changed its mind about ads while this screen was open.
  ///
  /// Both directions matter. Off means an ad already on screen has to go, not
  /// merely stop being requested — hiding a loaded banner leaves it accruing
  /// impressions nobody can see. On means the band has to actually ask for one,
  /// which nothing else here would ever do again: [initState] has run and
  /// [didUpdateWidget] only reacts to `suppressed`.
  void _onGateChanged() {
    if (!mounted) return;
    if (AdsService.available) {
      _maybeLoad();
    } else {
      _drop();
    }
    setState(() {});
  }

  void _maybeLoad() {
    if (widget.suppressed || !AdsService.available || _ad != null) return;
    final last = AnchoredBannerBand._lastRequest;
    final now = DateTime.now();
    if (last != null &&
        now.difference(last) < AnchoredBannerBand.minRequestInterval) {
      return;
    }
    AnchoredBannerBand._lastRequest = now;
    unawaited(_load(++_generation));
  }

  Future<void> _load(int generation) async {
    if (!await AdsService.ensureReady()) return;
    // Everything below was true before a multi-second consent form and SDK
    // initialisation. Re-asked rather than assumed: the widget may be gone, the
    // mode may have changed, and — the one that matters — the server may have
    // said stop while this was in flight.
    if (!mounted ||
        widget.suppressed ||
        !AdsService.available ||
        generation != _generation) {
      return;
    }
    final ad = BannerAd(
      size: AdSize.banner,
      adUnitId: AdsService.bannerUnitId,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (loaded) {
          if (!mounted || generation != _generation) {
            loaded.dispose();
            return;
          }
          setState(() => _loaded = true);
        },
        onAdFailedToLoad: (failed, error) {
          // Named, not swallowed. No fill is the ORDINARY outcome here — a new
          // app is on limited serving until AdMob's readiness review clears, so
          // a silent empty band would be indistinguishable from broken wiring.
          debugPrint('[ads] banner failed: ${error.code} ${error.message}');
          failed.dispose();
          // Only clears state that belongs to THIS request. Without the guard a
          // superseded request's failure would null a healthy sibling and
          // strand it undisposed.
          if (!mounted || generation != _generation) return;
          setState(() {
            _ad = null;
            _loaded = false;
          });
        },
      ),
    );
    _ad = ad;
    await ad.load();
  }

  /// Tears down whatever is loaded and makes any in-flight callback a no-op.
  void _drop() {
    _generation++;
    _ad?.dispose();
    _ad = null;
    _loaded = false;
  }

  @override
  void dispose() {
    ReleaseGate.revision.removeListener(_onGateChanged);
    _drop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Nothing reserved when the fleet switch is off. The band costs 63dp, and
    // holding that open on every handset for an ad the server has disabled
    // would be paying the price of the feature without the feature.
    if (!AdsService.available) return const SizedBox.shrink();
    final ad = _ad;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: AnchoredBannerBand.adHeight,
          child: _loaded && ad != null
              ? Center(
                  child: SizedBox(
                    width: ad.size.width.toDouble(),
                    height: ad.size.height.toDouble(),
                    child: AdWidget(ad: ad),
                  ),
                )
              : null,
        ),
        const SizedBox(height: AnchoredBannerBand.gap),
        const Divider(height: 1, thickness: 1, color: Color(0x1FE8C49A)),
      ],
    );
  }
}
