import 'dart:math' as math;

import 'estimator.dart';

/// Running total of breaths, merged from the onsets of successive windows.
/// Feed estimates in time order (same live and offline).
class BreathCounter {
  static const version = 'merge-v1';

  /// Onsets closer than this fraction of the current period to the last
  /// accepted one are treated as the same breath.
  final double minGapPeriods;

  /// Onsets within max(minMarginSec, marginPeriods × period) of the window
  /// end are not accepted yet (filter edge effects).
  final double minMarginSec;
  final double marginPeriods;

  final onsetsUs = <int>[];

  /// Total time covered by valid windows (where breaths can be counted).
  int coveredUs = 0;
  int _coveredEnd = 0;

  BreathCounter({
    this.minGapPeriods = 0.6,
    this.minMarginSec = 2,
    this.marginPeriods = 0.25,
  });

  int get total => onsetsUs.length;

  void reset() {
    onsetsUs.clear();
    coveredUs = 0;
    _coveredEnd = 0;
  }

  /// Time in [0, tUs] not covered by any valid window (motion, warm-up, weak
  /// signal), where breaths could not be counted.
  int uncountedUs(int tUs) => math.max(0, tUs - coveredUs);

  void update(Estimate e) => _merge(e, final_: false);

  /// Accepts onsets up to the window end; call once at the end of a session.
  void finish(Estimate e) => _merge(e, final_: true);

  void _merge(Estimate e, {required bool final_}) {
    if (!e.valid || e.best.peakFreq <= 0) return;
    final from = math.max(e.tStartUs, _coveredEnd);
    if (e.tEndUs > from) {
      coveredUs += e.tEndUs - from;
      _coveredEnd = e.tEndUs;
    }
    final periodUs = 1e6 / e.best.peakFreq;
    final minGap = (minGapPeriods * periodUs).round();
    final margin =
        final_ ? 0 : math.max(minMarginSec * 1e6, marginPeriods * periodUs);
    final limit = e.tEndUs - margin;
    for (final t in e.breathTimesUs) {
      if (t > limit) break;
      if (onsetsUs.isNotEmpty && t - onsetsUs.last < minGap) continue;
      onsetsUs.add(t);
    }
  }

  Map<String, Object> toJson() => {
        'version': version,
        'minGapPeriods': minGapPeriods,
        'minMarginSec': minMarginSec,
        'marginPeriods': marginPeriods,
        'total': total,
        'coveredSec': coveredUs / 1e6,
      };
}
