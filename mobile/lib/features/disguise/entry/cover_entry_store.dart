import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:miles/features/disguise/cover_gate.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:miles/features/disguise/entry/cover_entry_trigger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the owner's recorded moves live: one keystore record per cover, and
/// beside each a plain-prefs mirror that only says a record exists.
///
/// The keystore is the guard — a move is a secret in geometry form, the same
/// class as the PIN hash that was moved out of the prefs file for the same
/// reason — but the keystore is also slow on first access and can throw where
/// prefs never could (app_lock.dart has the same guard). The mirror is what
/// lets the host know the MODE on the first frame: "a move exists" is not a
/// secret, and knowing it is what keeps the backup door on the PIN while the
/// payload is still loading or has gone unreadable. Stated limit: the PIN
/// lives in the same store, so a keystore wiped clean takes both, and on a
/// phone with no biometric the backup then opens through the no-key floor.
///
/// Per cover, never one slot: recording a move for a new cover must not touch
/// the worn cover's, because the alias switch that follows can kill the
/// process and fail, and the worn cover has to keep its door either way.
class CoverEntryStore {
  CoverEntryStore._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static String keyFor(DisguiseCover cover) =>
      'miles_cover_entry_${cover.name}_v1';

  static String mirrorKeyFor(DisguiseCover cover) =>
      'cover_entry_present_${cover.name}';

  /// Decoded records, once read: the host is rebuilt on every cover raise and
  /// must not pay the keystore again each time.
  static final Map<DisguiseCover, CoverEntryTrigger> _cache = {};

  /// Whether the mirror says a move exists for [cover]. A prefs read, so it
  /// resolves as fast as the identity does.
  static Future<bool> present(DisguiseCover cover) async =>
      (await SharedPreferences.getInstance()).getBool(mirrorKeyFor(cover)) ??
      false;

  /// The move recorded for [cover], or null when there is none or it cannot
  /// be read. Never throws. Deliberately NOT bounded: nothing paints on this
  /// read (the mirror answers the mode first, and the backup hold takes five
  /// seconds to fire), and a first keystore access after a reboot can take
  /// longer than any timeout worth having — a read cut short would leave the
  /// owner's move dead for the whole session and report a record that is
  /// fine as unreadable.
  static Future<CoverEntryTrigger?> load(DisguiseCover cover) async {
    final cached = _cache[cover];
    if (cached != null) return cached;
    String? raw;
    try {
      raw = await _storage.read(key: keyFor(cover));
    } catch (e) {
      debugPrint('[cover-entry] secure read failed: ${e.runtimeType}');
      return null;
    }
    if (raw == null) return null;
    final trigger = CoverEntryTrigger.fromJson(raw);
    if (trigger == null || trigger.cover != cover) {
      // Only save() writes this key, so a record that does not decode or
      // names another cover is a defect worth naming, never a silent none.
      debugPrint('[cover-entry] record for ${cover.name} unreadable');
      return null;
    }
    _cache[cover] = trigger;
    return trigger;
  }

  /// What the host should do for [cover]: the payload decides `custom`, the
  /// mirror alone decides `customUnknown`, and neither is `none`.
  ///
  /// The payload is consulted first so a record whose mirror write was lost
  /// (a process death between the two writes) still counts as the move it is.
  static Future<(CoverEntryMode, CoverEntryTrigger?)> resolve(
    DisguiseCover cover,
  ) async {
    final trigger = await load(cover);
    if (trigger != null) return (CoverEntryMode.custom, trigger);
    return (
      await present(cover) ? CoverEntryMode.customUnknown : CoverEntryMode.none,
      null,
    );
  }

  /// Keystore first, mirror second: a death between the two leaves a record
  /// the next [resolve] finds through the payload, whereas the other order
  /// would leave a mirror promising a move that was never written.
  static Future<bool> save(CoverEntryTrigger trigger) async {
    try {
      await _storage.write(key: keyFor(trigger.cover), value: trigger.encode());
      await (await SharedPreferences.getInstance())
          .setBool(mirrorKeyFor(trigger.cover), true);
    } catch (e) {
      debugPrint('[cover-entry] write failed: ${e.runtimeType}');
      // A keystore write that landed and a mirror write that did not would
      // leave a record nothing points at. Take both back.
      await clear(trigger.cover);
      return false;
    }
    _cache[trigger.cover] = trigger;
    return true;
  }

  /// Mirror first, keystore second: the reverse of [save], for the same
  /// reason — at no point does the mirror promise a record that is gone.
  static Future<void> clear(DisguiseCover cover) async {
    await (await SharedPreferences.getInstance()).remove(mirrorKeyFor(cover));
    _cache.remove(cover);
    try {
      await _storage.delete(key: keyFor(cover));
    } catch (e) {
      debugPrint('[cover-entry] secure delete failed: ${e.runtimeType}');
    }
  }

  @visibleForTesting
  static void resetForTest() => _cache.clear();
}
