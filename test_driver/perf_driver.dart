import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/integration_test_driver.dart';

/// Writes a frame-timing summary per traced action to build/perf/.
Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    if (data == null) return;
    final out = <String, Object?>{};
    for (final key in data.keys) {
      final timeline = Timeline.fromJson(
        (data[key]! as Map).cast<String, dynamic>(),
      );
      final summary = TimelineSummary.summarize(timeline);
      await summary.writeTimelineToFile(
        key,
        destinationDirectory: 'build/perf',
        pretty: true,
        includeSummary: true,
      );
      final j = summary.summaryJson;
      out[key] = {
        for (final k in [
          'average_frame_build_time_millis',
          '90th_percentile_frame_build_time_millis',
          '99th_percentile_frame_build_time_millis',
          'worst_frame_build_time_millis',
          'average_frame_rasterizer_time_millis',
          '90th_percentile_frame_rasterizer_time_millis',
          '99th_percentile_frame_rasterizer_time_millis',
          'missed_frame_build_budget_count',
          'missed_frame_rasterizer_budget_count',
          'frame_count',
        ])
          k: j[k],
      };
    }
    File('build/perf/summary.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
  },
);
