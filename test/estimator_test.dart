import 'package:breath/algo/estimator.dart';
import 'package:breath/algo/imu.dart';
import 'package:breath/algo/rec_format.dart';
import 'package:breath/algo/synth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final est = RespirationEstimator();

  for (final bpm in [3.0, 4.0, 5.0, 6.5, 8.0, 12.0, 16.0, 24.0, 36.0]) {
    test('recovers $bpm bpm', () {
      final rec = synth(bpm: bpm);
      final e = est.estimate(rec, rec.durationUs)!;
      expect(e.valid, isTrue);
      expect(e.bpmSpectral, closeTo(bpm, 0.7));
      expect(e.bpmCount, closeTo(bpm, 1.5));
    });
  }

  for (final bpm in [4.0, 6.5, 9.0, 14.0]) {
    test('2nd harmonic stronger than fundamental at $bpm bpm', () {
      final rec = synth(bpm: bpm, harmonic: 1.3);
      final e = est.estimate(rec, rec.durationUs)!;
      expect(e.bpmSpectral, closeTo(bpm, 0.7));
      expect(e.bpmCount, closeTo(bpm, 1.5));
    });
  }

  test('accelerometer only', () {
    final rec = synth(bpm: 14);
    final e = est.estimate(ImuRecording(rec.acc, []), rec.durationUs)!;
    expect(e.channels, hasLength(1));
    expect(e.bpmSpectral, closeTo(14, 0.7));
  });

  test('whole-record breath count', () {
    final rec = synth(bpm: 15, seconds: 120);
    final e = est.estimate(rec, rec.durationUs, tStartUs: 0)!;
    expect(e.breathCount, inInclusiveRange(28, 31));
  });

  test('window starts after the last motion', () {
    final rec = synth(bpm: 6, seconds: 120, jerkAtSec: 40);
    final e = est.estimate(rec, rec.durationUs)!;
    expect(e.motion, isFalse);
    expect(e.tStartUs, greaterThan(41000000));
    expect(e.bpmSpectral, closeTo(6, 0.5));
  });

  test('flags motion', () {
    final rec = synth(bpm: 15, jerkAtSec: 45);
    final e = est.estimate(rec, rec.durationUs)!;
    expect(e.motion, isTrue);
    expect(e.valid, isFalse);
  });

  test('pure noise is not valid', () {
    final rec = synth(bpm: 15, tiltDeg: 0, noise: 0.05);
    final e = est.estimate(rec, rec.durationUs)!;
    expect(e.valid, isFalse);
  });

  test('csv round trip', () {
    final rec = synth(bpm: 15, seconds: 5);
    final sb = StringBuffer('$csvHeader\n');
    for (final s in rec.acc) {
      sb.writeln('${s.tUs},a,${s.x},${s.y},${s.z}');
    }
    for (final s in rec.gyro) {
      sb.writeln('${s.tUs},g,${s.x},${s.y},${s.z}');
    }
    final back = parseCsv(sb.toString());
    expect(back.acc.length, rec.acc.length);
    expect(back.gyro.length, rec.gyro.length);
    expect(back.acc.first.tUs, rec.acc.first.tUs);
  });
}
