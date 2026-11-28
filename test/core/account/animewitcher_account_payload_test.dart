import 'package:animewitcher/core/account/animewitcher_account_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('account boolean accepts legacy strings and numbers', () {
    for (final trueValue in [true, ' true ', '1', -1]) {
      expect(readAnimeWitcherPayloadBool(trueValue, false), isTrue);
    }
    for (final falseValue in [false, ' FALSE ', '0', 0]) {
      expect(readAnimeWitcherPayloadBool(falseValue, true), isFalse);
    }
    for (final fallback in [true, false]) {
      expect(readAnimeWitcherPayloadBool('unknown', fallback), fallback);
      expect(readAnimeWitcherPayloadBool(null, fallback), fallback);
    }
  });

  test('provider IDs drop invalid entries and preserve first occurrence', () {
    expect(
      readFirebaseProviderIds([
        null,
        'password',
        {'providerId': ' password '},
        {'providerId': ' '},
        {'providerId': 'google.com'},
        {'providerId': 'password'},
      ]),
      ['password', 'google.com'],
    );
    expect(readFirebaseProviderIds('password'), isEmpty);
  });
}
