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

/// The viewer's filmstrip cell: 46dp at 3x. Keeps its own key deliberately —
/// it is an order of magnitude smaller than a grid tile and sharing the tile's
/// decode would hold a 512px frame for a 46dp square.
const int kFilmstripDecodePx = 138;

/// How far either side of the current page a THUMBNAIL is decoded and pinned.
///
/// Thumbnails only. Four each way is ~7.7MB and makes a fast swipe land on a
/// frame that is already painted; the same radius of originals would be 66MB.
const int kThumbPrecacheRadius = 4;

/// How far either side the ORIGINAL's bytes are put on disk. Not decoded —
/// decoding an original nobody has swiped to yet is what makes the pager
/// expensive rather than fast.
const int kFileWarmRadius = 2;

/// The same on a metered connection. A pager left open on mobile data should
/// not quietly pull six originals the user never looked at.
const int kFileWarmRadiusMetered = 1;

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
