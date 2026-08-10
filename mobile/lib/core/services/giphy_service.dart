import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

/// One GIF result from GIPHY.
class GiphyGif {
  const GiphyGif({
    required this.id,
    required this.previewUrl,
    required this.fullUrl,
  });
  final String id;
  final String previewUrl; // small, for the grid
  final String fullUrl; // sent / flung
}

/// Thin GIPHY REST client. Free to use — needs a free API key in `.env` as
/// GIPHY_API_KEY (https://developers.giphy.com → Create App). No key → empty
/// results (the picker shows a friendly "add your key" note instead).
class GiphyService {
  GiphyService._();

  static String get _key => dotenv.maybeGet('GIPHY_API_KEY') ?? '';
  static bool get isConfigured => _key.trim().isNotEmpty;

  static Future<List<GiphyGif>> trending({int limit = 24}) => _fetch(
        'https://api.giphy.com/v1/gifs/trending'
        '?api_key=$_key&limit=$limit&rating=r&bundle=messaging_non_clips',
      );

  static Future<List<GiphyGif>> search(String q, {int limit = 24}) => _fetch(
        'https://api.giphy.com/v1/gifs/search'
        '?api_key=$_key&q=${Uri.encodeQueryComponent(q)}'
        '&limit=$limit&rating=r&bundle=messaging_non_clips',
      );

  static Future<List<GiphyGif>> _fetch(String url) async {
    if (_key.trim().isEmpty) return const [];
    try {
      final res =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return const [];
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (data['data'] as List?) ?? const [];
      final out = <GiphyGif>[];
      for (final e in list) {
        final images = (e as Map)['images'] as Map?;
        if (images == null) continue;
        final preview = (images['fixed_width_small'] ??
            images['fixed_width'] ??
            images['downsized']) as Map?;
        final full = (images['downsized_medium'] ??
            images['downsized'] ??
            images['fixed_width'] ??
            images['original']) as Map?;
        final pUrl = preview?['url']?.toString();
        final fUrl = full?['url']?.toString();
        if (pUrl == null || fUrl == null) continue;
        out.add(
            GiphyGif(id: e['id'].toString(), previewUrl: pUrl, fullUrl: fUrl),);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}
