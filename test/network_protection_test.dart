import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/widgets/common/network_protection_guard.dart';

void main() {
  test('NetworkProtectionGuard.checkInternet returns boolean without throwing', () async {
    final result = await NetworkProtectionGuard.checkInternet();
    expect(result, isA<bool>());
  });
}
