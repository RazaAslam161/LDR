/// Decode sizes, in pixels, shared by every surface that paints stored media.
///
/// These are constants in one file for a reason that is not tidiness. Flutter
/// keys a decoded frame on the provider AND its resize bounds, so two surfaces
/// that ask for the same object at different sizes get two decodes and two
/// cache entries — the second one paying full cost while the first sits
/// resident. The grid tile, the viewer's underlay and the neighbour precache
/// are three surfaces painting one thumbnail, and they only share a decode if
/// they agree here.
///
/// That is also why nothing in this app sets `memCacheHeight`. Passing both
/// dimensions makes the key depend on both, so a square tile (`width: side,
/// height: side`) and a viewer underlay (width only) miss each other even when
/// the width matches. One dimension, always; `BoxFit` handles the shape.
library;

/// A legacy original painted as a tile — no thumbnail sibling exists, so the
/// full-size object is what the grid has to decode. ~1.4MB resident per entry
/// against the ~48MB an unbounded 12MP decode costs.
const int kTileDecodePx = 512;

/// The ONE width every small surface decodes a CHAT thumbnail at.
///
/// The thumbnail object is 640px on its long edge ([Thumbnails.maxEdge]), and
/// the largest surface that paints one is the 220dp chat bubble — ~605px at
/// dpr 2.75. So this is the object's own size: landscape decodes 1:1, and
/// portrait decodes at its native width because `ResizeImage` does not upscale.
///
/// Bounded rather than `thumb: true`, and that is the point. Left unbounded a
/// 640px object costs 1.64MB of raster against 0.64MB at 400px — a 2.5x rise
/// on a budget that is 32MiB on a small handset. One shared bound keeps the
/// sharper object AND one decode across the bubble, the album tile and the
/// pager's underlay.
const int kThumbDecodePx = 640;

/// Pinch past this and the full-resolution layer is mounted over the bounded
/// one, so a zoom is crisp without every page paying for it.
const double kZoomUpgradeScale = 1.5;

/// Release below this and it is unmounted. Deliberately NOT the same number as
/// [kZoomUpgradeScale] — equal thresholds mount and unmount a 48MB decode on
/// every jitter around the boundary.
const double kZoomRevertScale = 1.2;

/// How long the underlay may fail to paint before a progress indicator is
/// allowed to appear.
///
/// Gated on "nothing has painted yet", never on "we are loading". A row whose
/// has_thumb is true but whose object is missing signs to nothing and would
/// otherwise hold a pure black screen for the whole original download with no
/// indication anything is happening.
const Duration kIndicatorDelay = Duration(milliseconds: 400);
