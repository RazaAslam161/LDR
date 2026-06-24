import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:miles/core/ads/ad_config.dart';

/// A self-contained anchored **adaptive** banner.
///
/// Drop it at the bottom of any SFW screen. It loads on first build, renders
/// nothing until the ad is ready (so the layout never flashes a grey box), and
/// disposes the ad cleanly.
///
/// ⚠️ Never place this inside the Closer / intimacy module — AdMob policy
/// prohibits ads adjacent to mature or sexual content, and doing so can get the
/// whole app removed from the Play Store.
class BannerAdSlot extends StatefulWidget {
  const BannerAdSlot({super.key});

  @override
  State<BannerAdSlot> createState() => _BannerAdSlotState();
}

class _BannerAdSlotState extends State<BannerAdSlot> {
  BannerAd? _ad;
  bool _loaded = false;
  bool _requested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Guard so we only ever create one ad, even if dependencies change.
    if (!_requested) {
      _requested = true;
      _load();
    }
  }

  Future<void> _load() async {
    if (kIsWeb || !AdConfig.adsEnabled) return;

    final width = MediaQuery.of(context).size.width.truncate();
    final size = await AdSize.getLargeAnchoredAdaptiveBannerAdSize(width);
    if (size == null || !mounted) return;

    final ad = BannerAd(
      adUnitId: AdConfig.bannerUnitId,
      size: size,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (mounted) {
            setState(() => _loaded = true);
          }
        },
        onAdFailedToLoad: (ad, error) => ad.dispose(),
      ),
    );

    await ad.load();
    if (!mounted) {
      await ad.dispose();
      return;
    }
    _ad = ad;
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (!_loaded || ad == null) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: SizedBox(
        width: ad.size.width.toDouble(),
        height: ad.size.height.toDouble(),
        child: AdWidget(ad: ad),
      ),
    );
  }
}
