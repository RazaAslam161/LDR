import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Every password gate in the app renders a failure as "that isn't your
/// password", and the check behind them used to answer failure to a 429, a
/// 5xx and a dead socket alike — so the emergency exit accused the owner of
/// mistyping a password they had typed correctly, and then showed nothing.
///
/// Pure, so it is pinnable: the network the exception arrives over is the part
/// a unit test cannot have, and the reading of it is the part that was wrong.
void main() {
  group('reauthOutcomeFor', () {
    test('400 is the credential being rejected', () {
      expect(
        reauthOutcomeFor(
          const AuthApiException(
            'Invalid login credentials',
            statusCode: '400',
            code: 'invalid_credentials',
          ),
        ),
        ReauthOutcome.wrongPassword,
      );
    });

    test('a rate limit is not a wrong password', () {
      // GoTrue's per-address limit is reachable by tapping twice, and this is
      // the case the old bare false was most likely to be lying about while
      // the network was otherwise up.
      expect(
        reauthOutcomeFor(
          const AuthApiException(
            'Request rate limit reached',
            statusCode: '429',
            code: 'over_request_rate_limit',
          ),
        ),
        ReauthOutcome.unavailable,
      );
    });

    test('a server error is not a wrong password', () {
      expect(
        reauthOutcomeFor(AuthRetryableFetchException(statusCode: '503')),
        ReauthOutcome.unavailable,
      );
    });

    test('a request that never got a reply is not a wrong password', () {
      // gotrue throws this with no status at all when the send itself failed,
      // which is why the reading is "400 means wrong" and not "anything else
      // means right".
      expect(
        reauthOutcomeFor(AuthRetryableFetchException()),
        ReauthOutcome.unavailable,
      );
    });
  });
}
