import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/core/utils/json_utils.dart';
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
class ChatReceiptRepository {
  ChatReceiptRepository._();

  static final _c = SupabaseService.client;

  /// The partner has RECEIVED everything up to [seq] — not necessarily read.
  ///
  /// [trigger] names what caused the ack, and it is the whole point: this
  /// method has exactly ONE call site in the app, the chat screen's catch-up.
  /// If the field only ever reads chat_open or resume, then a message that
  /// arrived while the chat was closed was never delivered-acked at all, and
  /// the sender's tick cannot move until the recipient opens the conversation.
  static Future<void> ackDelivered(int seq, {required String trigger}) async {
    if (seq <= 0) {
      _traceAck('ack_delivered', seq, trigger, skipped: 'seq_not_positive');
      return;
    }
    final sw = Stopwatch()..start();
    try {
      await _c.rpc<dynamic>('ack_delivered', params: {'p_seq': seq});
      _traceAck('ack_delivered', seq, trigger,
          ok: true, ms: sw.elapsedMilliseconds,);
    } catch (e) {
      // Best-effort: a lost ack self-corrects on the next one, because the
      // server takes the max. It must never break sending or reading.
      _traceAck('ack_delivered', seq, trigger,
          ok: false, error: e, ms: sw.elapsedMilliseconds,);
      debugPrint('[receipts] ackDelivered failed: $e');
    }
  }

  /// The user has SEEN everything up to [seq].
  static Future<void> ackRead(int seq, {required String trigger}) async {
    if (seq <= 0) {
      _traceAck('ack_read', seq, trigger, skipped: 'seq_not_positive');
      return;
    }
    final sw = Stopwatch()..start();
    try {
      await _c.rpc<dynamic>('ack_read', params: {'p_seq': seq});
      _traceAck('ack_read', seq, trigger, ok: true, ms: sw.elapsedMilliseconds);
    } catch (e) {
      _traceAck('ack_read', seq, trigger,
          ok: false, error: e, ms: sw.elapsedMilliseconds,);
      debugPrint('[receipts] ackRead failed: $e');
    }
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
    } catch (e) {
      debugPrint('[receipts] fetchPartner failed: $e');
      return null;
    }
  }
}
