import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:miles/core/app/config.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/core/net/timeout_http_client.dart';
import 'package:miles/core/services/session_scope.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// One partner's delivery/read position, as server-assigned message `seq`.
@immutable
class ChatReceipt {
  const ChatReceipt({this.deliveredSeq = 0, this.readSeq = 0});

  factory ChatReceipt.fromJson(Map<String, dynamic> j) => ChatReceipt(
        deliveredSeq: JsonUtils.parseInt(j['delivered_seq']),
        readSeq: JsonUtils.parseInt(j['read_seq']),
      );

  final int deliveredSeq;
  final int readSeq;
}

/// Read receipts that do not involve a clock.
///
/// The old model compared `presence.chat_last_read` (stamped by the READER'S
/// PHONE) against `messages.created_at` (stamped by POSTGRES). Two clocks, one
/// inequality, one second of slop. A reader 40 seconds slow left every message
/// on a black double tick long after it was read; a reader running fast marked
/// messages seen that were never on screen, and the client latched it
/// permanently. Two NTP-synced dev phones agree to the millisecond, which is
/// precisely why it looked correct and was not.
///
/// Here nothing compares times. The recipient acks the highest `seq` it has,
/// the server advances with `greatest()`, and the sender compares integers.
///
/// DELIVERED AND READ ARE DIFFERENT FACTS, ACKED FROM DIFFERENT PLACES.
/// [ackDelivered] answers "this handset has it" and fires from the push, from
/// the socket reconnect and from the app resume — none of which mean anyone
/// looked. [ackRead] answers "a human saw it" and fires from the chat screen
/// alone. Nothing in this file, and nothing in [DeliveryAckPort] or
/// [BackgroundReceiptAck] below, may call [ackRead]: opening the conversation
/// used to be the only thing that acked EITHER, which is why a message sat on
/// one grey tick until the recipient opened the chat and then jumped straight
/// past two grey to two green.
class ChatReceiptRepository {
  ChatReceiptRepository._();

  static final _c = SupabaseService.client;

  /// The partner has RECEIVED everything up to [seq] — not necessarily read.
  ///
  /// [trigger] names what caused the ack. Call sites, all of which reach here
  /// without the conversation being on screen except the first:
  ///   chat_open / catchup      — chat_screen's catch-up (also acks read)
  ///   push_fg                  — a message push with the app foregrounded
  ///   push_bg_handoff          — a message push handed over by the background
  ///                              isolate (fcm/reach_notifications)
  ///   socket_open / app_resume — the backstop for a push that never arrived
  static Future<void> ackDelivered(int seq, {required String trigger}) async {
    if (seq <= 0) {
      _traceAck('ack_delivered', seq, trigger, skipped: 'seq_not_positive');
      return;
    }
    if (!_signedIn) {
      _traceAck('ack_delivered', seq, trigger, skipped: 'signed_out');
      return;
    }
    final couple = await _couple();
    if (seq <= await DeliveredMark.acked(couple)) {
      // Coalesced. The watermark only moves on a confirmed 200, so this can
      // never swallow an ack that did not land — a dropped one stays owed and
      // is re-sent by the next trigger.
      _traceAck('ack_delivered', seq, trigger, skipped: 'already_acked');
      return;
    }
    final sw = Stopwatch()..start();
    try {
      await _c.rpc<dynamic>('ack_delivered', params: {'p_seq': seq});
      await DeliveredMark.recordAcked(couple, seq);
      _traceAck('ack_delivered', seq, trigger,
          ok: true, ms: sw.elapsedMilliseconds,);
    } catch (e, s) {
      // NOT best-effort any more. "A lost ack self-corrects on the next one"
      // was true only while the chat screen was the single caller, because the
      // screen re-acked on every catch-up; a push-driven ack has no next one.
      // So the seq is written down and [ackHighestDelivered] re-sends it.
      await DeliveredMark.recordOwed(couple, seq);
      _traceAck('ack_delivered', seq, trigger,
          ok: false, error: e, ms: sw.elapsedMilliseconds,);
      reportIfNotMerelyOffline(e, s, 'receipt-delivered');
      debugPrint('[receipts] ackDelivered seq=$seq failed, owed: $e');
    }
  }

