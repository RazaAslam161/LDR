import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The share-quality digest, end to end through the reporter.
///
/// The server CHECK caps `detail` at 64 characters and the reporter discards
/// free text by design — a digest that renders long, or rides any path other
/// than the typed `_detail` case, produces a row nobody ever sees. These pin
/// the row exactly as production would insert it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ErrorReporter.resetForTest();
  });

  ShareQualityDigest digest({
    String codec = 'h264',
    int durationS = 87,
  }) =>
      ShareQualityDigest(
        codec: codec,
        finalRung: 2,
        topRung: 3,
        durationS: durationS,
        climbs: 4,
        falls: 1,
        cpu: 12,
        bw: 0,
        fpsP50: 14,
        bweKbps: 2300,
        endReason: 0,
      );

  test('the row carries the digest, inside every server ceiling', () async {
    final rows = <Map<String, Object?>>[];
    ErrorReporter.insertRow = (row) async => rows.add(row);

    ErrorReporter.report(digest(), StackTrace.current,
        kind: 'share-quality',);
    await Future<void>.delayed(Duration.zero);

    expect(rows, hasLength(1));
    expect(rows.single['kind'], 'share-quality');
    expect(rows.single['error_type'], 'ShareQualityDigest');
    final detail = rows.single['detail']! as String;
    expect(detail, 'h264 r2/3 87s c4 f1 cpu12 bw0 fps14 bwe2300 e0');
    expect(detail.length, lessThanOrEqualTo(64),
        reason: 'the server CHECK rejects longer and the row dies unseen',);
    expect(
      detail,
      matches(RegExp(r'^\w+ r\d+/\d+ \d+s c\d+ f\d+ cpu\d+ bw\d+ '
          r'fps\d+ bwe\d+ e\d$',),),
    );
  });

  test('a worst-case digest still fits the 64-char ceiling', () async {
    final rows = <Map<String, Object?>>[];
    ErrorReporter.insertRow = (row) async => rows.add(row);

    ErrorReporter.report(
      ShareQualityDigest(
        codec: 'unknown',
        finalRung: 3,
        topRung: 3,
        durationS: 86400,
        climbs: 999,
        falls: 999,
        cpu: 86400,
        bw: 86400,
        fpsP50: 60,
        bweKbps: 99999,
        endReason: 2,
      ),
      StackTrace.current,
      kind: 'share-quality',
    );
    await Future<void>.delayed(Duration.zero);

    expect(rows, hasLength(1));
    expect((rows.single['detail']! as String).length, lessThanOrEqualTo(64));
  });
}
