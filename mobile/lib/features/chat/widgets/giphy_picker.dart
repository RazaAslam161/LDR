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
    builder: (_) => const _GiphySheet(),
  );
}

class _GiphySheet extends StatefulWidget {
  const _GiphySheet();

  @override
  State<_GiphySheet> createState() => _GiphySheetState();
}

class _GiphySheetState extends State<_GiphySheet> {
  final _search = TextEditingController();
  Timer? _debounce;
  List<GiphyGif> _gifs = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load(null);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load(String? query) async {
    setState(() => _loading = true);
    final gifs = (query == null || query.trim().isEmpty)
        ? await GiphyService.trending()
        : await GiphyService.search(query.trim());
    if (mounted) {
      setState(() {
        _gifs = gifs;
        _loading = false;
      });
    }
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
    if (!GiphyService.isConfigured) {
      return const Padding(
        padding: EdgeInsets.all(28),
        child: Center(
          child: Text(
            'GIFs need a free GIPHY key.\n\nGet one at developers.giphy.com → '
            'Create App, then add it to the app as GIPHY_API_KEY.',
            textAlign: TextAlign.center,
            style: TextStyle(color: MilesColors.taupe, fontSize: 13.5),
          ),
        ),
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_gifs.isEmpty) {
      return const Center(
        child: Text('No GIFs found — try another word.',
            style: TextStyle(color: MilesColors.taupe),),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: _gifs.length,
      itemBuilder: (_, i) {
        final g = _gifs[i];
        return GestureDetector(
          onTap: () => Navigator.pop(context, g.fullUrl),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.network(
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