  /// Whether an ack can possibly land.
  ///
  /// `ack_read` and `ack_delivered` are granted to `authenticated` and NOT to
  /// `anon`, so calling either without a session is a guaranteed Postgres
  /// 42501. That is not hypothetical: chat_screen's dispose() flushes the read
  /// watermark on the way out, and signing out disposes the chat — so every
  /// sign-out from the conversation fired one, and build 76 reported it from
  /// the field. Guarded HERE rather than at the call site because dispose() is
  /// not the only teardown path and the next one would reintroduce it.
  static bool get _signedIn =>
      SupabaseService.client.auth.currentSession != null;

  /// The user has SEEN everything up to [seq].
  ///
  /// Only the chat screen may call this. `ack_read` advances `delivered_seq`
  /// server-side too (you cannot read what you never received), so a successful
  /// read ack moves the delivered watermark as well — the implication runs one
  /// way only and never back.
  static Future<void> ackRead(int seq, {required String trigger}) async {
    if (seq <= 0) {
      _traceAck('ack_read', seq, trigger, skipped: 'seq_not_positive');
      return;
    }
    if (!_signedIn) {
      _traceAck('ack_read', seq, trigger, skipped: 'signed_out');
      return;
    }
    final sw = Stopwatch()..start();
    try {
      await _c.rpc<dynamic>('ack_read', params: {'p_seq': seq});
      await DeliveredMark.recordAcked(await _couple(), seq);
      _traceAck('ack_read', seq, trigger, ok: true, ms: sw.elapsedMilliseconds);
    } catch (e, s) {
      _traceAck('ack_read', seq, trigger,
          ok: false, error: e, ms: sw.elapsedMilliseconds,);
      reportIfNotMerelyOffline(e, s, 'receipt-read');
      debugPrint('[receipts] ackRead failed: $e');
    }
  }

  /// Ack delivery of the newest message this couple has, without the chat.
  ///
  /// The backstop for a push that was dropped, throttled, or never sent — which
  /// on Android is not the rare case. Two facts make it honest rather than a
  /// guess: the query only returns rows RLS lets this handset read, and it only
  /// answers at all when the handset is on the network. A `seq` this returns is
  /// one the device can fetch at that moment, which is the same standard a
  /// server-side delivery receipt is held to.
  ///
  /// Never acks read. Nobody has looked at anything here.
  ///
  /// Throttled, because a reconnect is not evidence that anything new exists —
  /// a flapping socket rejoins several times a second. Use
  /// [ackHighestDeliveredSoon] for the push path, where something new
  /// demonstrably does.
  static Future<void> ackHighestDelivered({required String trigger}) async {
    if (_lastRun != null &&
        DateTime.now().difference(_lastRun!) < _backstopEvery) {
      return;
    }
    await _ackHighest(trigger);
  }

