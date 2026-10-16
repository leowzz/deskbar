import 'package:desklet/workbench_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'workbench_fixture.dart';

void main() {
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
