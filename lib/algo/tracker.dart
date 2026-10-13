import 'estimator.dart';

class TrackerConfig {
  /// Median over valid per-window estimates in the last [spanSec].
  final double spanSec;

  /// Minimum number of valid estimates in the span to report a value.
  final int minValid;

  const TrackerConfig({this.spanSec = 15, this.minValid = 5});

  Map<String, Object> toJson() => {'spanSec': spanSec, 'minValid': minValid};
}

/// Smooths the per-window estimates into the displayed rate. Feed estimates in
/// time order; same behaviour live and offline.
class RateTracker {
  static const version = 'median-v1';

  final TrackerConfig cfg;
  final _recent = <(int, double)>[];

  RateTracker([this.cfg = const TrackerConfig()]);

  void reset() => _recent.clear();

  /// Returns the tracked rate (breaths/min) after [e], or null if not enough
  /// valid estimates recently.
  double? update(Estimate e) {
    if (e.valid) _recent.add((e.tEndUs, e.bpmSpectral));
    final from = e.tEndUs - (cfg.spanSec * 1e6).round();
    _recent.removeWhere((r) => r.$1 < from);
    if (_recent.length < cfg.minValid) return null;
    final v = _recent.map((r) => r.$2).toList()..sort();
    final m = v.length ~/ 2;
    return v.length.isOdd ? v[m] : (v[m - 1] + v[m]) / 2;
  }
}
