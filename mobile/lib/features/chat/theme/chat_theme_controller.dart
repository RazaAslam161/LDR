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
  String? _bgPath;

  String get themeId => _themeId;

  /// A storage path in `chat-bg`, or a legacy public URL cached by an older
  /// build. Readers sign it — the bucket is private.
  String? get bgPath => _bgPath;
  ChatTheme get theme => chatThemeById(_themeId);

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    _themeId = p.getString(_themeKey) ?? 'velvet';
    _bgPath = p.getString(_bgKey);
    notifyListeners();
    // Then reconcile with the server (cross-device).
    try {
      final remote = await SupabaseRepository.getChatTheme();
      _themeId = remote.themeId;
      _bgPath = remote.bgPath;
      await _cache();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _cache() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_themeKey, _themeId);
    if (_bgPath != null) {
      await p.setString(_bgKey, _bgPath!);
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

  Future<void> setCustomBackground(String path) async {
    _themeId = 'custom';
    _bgPath = path;
    notifyListeners();
    await _cache();
    try {
      await SupabaseRepository.setChatTheme('custom', bgPath: path);
    } catch (_) {}
  }
}

final chatThemeProvider =
    ChangeNotifierProvider<ChatThemeController>((ref) => ChatThemeController());