  /// A push arrived but carried no seq. Collapse the burst — ten messages
  /// landing together are one query and one ack, not ten of each — then ack
  /// the newest of them.
  static void ackHighestDeliveredSoon({required String trigger}) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 800),
      () => unawaited(_ackHighest(trigger)),
    );
  }

  static Future<void> _ackHighest(String trigger) async {
    final couple = await _couple();
    // Deliberately before the stamp: a run that found no couple did no work,
    // so it must not spend the window a real one would have used.
    if (couple == null) return;
    _lastRun = DateTime.now();
    // Re-read: the background isolate writes the same keys from its own
    // SharedPreferences instance, and this one caches.
    await DeliveredMark.reload();
    final owed = await DeliveredMark.owed(couple);
    try {
      final seq = await highestSeq(couple);
      if (seq > 0) {
        await ackDelivered(seq, trigger: trigger);
        return;
      }
    } catch (e) {
      debugPrint('[receipts] highestSeq failed, falling back to owed: $e');
    }
    // The query failed but something is still owed from an earlier attempt —
    // re-send that rather than let it sit until the chat is next opened.
    if (owed > 0) await ackDelivered(owed, trigger: '${trigger}_owed');
  }

  /// Newest `seq` in this couple's messages, or 0 when there are none.
  static Future<int> highestSeq(String coupleId) async {
    final row = await _c
        .from('messages')
        .select('seq')
        .eq('couple_id', coupleId)
        .order('seq', ascending: false)
        .limit(1)
        .maybeSingle();
    return row == null ? 0 : JsonUtils.parseInt(row['seq']);
  }

  /// The watermark already suppresses a repeat RPC, but not the `highestSeq`
  /// query that decides one is unnecessary — this bounds that.
  static const _backstopEvery = Duration(seconds: 20);
  static DateTime? _lastRun;
  static Timer? _debounce;

  static Future<String?> _couple() async =>
      SessionScope.coupleId ?? await SessionScope.readCouple();

  /// Offline is not a defect and must not spend one of [ErrorReporter]'s five
  /// slots — the owed-seq retry above is the answer to it. A Postgrest refusal
  /// is a defect: the grant, the RLS policy or the function is wrong, and it
  /// would otherwise be invisible, because [Diag.record] records nothing in a
  /// shipped build and `debugPrint` reaches a cable attached to one handset.
  static void reportIfNotMerelyOffline(Object e, StackTrace s, String kind) {
    if (e is PostgrestException) ErrorReporter.report(e, s, kind: kind);
  }

  /// Both acks failed the same silent way — swallowed into a debugPrint that
  /// reaches a cable attached to one of the two phones. One shape, so the two
  /// halves stay comparable when the traces are laid side by side.
  static void _traceAck(
    String rpc,
    int seq,
    String trigger, {
    String? skipped,
    bool? ok,
    Object? error,
    int? ms,
  }) {
    Diag.record(DiagArea.receipt, 'receipt_ack_attempt', fields: {
      'rpc': rpc,
      'seq': seq,
      'trigger': trigger,
      'skipped_reason': skipped,
      'ok': ok,
      'error_class': error?.runtimeType.toString(),
      'pg_code': error is PostgrestException ? error.code : null,
      'latency_ms': ms,
    },);
  }

  /// The partner's current position. Null when they have no row yet.
  static Future<ChatReceipt?> fetchPartner(
      String coupleId, String partnerId,) async {
    try {
      final row = await _c
          .from('chat_receipts')
          .select('delivered_seq, read_seq')
          .eq('couple_id', coupleId)
          .eq('user_id', partnerId)
          .maybeSingle();
      return row == null ? null : ChatReceipt.fromJson(JsonUtils.asMap(row));
    } catch (e, st) {
      // The file's own rule, applied to its third RPC path: a Postgrest
      // refusal here is a schema or policy defect, and it used to read as
      // 'they have no row yet'.
      reportIfNotMerelyOffline(e, st, 'receipt-fetch');
      debugPrint('[receipts] fetchPartner failed: $e');
      return null;
    }
  }
}

/// What this handset has already told the server it received, and what it still
/// owes it.
///
/// In SharedPreferences rather than a static, because the two writers are two
/// isolates: the app, and the FCM background isolate, which shares no memory
/// with it. Both values are stamped with the couple they belong to — a handset
/// that signs in as somebody else must not have the previous account's
/// watermark suppress the new one's acks.
class DeliveredMark {
  DeliveredMark._();

  static const _ackedKey = 'receipt_delivered_acked';
  static const _owedKey = 'receipt_delivered_owed';

  /// Highest seq the server has CONFIRMED (HTTP 2xx) as delivered.
  static Future<int> acked(String? couple) => _read(_ackedKey, couple);

