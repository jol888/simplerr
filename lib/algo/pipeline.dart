import 'breath_counter.dart';
import 'estimator.dart';
import 'imu.dart';
import 'tracker.dart';

/// One step of the pipeline, kept for the trend chart and cursor.
class BpmPoint {
  final double tSec, bpm, bpmCount, quality, snrDb;
  final bool valid;
  final String channel;

  /// Smoothed rate from [RateTracker], null while not enough valid estimates.
  final double? tracked;

  /// Breaths counted so far.
  final int total;

  BpmPoint(this.tSec, Estimate e, this.tracked, this.total)
      : bpm = e.bpmSpectral,
        bpmCount = e.bpmCount,
        quality = e.quality,
        snrDb = e.best.snrDb,
        valid = e.valid,
        channel = e.best.name;
}

/// Estimator → tracker → counter. Used live, for history review and by
/// `tool/analyze.dart`, so all three produce identical results.
class Pipeline {
  final RespirationEstimator estimator;
  final RateTracker tracker;
  final BreathCounter counter = BreathCounter();

  /// Full estimates (with waveforms) are kept for at most this many steps;
  /// null keeps all.
  final int? keepEstimates;

  final history = <BpmPoint>[];
  final estimates = <Estimate>[];
  Estimate? latest;

  Pipeline(EstimatorConfig ecfg, TrackerConfig tcfg, {this.keepEstimates})
      : estimator = RespirationEstimator(ecfg),
        tracker = RateTracker(tcfg);

  double? get tracked => history.isEmpty ? null : history.last.tracked;

  /// Runs one window ending at [tEndUs]. Returns null if there isn't enough
  /// data yet.
  BpmPoint? step(ImuRecording rec, int tEndUs) {
    final e = estimator.estimate(rec, tEndUs);
    if (e == null) return null;
    latest = e;
    final t = tracker.update(e);
    counter.update(e);
    final p = BpmPoint(tEndUs / 1e6, e, t, counter.total);
    history.add(p);
    estimates.add(e);
    final keep = keepEstimates;
    if (keep != null && estimates.length > keep) estimates.removeAt(0);
    return p;
  }

  /// Accepts the remaining breaths at the end of a session.
  void finish(ImuRecording rec, int tEndUs) {
    final e = estimator.estimate(rec, tEndUs);
    if (e != null) counter.finish(e);
  }

  /// Buffered estimate whose window ends closest to [tSec] (within 1.5 × step).
  Estimate? estimateAt(double tSec, {double stepSec = 1}) {
    Estimate? best;
    for (final e in estimates) {
      if (best == null ||
          (e.tEndUs / 1e6 - tSec).abs() < (best.tEndUs / 1e6 - tSec).abs()) {
        best = e;
      }
    }
    return best != null && (best.tEndUs / 1e6 - tSec).abs() <= 1.5 * stepSec
        ? best
        : null;
  }

  /// Median of the tracked rate over the whole run.
  double? get medianTracked {
    final v = history.map((p) => p.tracked).whereType<double>().toList()
      ..sort();
    return v.isEmpty ? null : v[v.length ~/ 2];
  }

  /// Runs over a whole recording with windows every [stepSec].
  static Pipeline replay(
      ImuRecording rec, EstimatorConfig ecfg, TrackerConfig tcfg,
      {double stepSec = 1, int? keepEstimates}) {
    final p = Pipeline(ecfg, tcfg, keepEstimates: keepEstimates);
    final dur = rec.durationUs;
    final step = (stepSec * 1e6).round();
    for (var t = (ecfg.minWindowSec * 1e6).round(); t <= dur; t += step) {
      p.step(rec, t);
    }
    if (p.history.isNotEmpty) p.finish(rec, dur);
    return p;
  }
}
