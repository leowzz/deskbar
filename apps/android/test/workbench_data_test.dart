import 'dart:convert';
import 'dart:typed_data';

import 'package:desklet/workbench_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'workbench_fixture.dart';

void main() {
  test('shortcut PNG is bounded and older or malformed icons fall back', () {
    final entry = Map<String, dynamic>.from(
      (snapshot()['shortcuts'] as List).single as Map,
    );
    expect(WorkShortcut(entry).iconBytes, isNotNull);
    entry.remove('icon_png');
    expect(WorkShortcut(entry).iconBytes, isNull);
    for (final bad in [
      '',
      'not base64!',
      base64Encode(List<int>.filled(32769, 0)),
      base64Encode(utf8.encode('https://example.com/icon.png')),
    ]) {
      entry['icon_png'] = bad;
      expect(WorkShortcut(entry).iconBytes, isNull);
    }
    final huge = base64Decode(shortcutIconPng);
    ByteData.sublistView(huge).setUint32(16, 4096);
    entry['icon_png'] = base64Encode(huge);
    expect(WorkShortcut(entry).iconBytes, isNull);
  });
  test(
    'older snapshots have no API usage; aggregate values keep exact units',
    () {
      expect(WorkbenchData(snapshot()).apiUsage, isEmpty);
      final value = snapshot();
      value['api_usage'] = [
        {
          'id': 'sub2api',
          'label': 'Sub2API · 今日',
          'actual_cost_micros': 1234567,
          'currency': 'USD',
          'token_count': 0,
          'tpm': 4500,
          'window_start': 100,
          'window_end': 86500,
        },
      ];
      final usage = WorkbenchData(value).apiUsage.single;
      expect(usage.actualCostMicros, 1234567);
      expect(usage.tokenCount, 0);
      expect(usage.tpm, 4500);
      expect(usage.currency, 'USD');
      expect(usage.windowEnd, 86500);
    },
  );
}
