import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/features/chat/theme/chat_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds the user's chat theme. Loads instantly from a local cache, then syncs
/// from the profile (so a fresh install picks up the saved choice). Each partner
/// has their own theme — this never touches the other person.
class ChatThemeController extends ChangeNotifier {
  ChatThemeController() {
    _init();
  }

  static const _themeKey = 'chat_theme_id';
  static const _bgKey = 'chat_bg_url';

  String _themeId = 'velvet';
  String? _bgUrl;

  String get themeId => _themeId;
  String? get bgUrl => _bgUrl;
  ChatTheme get theme => chatThemeById(_themeId);

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    _themeId = p.getString(_themeKey) ?? 'velvet';
    _bgUrl = p.getString(_bgKey);
    notifyListeners();
    // Then reconcile with the server (cross-device).
    try {
      final remote = await SupabaseRepository.getChatTheme();
      _themeId = remote.themeId;
      _bgUrl = remote.bgUrl;
      await _cache();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _cache() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_themeKey, _themeId);
    if (_bgUrl != null) {
      await p.setString(_bgKey, _bgUrl!);
    } else {
      await p.remove(_bgKey);
    }
  }

  Future<void> setTheme(String id) async {
    _themeId = id;
    notifyListeners();
    await _cache();
    try {
      await SupabaseRepository.setChatTheme(id);
    } catch (_) {}
  }

  Future<void> setCustomBackground(String url) async {
    _themeId = 'custom';
    _bgUrl = url;
    notifyListeners();
    await _cache();
    try {
      await SupabaseRepository.setChatTheme('custom', bgUrl: url);
    } catch (_) {}
  }
}

final chatThemeProvider =
    ChangeNotifierProvider<ChatThemeController>((ref) => ChatThemeController());