  /// Highest seq an ack was attempted for and failed. Retried by
  /// [ChatReceiptRepository.ackHighestDelivered].
  static Future<int> owed(String? couple) => _read(_owedKey, couple);

  static Future<void> recordAcked(String? couple, int seq) async {
    if (couple == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (seq <= _parse(prefs.getString(_ackedKey), couple)) return;
    await prefs.setString(_ackedKey, '$couple|$seq');
    // Anything owed at or below this is now settled; the server takes the max.
    if (seq >= _parse(prefs.getString(_owedKey), couple)) {
      await prefs.remove(_owedKey);
    }
  }

  static Future<void> recordOwed(String? couple, int seq) async {
    if (couple == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (seq <= _parse(prefs.getString(_owedKey), couple)) return;
    await prefs.setString(_owedKey, '$couple|$seq');
  }

  /// Pick up writes made by the other isolate.
  static Future<void> reload() async =>
      (await SharedPreferences.getInstance()).reload();

  static Future<int> _read(String key, String? couple) async {
    if (couple == null) return 0;
    final prefs = await SharedPreferences.getInstance();
    return _parse(prefs.getString(key), couple);
  }

  /// `<coupleId>|<seq>`. A value stamped with a different couple reads as 0,
  /// which re-acks rather than under-acks — the safe direction.
  static int _parse(String? raw, String couple) {
    if (raw == null) return 0;
    final i = raw.lastIndexOf('|');
    if (i <= 0 || raw.substring(0, i) != couple) return 0;
    return int.tryParse(raw.substring(i + 1)) ?? 0;
  }
}

/// The channel the FCM background isolate uses to reach the running app.
///
/// The background isolate has no session, no Supabase client and no memory
/// shared with the UI — but when the app's PROCESS is still alive (backgrounded
/// rather than killed) the UI isolate is sitting there with a fully authorised
/// client and sole ownership of the refresh token. Handing the ack to it is
/// both cheaper and the only safe option: see [BackgroundReceiptAck] for what
/// two isolates independently refreshing one session does to a user.
///
/// Same mechanism `FlutterForegroundTask.initCommunicationPort()` (main.dart)
/// already relies on to talk from the call service back to the app.
class DeliveryAckPort {
  DeliveryAckPort._();

  static const name = 'miles.delivery_ack';

  static ReceivePort? _port;

  /// UI isolate only. Idempotent.
  static void listen() {
    if (_port != null) return;
    final port = ReceivePort();
    // A hot restart leaves the previous engine's mapping behind, and
    // registerPortWithName refuses to replace one.
    IsolateNameServer.removePortNameMapping(name);
    if (!IsolateNameServer.registerPortWithName(port.sendPort, name)) {
      port.close();
      debugPrint('[receipts] delivery ack port already registered');
      return;
    }
    _port = port;
    port.listen((Object? msg) {
      if (msg is! int) return;
      // 0 means "the push carried no seq" — work out how far ourselves rather
      // than make the background isolate spend a request on it.
      if (msg > 0) {
        unawaited(
          ChatReceiptRepository.ackDelivered(msg, trigger: 'push_bg_handoff'),
        );
      } else {
        ChatReceiptRepository.ackHighestDeliveredSoon(
          trigger: 'push_bg_handoff',
        );
      }
    });
  }

  /// The running app's port, or null when this process has no UI isolate —
  /// which is the case for a push that started the process from cold.
  static SendPort? get liveApp => IsolateNameServer.lookupPortByName(name);
}

/// Acking delivery from the FCM background isolate.
///
/// WHAT THIS ISOLATE ACTUALLY HAS, verified rather than assumed:
///   * Plugin channels and the asset bundle — yes.
///     `_firebaseMessagingCallbackDispatcher` opens with
///     `WidgetsFlutterBinding.ensureInitialized()`
///     (firebase_messaging_platform_interface method_channel_messaging.dart:26)
///     before it ever reaches this handler, so SharedPreferences, `rootBundle`
///     (dotenv, hence the project URL and anon key) and sockets all work here.
///   * SharedPreferences — yes. `firebaseMessagingBackgroundHandler` already
///     reads `fsi_can_use` and the active couple through it.
///   * The persisted Supabase session — yes. supabase_flutter stores it as JSON
///     under `sb-<project-ref>-auth-token` in the same SharedPreferences
///     (supabase.dart:127, local_storage.dart:113).
///   * `SupabaseService.client` — NO. It is a `late final` assigned by
///     `SupabaseService.init()`, which only main() runs. Reading it here throws
///     LateInitializationError, so nothing below touches it.
///   * A safe `Supabase.initialize()` — NO, and this is the important one.
///     gotrue rotates the refresh token on every refresh, and gotrue 2.22.0
///     `_executeRefresh` signs the user OUT when a rotated token is retried and
///     the in-memory session is expired (gotrue_client.dart:1479-1499) — which
///     is exactly the state a backgrounded UI isolate is in, since
///     supabase_flutter stops auto-refresh on pause and restarts it on resume.
///     Supabase also revokes the whole token family on reuse detection, so both
///     halves lose the session. A couples app that silently signs someone out
///     has destroyed their pairing to save one tick.
///
/// So: if the app process is alive, the ack is handed to the UI isolate, which
/// owns the refresh token and refreshes on demand inside its own client
/// (supabase_client.dart:253). Only when there is demonstrably no UI isolate —
/// a push that woke a killed process, the case the whole silent push exists for
/// — does this isolate talk to the server itself, over plain HTTP, and then
/// READ-ONLY: it uses the stored access token while it is fresh and never
/// presents the refresh token (see [_accessToken] for the race that rule
/// closes).
class BackgroundReceiptAck {
  BackgroundReceiptAck._();

  /// Call from `firebaseMessagingBackgroundHandler` for `type == 'message'`,
  /// AFTER `Firebase.initializeApp` (the plugin bindings this needs come up
  /// with it) and after the couple guard has accepted the push.
  static Future<void> onMessagePush(Map<String, dynamic> data) async {
    // The edge function does not put `seq` in the payload today
    // (reach-notify/index.ts:246 sends message_id only). Read it anyway: the
    // day it does, this stops costing a round trip, and an old client that
    // never learns to read it is unaffected.
    final seq = int.tryParse('${data['seq']}') ?? 0;
    final app = DeliveryAckPort.liveApp;
    if (app != null) {
      app.send(seq);
      return;
    }
    await _ackWithoutTheApp(seq, data['couple_id'] as String?);
  }

  /// Treat the JWT as dead a minute early, so a slow request cannot land
  /// after expiry.
  static const _skew = Duration(seconds: 60);
  static const _budget = Duration(seconds: 15);

  static Future<void> _ackWithoutTheApp(int pushSeq, String? pushCouple) async {
    final client = TimeoutHttpClient(http.Client(), timeout: _budget);
    String? couple;
    var seq = pushSeq;
    try {
      if (!dotenv.isInitialized) await dotenv.load();
      final url = dotenv.maybeGet(MilesConfig.supabaseUrlKey) ?? '';
      final anon = dotenv.maybeGet(MilesConfig.supabaseAnonKeyKey) ?? '';
      if (url.isEmpty || anon.isEmpty) {
        debugPrint('[receipts] bg ack: no supabase config in this isolate');
        return;
      }
      couple = pushCouple ?? await SessionScope.readCouple();
      if (couple == null) return;

      final token = await _accessToken(client, url, anon);
      if (token == null) {
        // Signed out, or the refresh was refused. Owe it: the next resume acks
        // through the UI isolate, which can surface a real auth failure.
        if (seq > 0) await DeliveredMark.recordOwed(couple, seq);
        return;
      }
      if (seq <= 0) seq = await _highestSeq(client, url, anon, token, couple);
      if (seq <= 0) return;
      if (seq <= await DeliveredMark.acked(couple)) return;

      final res = await client.post(
        Uri.parse('$url/rest/v1/rpc/ack_delivered'),
        headers: {
          'apikey': anon,
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'p_seq': seq}),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        await DeliveredMark.recordAcked(couple, seq);
      } else {
        await DeliveredMark.recordOwed(couple, seq);
        debugPrint('[receipts] bg ack_delivered seq=$seq '
            'HTTP ${res.statusCode} ${res.body}');
      }
    } catch (e) {
      if (couple != null && seq > 0) {
        await DeliveredMark.recordOwed(couple, seq);
      }
      debugPrint('[receipts] bg ack failed at seq=$seq: $e');
    } finally {
      client.close();
    }
  }

  static Future<int> _highestSeq(
    http.Client c,
    String url,
    String anon,
    String token,
    String couple,
  ) async {
    // The couple id comes off a push payload. It has already been matched
    // against this handset's stored couple, but it is still remote input
    // reaching a query string, and `&` in it would add PostgREST parameters.
    final res = await c.get(
      Uri.parse('$url/rest/v1/messages?select=seq&order=seq.desc&limit=1'
          '&couple_id=eq.${Uri.encodeQueryComponent(couple)}'),
      headers: {'apikey': anon, 'Authorization': 'Bearer $token'},
    );
    if (res.statusCode != 200) {
      debugPrint('[receipts] bg highest seq HTTP ${res.statusCode}');
      return 0;
    }
    final rows = jsonDecode(res.body);
    if (rows is! List || rows.isEmpty) return 0;
    return JsonUtils.parseInt(JsonUtils.asMap(rows.first)['seq']);
  }

  /// Reads the session supabase_flutter persisted. NEVER refreshes it.
  ///
  /// This used to refresh an expired token in place, gated on "no UI isolate
  /// in this process" — and that gate has a window no port check can close:
  /// the push that cold-starts this process is often the very reason the user
  /// opens the app seconds later. This isolate's refresh then races the UI
  /// isolate's own cold-start refresh with the SAME stored token, and on a
  /// radio waking from doze either request can take 30-60s (measured 53s on
  /// the OnePlus 7, BRAIN §248). Two uses of one refresh token landing more
  /// than the server's 10s reuse-interval apart make gotrue revoke the whole
  /// token family — which is the "randomly signed out" a couples app can
  /// least afford, to save one delivery tick.
  ///
  /// So: one token holder, ever — the UI isolate. If the stored access token
  /// is still fresh it is used read-only (no rotation, no race); if it has
  /// expired, the ack is recorded as owed (the caller already does this on
  /// null) and the next app open pays the debt through the UI isolate's own
  /// client.
  static Future<String?> _accessToken(
      http.Client c, String url, String anon,) async {
    final prefs = await SharedPreferences.getInstance();
    // Built exactly as supabase_flutter builds it (supabase.dart:128-129).
    final key = 'sb-${Uri.parse(url).host.split('.').first}-auth-token';
    final raw = prefs.getString(key);
    if (raw == null) return null;

    final stored = JsonUtils.asMap(jsonDecode(raw));
    final access = stored['access_token'] as String?;
    if (access == null) return null;
    final expiry = _expiry(access);
    if (expiry != null && expiry.isAfter(DateTime.now().add(_skew))) {
      return access;
    }
    debugPrint('[receipts] bg token expired; ack owed, not refreshing '
        '(one refresh-token holder, ever)');
    return null;
  }

  /// `exp` out of the JWT itself, which is where gotrue reads it from too
  /// (session.dart:73) — the stored `expires_at` is a copy and can be absent.
  static DateTime? _expiry(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = JsonUtils.asMap(
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))),
      );
      final exp = payload['exp'];
      if (exp is! int) return null;
      return DateTime.fromMillisecondsSinceEpoch(exp * 1000);
    } catch (e) {
      debugPrint('[receipts] bg could not read token expiry: $e');
      return null;
    }
  }
}
