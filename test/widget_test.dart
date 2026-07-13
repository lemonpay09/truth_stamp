import 'package:flutter_test/flutter_test.dart';

import 'package:truth_stamp/main.dart';

void main() {
  test('TruthStampApp can be constructed', () {
    expect(const TruthStampApp(cameras: []), isNotNull);
  });
}
