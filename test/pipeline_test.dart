import 'package:breath/algo/estimator.dart';
import 'package:breath/algo/imu.dart';
import 'package:breath/algo/pipeline.dart';
import 'package:breath/algo/synth.dart';
import 'package:breath/algo/tracker.dart';
import 'package:breath/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const ecfg = EstimatorConfig();
  const tcfg = TrackerConfig();

  test('live rolling buffer matches whole-recording replay', () {
    final rec = synth(bpm: 6, seconds: 150, jerkAtSec: 70);
    final replay = Pipeline.replay(rec, ecfg, tcfg);

    final live = Pipeline(ecfg, tcfg);
    final buf = ImuRecording([], []);
    var ia = 0, ig = 0;
    for (var t = 1000000; t <= rec.durationUs; t += 1000000) {
      while (ia < rec.acc.length && rec.acc[ia].tUs <= t) {
        buf.acc.add(rec.acc[ia++]);
      }
      while (ig < rec.gyro.length && rec.gyro[ig].tUs <= t) {
        buf.gyro.add(rec.gyro[ig++]);
      }
      final keepFrom = t - ((ecfg.windowSec + 5) * 1e6).round();
      for (final l in [buf.acc, buf.gyro]) {
        final i = lowerBound(l, keepFrom);
        if (i > 0) l.removeRange(0, i);
      }
      live.step(buf, t);
    }
    live.finish(buf, rec.durationUs);

    expect(live.history.length, replay.history.length);
    for (var i = 0; i < live.history.length; i++) {
      expect(live.history[i].bpm, closeTo(replay.history[i].bpm, 1e-9));
      expect(live.history[i].tracked, replay.history[i].tracked);
    }
    expect(live.counter.total, replay.counter.total);
  });

  test('replay counts breaths and reports uncounted motion time', () {
    final rec = synth(bpm: 6, seconds: 180, jerkAtSec: 90);
    final p = Pipeline.replay(rec, ecfg, tcfg);
    expect(p.medianTracked, closeTo(6, 0.5));
    expect(p.counter.total, inInclusiveRange(15, 18));
    expect(p.counter.uncountedUs(rec.durationUs), greaterThan(0));
  });

  test('settings map onto algorithm configs and round-trip', () {
    const s = AppSettings(
        windowSec: 90,
        minRateBpm: 3,
        smoothingSec: 5,
        motionTolerance: 2,
        themeMode: ThemeMode.dark);
    final e = s.estimatorConfig;
    expect(e.windowSec, 90);
    expect(e.fLow, closeTo(0.05, 1e-12));
    expect(e.motionGyroMax,
        closeTo(2 * const EstimatorConfig().motionGyroMax, 1e-12));
    expect(s.trackerConfig.spanSec, 5);
    expect(s.trackerConfig.minValid, lessThanOrEqualTo(5));
    final back = AppSettings.fromJson(s.toJson());
    expect(back.toJson(), s.toJson());
    expect(const AppSettings(windowSec: 30).estimatorConfig.minWindowSec, 30);
  });
}
