import 'package:flutter/foundation.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';

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
  static Future<void> ackDelivered(int seq) async {
    if (seq <= 0) return;
    try {
      await _c.rpc<dynamic>('ack_delivered', params: {'p_seq': seq});
    } catch (e) {
      // Best-effort: a lost ack self-corrects on the next one, because the
      // server takes the max. It must never break sending or reading.
      debugPrint('[receipts] ackDelivered failed: $e');
    }
  }

  /// The user has SEEN everything up to [seq].
  static Future<void> ackRead(int seq) async {
    if (seq <= 0) return;
    try {
      await _c.rpc<dynamic>('ack_read', params: {'p_seq': seq});
    } catch (e) {
      debugPrint('[receipts] ackRead failed: $e');
    }
  }

  /// The partner's current position. Null when they have no row yet.
  static Future<ChatReceipt?> fetchPartner(
      String coupleId, String partnerId) async {
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
