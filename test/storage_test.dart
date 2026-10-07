import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumacaption/core/storage/settings.dart';

void main() {
  test(
    'credentials scoped to scheme host port; never part of settings export',
    () {
      expect(
        AppSettings.credentialAccount(Uri.parse('https://one.test/v1')),
        isNot(AppSettings.credentialAccount(Uri.parse('https://two.test/v1'))),
      );
      expect(
        AppSettings.credentialAccount(Uri.parse('https://one.test:8443')),
        isNot(AppSettings.credentialAccount(Uri.parse('https://one.test'))),
      );
      expect(
        jsonEncode(AppSettings().toJson()).toLowerCase(),
        isNot(contains('apikey')),
      );
    },
  );
}
