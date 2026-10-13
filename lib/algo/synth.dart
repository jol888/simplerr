import 'dart:math' as math;

import 'imu.dart';

/// Phone lying on a chest: gravity mostly on z, breathing tilts it by a
/// fraction of a degree about x.
ImuRecording synth({
  required double bpm,
  double seconds = 60,
  double fs = 50,
  double tiltDeg = 0.5,
  double noise = 0.02,
  int seed = 1,
  double? jerkAtSec,

  /// Amplitude of a 2nd-harmonic component relative to the fundamental
  /// (asymmetric inhale/exhale).
  double harmonic = 0,
}) {
  final rnd = math.Random(seed);
  double n() => (rnd.nextDouble() - 0.5) * 2 * noise;
  final acc = <ImuSample>[], gyro = <ImuSample>[];
  final w = 2 * math.pi * bpm / 60;
  final amp = tiltDeg * math.pi / 180;
  for (var i = 0; i < seconds * fs; i++) {
    final t = i / fs;
    final tUs = (t * 1e6).round() + rnd.nextInt(2000);
    var theta = amp * (math.sin(w * t) + harmonic * math.sin(2 * w * t + 1));
    var omega =
        amp * w * (math.cos(w * t) + 2 * harmonic * math.cos(2 * w * t + 1));
    if (jerkAtSec != null && (t - jerkAtSec).abs() < 1) {
      theta += 0.3 * math.sin(20 * t);
      omega += 6 * math.cos(20 * t);
    }
    acc.add(ImuSample(tUs, 0.1 + n(), 9.81 * math.sin(theta) + n(),
        9.81 * math.cos(theta) + n()));
    gyro.add(ImuSample(tUs, omega + n() * 0.05, n() * 0.05, n() * 0.05));
  }
  return ImuRecording(acc, gyro);
}
