// Offline re-run of the estimator over exported recordings.
//
//   dart run tool/analyze.dart <rec_*.csv | dir>... [options]
//
// Options:
//   --window <s>   analysis window (default from EstimatorConfig)
//   --set k=v      override any EstimatorConfig field, repeatable (e.g. --set fLow=0.05)
//   --quiet        only print the summary block
//   --step <s>     step between windows (default 1)
//   --verbose      print every window
//   --dump <dir>   write <id>.est.csv (per window) and <id>.sig.csv (filtered
//                  signals over the longest still span) for plotting
import 'dart:io';
import 'dart:math' as math;

import 'package:breath/algo/pipeline.dart';
import 'package:breath/algo/estimator.dart';
import 'package:breath/algo/rec_format.dart';
import 'package:breath/algo/tracker.dart';

Future<void> main(List<String> args) async {
  final inputs = <String>[];
  double? window;
  var step = 1.0;
  var verbose = false;
  String? dump;
  var quiet = false;
  final overrides = <String, dynamic>{};
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--window':
        window = double.parse(args[++i]);
      case '--step':
        step = double.parse(args[++i]);
      case '--verbose':
        verbose = true;
      case '--dump':
        dump = args[++i];
      case '--set':
        final kv = args[++i].split('=');
        overrides[kv[0]] = double.parse(kv[1]);
      case '--quiet':
        quiet = true;
      default:
        inputs.add(args[i]);
    }
  }
  if (inputs.isEmpty) {
    stderr.writeln(
        'usage: dart run tool/analyze.dart <rec_*.csv|dir>... [--window s] [--step s] [--verbose] [--dump dir]');
    exit(64);
  }

  final files = <File>[];
  for (final p in inputs) {
    if (await FileSystemEntity.isDirectory(p)) {
      await for (final f in Directory(p).list()) {
        if (f is File && f.path.endsWith('.csv') && f.path.contains('rec_')) {
          files.add(f);
        }
      }
    } else {
      files.add(File(p));
    }
  }
  files.sort((a, b) => a.path.compareTo(b.path));

  final cfg = EstimatorConfig.fromJson({
    ...const EstimatorConfig().toJson(),
    if (window != null) 'windowSec': window,
    ...overrides,
  });
  final est = RespirationEstimator(cfg);
  if (dump != null) await Directory(dump).create(recursive: true);

  stdout
      .writeln('algo ${RespirationEstimator.version}  config ${cfg.toJson()}');
  stdout.writeln(
      'tracker ${RateTracker.version}  config ${const TrackerConfig().toJson()}');
  stdout.writeln();
  if (!quiet) {
    stdout.writeln(
        '${'recording'.padRight(24)} ${'dur'.padLeft(6)} ${'ref'.padLeft(6)} ${'median'.padLeft(7)} ${'track'.padLeft(6)} ${'jump'.padLeft(5)} ${'still'.padLeft(9)} ${'whole'.padLeft(6)} ${'count'.padLeft(5)} ${'exp'.padLeft(5)} ${'total'.padLeft(5)} ${'uncnt'.padLeft(5)} ${'manual'.padLeft(6)} ${'valid%'.padLeft(6)}  posture');
  }

  final errMedian = <double>[],
      errTrack = <double>[],
      errTotal = <double>[],
      errWhole = <double>[],
      errCount = <double>[];
  for (final f in files) {
    final rec = await loadCsv(f);
    final meta = await RecordingMeta.load(
        File(f.path.replaceAll(RegExp(r'\.csv$'), '.json')));
    final name = f.uri.pathSegments.last.replaceAll('.csv', '');
    final dur = rec.durationUs;

    final pipe =
        Pipeline.replay(rec, cfg, const TrackerConfig(), stepSec: step);
    final rows = pipe.estimates;
    final tracked = [for (final p in pipe.history) p.tracked];
    final counter = pipe.counter;
    final manual = meta?.manualCount;
    if (manual != null) errTotal.add((counter.total - manual).toDouble());
    final tv = tracked.whereType<double>().toList();
    final trackMedian =
        tv.isEmpty ? double.nan : (List.of(tv)..sort())[tv.length ~/ 2];
    var jump = 0.0;
    for (var i = 1; i < tracked.length; i++) {
      final a = tracked[i - 1], b = tracked[i];
      if (a != null && b != null) jump = math.max(jump, (b - a).abs());
    }
    final valid = rows.where((e) => e.valid).map((e) => e.bpmSpectral).toList()
      ..sort();
    final median = valid.isEmpty ? double.nan : valid[valid.length ~/ 2];
    final spans = est.stillSpans(rec);
    final still = spans.isEmpty
        ? null
        : spans.reduce((a, b) => b.$2 - b.$1 > a.$2 - a.$1 ? b : a);
    final whole =
        still == null ? null : est.estimate(rec, still.$2, tStartUs: still.$1);
    final ref = meta?.referenceBpm;
    final expected = ref == null || whole == null
        ? null
        : ref * (whole.tEndUs - whole.tStartUs) / 60e6;

    if (ref != null && !median.isNaN) errMedian.add(median - ref);
    if (ref != null && !trackMedian.isNaN) errTrack.add(trackMedian - ref);
    if (ref != null && whole != null) errWhole.add(whole.bpmSpectral - ref);
    if (expected != null) {
      errCount.add(whole!.breathCount - expected);
    }

    String f1(double? v) => v == null || v.isNaN ? '-' : v.toStringAsFixed(1);
    if (!quiet) {
      stdout.writeln([
        name.padRight(24),
        (dur / 1e6).toStringAsFixed(0).padLeft(6),
        f1(ref).padLeft(6),
        f1(median).padLeft(7),
        f1(trackMedian).padLeft(6),
        f1(jump).padLeft(5),
        (still == null ? '-' : '${still.$1 ~/ 1000000}-${still.$2 ~/ 1000000}')
            .padLeft(9),
        f1(whole?.bpmSpectral).padLeft(6),
        '${whole?.breathCount ?? '-'}'.padLeft(5),
        f1(expected).padLeft(5),
        '${counter.total}'.padLeft(5),
        '${counter.uncountedUs(dur) ~/ 1000000}s'.padLeft(5),
        '${manual ?? '-'}'.padLeft(6),
        (rows.isEmpty
                ? '-'
                : (100 * valid.length / rows.length).toStringAsFixed(0))
            .padLeft(6),
        ' ${meta?.posture ?? ''}',
      ].join(' '));
    }

    if (verbose) {
      for (final (i, e) in rows.indexed) {
        stdout.writeln('    t=${(e.tEndUs / 1e6).toStringAsFixed(0).padLeft(5)}'
            '  trk ${f1(tracked[i]).padLeft(5)}  spec ${f1(e.bpmSpectral).padLeft(5)}  count ${f1(e.bpmCount).padLeft(5)}'
            '  q ${e.quality.toStringAsFixed(2)}  snr ${e.best.snrDb.toStringAsFixed(1).padLeft(5)}  ${e.best.name.padRight(4)}'
            '  accStd ${e.motionAccStd.toStringAsFixed(3)}  gyroMax ${e.motionGyroMax.toStringAsFixed(3)}'
            '${e.valid ? '' : '  INVALID'}');
      }
    }

    if (dump != null) {
      final id = name.replaceFirst('rec_', '');
      final sb = StringBuffer(
          't_s,bpm_tracked,bpm_spectral,bpm_count,quality,snr_db,channel,motion_acc_std,motion_gyro_max,valid\n');
      for (final (i, e) in rows.indexed) {
        sb.writeln([
          (e.tEndUs / 1e6).toStringAsFixed(2),
          tracked[i]?.toStringAsFixed(2) ?? '',
          e.bpmSpectral.toStringAsFixed(2),
          e.bpmCount.isNaN ? '' : e.bpmCount.toStringAsFixed(2),
          e.quality.toStringAsFixed(4),
          e.best.snrDb.toStringAsFixed(2),
          e.best.name,
          e.motionAccStd.toStringAsFixed(4),
          e.motionGyroMax.toStringAsFixed(4),
          e.valid ? 1 : 0,
        ].join(','));
      }
      await File('$dump/$id.est.csv').writeAsString(sb.toString());
      if (whole != null) {
        final names = whole.channels.map((c) => c.name).toList();
        final sig = StringBuffer('t_s,${names.join(',')},breath\n');
        final breaths = whole.breathTimesUs
            .map((t) => ((t - whole.tStartUs) / 1e6 * whole.fs).round())
            .toSet();
        for (var i = 0; i < whole.best.signal.length; i++) {
          sig.writeln([
            (whole.tStartUs / 1e6 + i / whole.fs).toStringAsFixed(2),
            for (final c in whole.channels)
              c.signal[i].toStringAsExponential(4),
            breaths.contains(i) ? 1 : 0,
          ].join(','));
        }
        await File('$dump/$id.sig.csv').writeAsString(sig.toString());
      }
    }
  }

  void summary(String label, List<double> err) {
    if (err.isEmpty) return;
    final mae = err.map((e) => e.abs()).reduce((a, b) => a + b) / err.length;
    final bias = err.reduce((a, b) => a + b) / err.length;
    final worst = err.map((e) => e.abs()).reduce(math.max);
    stdout.writeln(
        '  ${label.padRight(28)} n=${err.length}  MAE ${mae.toStringAsFixed(2)}'
        '  bias ${bias.toStringAsFixed(2)}  worst ${worst.toStringAsFixed(2)}');
  }

  stdout.writeln();
  stdout.writeln('vs manual labels:');
  summary('median sliding (bpm)', errMedian);
  summary('median tracked (bpm)', errTrack);
  summary('still-span spectral (bpm)', errWhole);
  summary('still-span count (breaths)', errCount);
  summary('live total vs manual (breaths)', errTotal);
  if (errMedian.isEmpty && errCount.isEmpty) {
    stdout.writeln('  (no recordings with manualCount)');
  }
}
