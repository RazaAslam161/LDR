import 'dart:async';

import 'package:flutter/material.dart';
import 'package:miles/core/services/giphy_service.dart';
import 'package:miles/core/ui/theme.dart';

/// A GIPHY GIF picker. Returns the chosen GIF's URL (or null). Used to fling a
/// GIF and to attach one in chat.
Future<String?> showGiphyPicker(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: MilesColors.surface1,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const GiphySheet(),
  );
}

/// Public only so a widget test can pump it with a [loader]: the states worth
/// testing here are the failures, and a live GIPHY call cannot be asked to
/// produce one on demand.
class GiphySheet extends StatefulWidget {
  const GiphySheet({super.key, this.loader});

  /// Null in the app — [GiphyService] answers. The query is already trimmed;
  /// empty means trending.
  final Future<GiphyResult> Function(String query)? loader;

  @override
  State<GiphySheet> createState() => _GiphySheetState();
}

class _GiphySheetState extends State<GiphySheet> {
  final _search = TextEditingController();
  Timer? _debounce;

  /// What Retry re-runs. Also picks the empty-state wording: with no query,
  /// "try another word" is advice about a word the user never typed.
  String _query = '';

  /// Null while a fetch is in flight — the sheet opens straight into one.
  GiphyResult? _result;

  /// Bumped per load; a reply carrying a stale number is dropped.
  ///
  /// Loads overlap routinely — the opening trending fetch against the first
  /// debounced keystroke, or Try again tapped while the failing request is
  /// still out — and the older one used to win simply by finishing last,
  /// painting one word's GIFs underneath another word's empty-state wording.
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load(''));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load(String query) async {
    final q = query.trim();
    final seq = ++_seq;
    setState(() {
      _query = q;
      _result = null;
    });
    final res = await _fetch(q);
    if (!mounted || seq != _seq) return;
    setState(() => _result = res);
  }

  Future<GiphyResult> _fetch(String q) {
    final loader = widget.loader;
    if (loader != null) return loader(q);
    return q.isEmpty ? GiphyService.trending() : GiphyService.search(q);
  }

  void _onSearchChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _load(q));
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: h * 0.72,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                  color: MilesColors.taupe,
                  borderRadius: BorderRadius.circular(2),),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _search,
                onChanged: _onSearchChanged,
                style: const TextStyle(color: MilesColors.cream50),
                decoration: InputDecoration(
                  hintText: 'Search GIFs — happy, love, sulky, miss you…',
                  hintStyle: const TextStyle(color: MilesColors.taupe),
                  prefixIcon:
                      const Icon(Icons.search, color: MilesColors.taupe),
                  filled: true,
                  fillColor: MilesColors.surface2,
                  contentPadding: const EdgeInsets.symmetric(),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(child: _body()),
            // "Powered by GIPHY" — required by GIPHY's attribution terms.
            const Padding(
              padding: EdgeInsets.only(bottom: 8, top: 2),
              child: Text('Powered by GIPHY',
                  style: TextStyle(color: MilesColors.taupe, fontSize: 10),),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final result = _result;
    if (result == null) {
      return const Center(child: CircularProgressIndicator());
    }
    switch (result.status) {
      case GiphyStatus.notConfigured:
        // No retry: the key is missing server-side and nothing on this handset
        // can supply it, so a button that re-runs the same lookup would be a
        // control that is known in advance to do nothing.
        return const _Note(
          'GIFs need a free GIPHY key.\n\nGet one at developers.giphy.com → '
          'Create App, then add it to the app as GIPHY_API_KEY.',
          icon: Icons.vpn_key_outlined,
        );
      case GiphyStatus.keyRejected:
        // Retry is real here and only because the service drops its cached key
        // on this status: the tap re-reads `app_secrets`, so the moment the row
        // is replaced this button starts working, with no restart.
        return _Note(
          "GIPHY turned this app's key away.\n\nIt needs replacing as "
          'GIPHY_API_KEY — then try again.',
          icon: Icons.key_off_outlined,
          onRetry: () => unawaited(_load(_query)),
        );
      case GiphyStatus.rateLimited:
        // The one failure where trying again immediately is the wrong advice,
        // so the copy says wait and the button stays for when they have.
        return _Note(
          "GIFs have used up GIPHY's limit for now.\n\nIt resets on its own.",
          icon: Icons.hourglass_empty,
          onRetry: () => unawaited(_load(_query)),
        );
      case GiphyStatus.unavailable:
        return _Note(
          "GIFs aren't loading right now.",
          icon: Icons.cloud_off_outlined,
          onRetry: () => unawaited(_load(_query)),
        );
      case GiphyStatus.ok:
        if (result.gifs.isEmpty) {
          return _Note(
            _query.isEmpty
                ? 'GIPHY has nothing to show right now.'
                : 'No GIFs found — try another word.',
          );
        }
    }
    final gifs = result.gifs;
    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: gifs.length,
      itemBuilder: (_, i) {
        final g = gifs[i];
        return GestureDetector(
          onTap: () => Navigator.pop(context, g.fullUrl),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.network(
              // A 3-col grid of animated GIFs, every frame at source resolution.
              cacheWidth: 250,
              g.previewUrl,
              fit: BoxFit.cover,
              loadingBuilder: (_, child, p) =>
                  p == null ? child : Container(color: MilesColors.surface2),
              errorBuilder: (_, __, ___) =>
                  Container(color: MilesColors.surface2),
            ),
          ),
        );
      },
    );
  }
}

/// The sheet's non-grid states, all rendered by this one card: no key, a key
/// GIPHY refused, a spent quota, an outage, and a search that matched nothing.
///
/// The icon and [onRetry] are what separate them: an outage that reads exactly
/// like "nothing matched your word" is a lie about whose fault it is, and a
/// user who believes it types a different word instead of trying again. Retry
/// is present only where it can actually change the answer — which is why
/// [GiphyStatus.notConfigured] alone has none, and why the rejected-key state
/// has one only because the service stops caching a key that was refused.
class _Note extends StatelessWidget {
  const _Note(this.text, {this.icon, this.onRetry});

  final String text;
  final IconData? icon;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, color: MilesColors.taupe, size: 34),
                const SizedBox(height: 10),
              ],
              Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: MilesColors.taupe,
                  fontSize: 13.5,
                ),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 6),
                TextButton(onPressed: onRetry, child: const Text('Try again')),
              ],
            ],
          ),
        ),
      );
}
