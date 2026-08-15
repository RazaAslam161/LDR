import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/safety/report_service.dart';

/// The Dart enums and the SQL CHECK constraints are one contract written in two
/// files, and nothing but this test joins them.
///
/// A value in the enum that is not in the CHECK is a 23514 at the moment
/// somebody files a report — which the user reads as "that didn't go through"
/// about the one screen where being ignored is the worst possible outcome. It
/// compiles, it passes analysis, and it only fails against a real database.
void main() {
  final migration = File('../supabase/migrations/'
      '20260816120000_ugc_terms_reports_and_contact_pause.sql');

  late String sql;

  setUpAll(() {
    expect(migration.existsSync(), isTrue,
        reason: 'the migration this test reads its expectations from is gone; '
            'without it the checks below pass by knowing nothing',);
    sql = migration.readAsStringSync();
  });

  /// The quoted values of `check (<column> in ( ... ))`, read out of the DDL.
  Set<String> checkValues(String column) {
    final m = RegExp('$column\\s+text not null check \\($column in \\((.*?)\\)\\)',
            dotAll: true,)
        .firstMatch(sql);
    expect(m, isNotNull, reason: 'no CHECK found for $column');
    return RegExp("'([a-z_]+)'")
        .allMatches(m!.group(1)!)
        .map((m) => m[1]!)
        .toSet();
  }

  test('every ReportReason is accepted by the reason CHECK', () {
    final allowed = checkValues('reason');
    expect(allowed, isNotEmpty);
    expect(ReportReason.values.map((r) => r.wire).toSet(), allowed);
  });

  test('every ReportTarget is accepted by the target_kind CHECK', () {
    final allowed = checkValues('target_kind');
    expect(allowed, isNotEmpty);
    expect(ReportTarget.values.map((t) => t.wire).toSet(), allowed);
  });

  test('csam and non-consensual imagery are both reportable', () {
    // Named rather than counted. These two are the reasons the whole feature
    // exists, and a refactor that tidied the enum down to "abuse" would pass
    // the set comparison above by changing both sides.
    expect(ReportReason.values.map((r) => r.wire),
        containsAll(['csam', 'nonconsensual_imagery']),);
  });

  test('app_content is a target, so a report needs no partner', () {
    // submit_report only resolves reported_user_id for other kinds. Without
    // this value, an unpaired account has nothing it can report at all.
    expect(ReportTarget.appContent.wire, 'app_content');
    expect(sql, contains("p_target_kind <> 'app_content'"));
  });

  test('every reason has a label a person can read', () {
    for (final r in ReportReason.values) {
      expect(r.label.trim(), isNotEmpty, reason: '${r.name} has no label');
      expect(r.label, isNot(equals(r.wire)),
          reason: '${r.name} shows the wire value to the user',);
    }
  });

  test('the reports table grants nothing and defines no select policy', () {
    // The safety property, asserted where it can rot: a screen listing the
    // reports you filed about your partner, on a phone that partner may pick
    // up, is the most dangerous thing this app could render. RLS denies what
    // it does not permit, so the absence IS the protection.
    expect(sql, contains('revoke all on public.content_reports'));
    expect(RegExp(r'create policy[^;]*on public\.content_reports').hasMatch(sql),
        isFalse,
        reason: 'a policy on content_reports makes the rows readable',);
  });
}
