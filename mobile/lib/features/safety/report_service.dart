import 'package:miles/core/app/release_gate.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Why something is being reported.
///
/// The [wire] strings are one half of a CHECK constraint in
/// 20260816120000_ugc_terms_reports_and_contact_pause.sql. A value that is not
/// in the other half is a 23514 the user reads as "something went wrong", so
/// the pair is pinned by report_payload_test.
enum ReportReason {
  threats('threats', 'Threats or violence'),
  harassment('harassment', 'Harassment or abuse'),
  nonconsensualImagery(
      'nonconsensual_imagery', 'Intimate images shared without consent',),
  csam('csam', 'Sexual content involving a minor'),
  impersonation('impersonation', 'Pretending to be someone else'),
  spam('spam', 'Spam or a scam'),
  other('other', 'Something else');

  const ReportReason(this.wire, this.label);

  final String wire;
  final String label;
}

/// What is being reported. Same CHECK-constraint pairing as [ReportReason].
enum ReportTarget {
  partner('partner'),
  message('message'),
  galleryItem('gallery_item'),
  gif('gif'),
  reel('reel'),
  appContent('app_content');

  const ReportTarget(this.wire);

  final String wire;
}

/// Thrown when the daily limit refuses the report, so the sheet can say the
/// true thing instead of "try again" about something that will not work for
/// another day.
class ReportRateLimited implements Exception {
  const ReportRateLimited();
}

class ReportService {
  ReportService._();

  /// Files a report.
  ///
  /// Notice what is NOT sent: who is being reported. The RPC resolves that from
  /// the reporter's own couple, server-side. Accepting it here would let any
  /// account file reports against any uuid it could guess.
  static Future<void> submit({
    required ReportReason reason,
    required ReportTarget target,
    String? targetRef,
    String? note,
  }) async {
    try {
      await SupabaseService.client.rpc<void>('submit_report', params: {
        'p_reason': reason.wire,
        'p_target_kind': target.wire,
        'p_target_ref': targetRef,
        'p_note': note,
        'p_build': ReleaseGate.buildNumber,
      },);
    } on PostgrestException catch (e) {
      if (e.code == 'PT429') throw const ReportRateLimited();
      rethrow;
    }
  }
}
