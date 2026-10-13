import 'dart:math' as math;

import 'dsp.dart';
import 'imu.dart';

class EstimatorConfig {
  /// Internal processing rate after resampling.
  final double fs;
  final double windowSec;

  /// Shortest window used after trimming leading motion.
  final double minWindowSec;
  final double fLow, fHigh;
  final double fStep;

  /// Half-width of the band around the spectral peak counted as "signal".
  final double peakHalfWidth;

  /// Pick f/2 over the spectral peak f when P(f/2) ≥ this × P(f).
  final double subharmonicRatio;
  final double minQuality;

  /// Noise-floor reference band (no respiratory content), and the minimum
  /// peak-to-floor power density ratio.
  final double noiseLow, noiseHigh;
  final double minSnrDb;

  /// Hysteresis threshold for breath counting, as a fraction of signal std.
  final double hysteresis;

  /// Motion thresholds: std of |acc| in 1 s sub-windows (m/s²) and peak |gyro| (rad/s).
  final double motionAccStd;
  final double motionGyroMax;

  /// Margin trimmed off each side of a still span (settling after motion).
  final double settleSec;

  const EstimatorConfig({
    this.fs = 10,
    this.windowSec = 60,
    this.minWindowSec = 30,
    this.fLow = 0.04,
    this.fHigh = 0.8,
    this.fStep = 0.005,
    this.peakHalfWidth = 0.04,
    this.subharmonicRatio = 0.3,
    this.minQuality = 0.3,
    this.noiseLow = 1.5,
    this.noiseHigh = 4.5,
    this.minSnrDb = 10,
    this.hysteresis = 0.3,
    this.motionAccStd = 0.2,
    this.motionGyroMax = 0.6,
    this.settleSec = 2,
  });

  /// Missing keys fall back to defaults, so older metadata still loads.
  factory EstimatorConfig.fromJson(Map<String, dynamic> j) {
    const d = EstimatorConfig();
    double g(String k, double v) => (j[k] as num?)?.toDouble() ?? v;
    return EstimatorConfig(
      fs: g('fs', d.fs),
      windowSec: g('windowSec', d.windowSec),
      minWindowSec: g('minWindowSec', d.minWindowSec),
      fLow: g('fLow', d.fLow),
      fHigh: g('fHigh', d.fHigh),
      fStep: g('fStep', d.fStep),
      peakHalfWidth: g('peakHalfWidth', d.peakHalfWidth),
      subharmonicRatio: g('subharmonicRatio', d.subharmonicRatio),
      minQuality: g('minQuality', d.minQuality),
      noiseLow: g('noiseLow', d.noiseLow),
      noiseHigh: g('noiseHigh', d.noiseHigh),
      minSnrDb: g('minSnrDb', d.minSnrDb),
      hysteresis: g('hysteresis', d.hysteresis),
      motionAccStd: g('motionAccStd', d.motionAccStd),
      motionGyroMax: g('motionGyroMax', d.motionGyroMax),
      settleSec: g('settleSec', d.settleSec),
    );
  }

  Map<String, Object> toJson() => {
        'fs': fs,
        'windowSec': windowSec,
        'minWindowSec': minWindowSec,
        'fLow': fLow,
        'fHigh': fHigh,
        'fStep': fStep,
        'peakHalfWidth': peakHalfWidth,
        'subharmonicRatio': subharmonicRatio,
        'minQuality': minQuality,
        'noiseLow': noiseLow,
        'noiseHigh': noiseHigh,
        'minSnrDb': minSnrDb,
        'hysteresis': hysteresis,
        'motionAccStd': motionAccStd,
        'motionGyroMax': motionGyroMax,
        'settleSec': settleSec,
      };
}

class ChannelResult {
  final String name;
  final List<double> signal;
  final double peakFreq;

  /// Fraction of in-band power within ±peakHalfWidth of the peak.
  final double quality;

  /// Peak power density over the noise-band density, dB.
  final double snrDb;
  final double explainedVar;

  ChannelResult(this.name, this.signal, this.peakFreq, this.quality, this.snrDb,
      this.explainedVar);
}

class Estimate {
  final int tStartUs, tEndUs;
  final double fs;

  /// Rate from the spectral peak, breaths/min.
  final double bpmSpectral;

  /// Rate from counted cycles, breaths/min (NaN if < 2 breaths).
  final double bpmCount;

  /// Breaths counted in the window.
  final int breathCount;

  /// Breath onset times (µs since recording start).
  final List<int> breathTimesUs;

  final double quality;
  final bool motion;
  final double motionAccStd, motionGyroMax;
  final ChannelResult best;
  final List<ChannelResult> channels;
  final bool valid;

  Estimate({
    required this.tStartUs,
    required this.tEndUs,
    required this.fs,
    required this.bpmSpectral,
    required this.bpmCount,
    required this.breathCount,
    required this.breathTimesUs,
    required this.quality,
    required this.motion,
    required this.motionAccStd,
    required this.motionGyroMax,
    required this.best,
    required this.channels,
    required this.valid,
  });
}

/// v1: resample → detrend → zero-phase band-pass → PCA per sensor →
/// pick channel with the sharpest spectral peak → spectral rate + hysteresis
/// cycle count. Stateless per window, so phone and offline results match.
class RespirationEstimator {
  static const version = 'v1.7-count';

  final EstimatorConfig cfg;
  late final List<Biquad> _sections = [
    Biquad.highpass(cfg.fLow, cfg.fs),
    Biquad.highpass(cfg.fLow, cfg.fs),
    Biquad.lowpass(cfg.fHigh, cfg.fs),
    Biquad.lowpass(cfg.fHigh, cfg.fs),
  ];
  late final List<double> _freqs = [
    for (var f = cfg.fLow; f <= cfg.fHigh + 1e-9; f += cfg.fStep) f
  ];
  late final List<double> _noiseFreqs = [
    for (var f = cfg.noiseLow; f <= cfg.noiseHigh + 1e-9; f += 0.05) f
  ];

  RespirationEstimator([this.cfg = const EstimatorConfig()]);

  /// Estimate over the window ending at [tEndUs]. Pass [tStartUs] to override
  /// the configured window length (e.g. whole-recording analysis).
  ///
  /// Without [tStartUs], the window starts after the last motion inside it
  /// (plus settleSec) as long as at least minWindowSec remains, so one
  /// movement doesn't void a long window.
  Estimate? estimate(ImuRecording rec, int tEndUs, {int? tStartUs}) {
    var t0 = tStartUs ?? tEndUs - (cfg.windowSec * 1e6).round();
    if (tStartUs == null) {
      final minStart = tEndUs - (cfg.minWindowSec * 1e6).round();
      if (minStart < 0) return null;
      t0 = math.max(t0, 0);
      final after = _lastMotionEnd(rec, t0, tEndUs);
      if (after != null) {
        t0 = math.min(after + (cfg.settleSec * 1e6).round(), minStart);
      }
    }
    if (t0 < 0) return null;
    final n = ((tEndUs - t0) / 1e6 * cfg.fs).floor();
    if (n < cfg.fs * 10) return null;
    if (!_covers(rec.acc, t0, tEndUs)) return null;
    final hasGyro = _covers(rec.gyro, t0, tEndUs);

    final channels = <ChannelResult>[
      _channel('acc', rec.acc, t0, n),
      if (hasGyro) _channel('gyro', rec.gyro, t0, n),
    ];
    final best = channels.reduce((a, b) => b.quality > a.quality ? b : a);

    final (count, times) = _countBreaths(best.signal, t0, best.peakFreq);
    final bpmCount = times.length >= 2
        ? (times.length - 1) / ((times.last - times.first) / 1e6) * 60
        : double.nan;

    final (accStd, gyroMax) = _motion(rec, t0, tEndUs, hasGyro);
    final motion = accStd > cfg.motionAccStd || gyroMax > cfg.motionGyroMax;

    return Estimate(
      tStartUs: t0,
      tEndUs: tEndUs,
      fs: cfg.fs,
      bpmSpectral: best.peakFreq * 60,
      bpmCount: bpmCount,
      breathCount: count,
      breathTimesUs: times,
      quality: best.quality,
      motion: motion,
      motionAccStd: accStd,
      motionGyroMax: gyroMax,
      best: best,
      channels: channels,
      valid: !motion &&
          best.quality >= cfg.minQuality &&
          best.snrDb >= cfg.minSnrDb,
    );
  }

  /// Motion-free spans `(startUs, endUs)` at 1 s resolution, shrunk by
  /// [EstimatorConfig.settleSec] on each side.
  List<(int, int)> stillSpans(ImuRecording rec) {
    final settle = (cfg.settleSec * 1e6).round();
    return [
      for (final (a, b) in _rawStillSpans(rec))
        if (b - a > 2 * settle) (a + settle, b - settle)
    ];
  }

  List<(int, int)> _rawStillSpans(ImuRecording rec) {
    final spans = <(int, int)>[];
    final hasGyro = rec.gyro.isNotEmpty;
    int? start;
    final end = rec.durationUs;
    for (var ts = 0; ts < end; ts += 1000000) {
      final (a, g) = _motion(rec, ts, math.min(ts + 1000000, end), hasGyro);
      final still = a <= cfg.motionAccStd && g <= cfg.motionGyroMax;
      if (still) {
        start ??= ts;
      } else if (start != null) {
        spans.add((start, ts));
        start = null;
      }
    }
    if (start != null) spans.add((start, end));
    return spans;
  }

  /// End of the last 1 s block in [t0, t1) that contains motion, or null.
  int? _lastMotionEnd(ImuRecording rec, int t0, int t1) {
    final hasGyro = rec.gyro.isNotEmpty;
    for (var te = t1; te - 1000000 >= t0; te -= 1000000) {
      final (a, g) = _motion(rec, te - 1000000, te, hasGyro);
      if (a > cfg.motionAccStd || g > cfg.motionGyroMax) return te;
    }
    return null;
  }

  bool _covers(List<ImuSample> s, int t0, int t1) {
    if (s.isEmpty) return false;
    final i = lowerBound(s, t0);
    return i < s.length && s[i].tUs - t0 < 1e6 && t1 - s.last.tUs < 1e6;
  }

  ChannelResult _channel(String name, List<ImuSample> s, int t0, int n) {
    final xyz = resample(s, t0, cfg.fs, n);
    final pad = (cfg.fs * 10).round();
    for (final c in xyz) {
      detrend(c);
    }
    final filtered = [for (final c in xyz) filtfilt(c, _sections, pad)];
    final (v, ev) = pca1(filtered);
    final sig = project(filtered, v);
    final p = powerSpectrum(sig, cfg.fs, _freqs);
    var iMax = 0, total = 0.0;
    for (var i = 0; i < p.length; i++) {
      total += p[i];
      if (p[i] > p[iMax]) iMax = i;
    }
    // Asymmetric breathing can put more power in the 2nd harmonic than in
    // the fundamental; prefer f/2 when it carries a real peak.
    var iPeak = iMax;
    final iHalf = _argmaxNear(p, _freqs[iMax] / 2);
    if (iHalf != null && p[iHalf] >= cfg.subharmonicRatio * p[iMax]) {
      iPeak = iHalf;
    }
    final f0 = _freqs[iPeak];
    final (b1, n1) = _band(p, f0);
    final (b2, n2) = _band(p, 2 * f0);
    final density = math.max(b1 / n1, n2 > 0 ? b2 / n2 : 0.0);
    final noise = powerSpectrum(project(xyz, v), cfg.fs, _noiseFreqs);
    final floor = noise.reduce((a, b) => a + b) / noise.length;
    final snrDb = floor > 0
        ? 10 * math.log(density / floor) / math.ln10
        : double.infinity;
    return ChannelResult(
        name, sig, f0, total > 0 ? (b1 + b2) / total : 0, snrDb, ev);
  }

  /// Strict local maximum within ±peakHalfWidth of [f], or null.
  int? _argmaxNear(List<double> p, double f) {
    if (f < cfg.fLow) return null;
    final w = _halfWidth(f);
    int? best;
    for (var i = 0; i < p.length; i++) {
      if ((_freqs[i] - f).abs() > w) continue;
      if (best == null || p[i] > p[best]) best = i;
    }
    if (best == null || best == 0 || best == p.length - 1) return null;
    return p[best] > p[best - 1] && p[best] > p[best + 1] ? best : null;
  }

  /// Half-width around [f] that keeps f and 2f bands disjoint at low rates.
  double _halfWidth(double f) => math.min(cfg.peakHalfWidth, 0.3 * f);

  (double, int) _band(List<double> p, double f) {
    final w = _halfWidth(f);
    var sum = 0.0, bins = 0;
    for (var i = 0; i < p.length; i++) {
      if ((_freqs[i] - f).abs() <= w) {
        sum += p[i];
        bins++;
      }
    }
    return (sum, bins);
  }

  /// Counts on the signal low-passed just above [f0] (removes harmonics), with
  /// a minimum gap of half a period between onsets. The hysteresis threshold
  /// follows the local amplitude (RMS over ±1.5 periods).
  (int, List<int>) _countBreaths(List<double> sig, int t0, double f0) {
    final lp = Biquad.lowpass(math.min(1.5 * f0, cfg.fHigh), cfg.fs);
    final hp = Biquad.highpass(math.max(0.5 * f0, cfg.fLow), cfg.fs);
    final x = filtfilt(sig, [hp, lp, lp], (cfg.fs * 10).round());
    final rms = movingRms(x, (1.5 / f0 * cfg.fs).round());
    final minGap = (0.5 / f0 * cfg.fs).round();
    final times = <int>[];
    // Starting below zero counts as having seen the trough, so a first inhale
    // right after the window start isn't dropped.
    var state = x.isNotEmpty && x[0] < 0 ? -1 : 0, last = -minGap;
    for (var i = 0; i < x.length; i++) {
      final th = cfg.hysteresis * rms[i];
      if (x[i] > th && state <= 0) {
        if (state == -1 && i - last >= minGap) {
          times.add(t0 + (i / cfg.fs * 1e6).round());
          last = i;
        }
        state = 1;
      } else if (x[i] < -th && state >= 0) {
        state = -1;
      }
    }
    return (times.length, times);
  }

  (double, double) _motion(ImuRecording rec, int t0, int t1, bool hasGyro) {
    var accStd = 0.0;
    for (var ts = t0; ts < t1; ts += 1000000) {
      final mags = <double>[];
      for (var i = lowerBound(rec.acc, ts);
          i < rec.acc.length && rec.acc[i].tUs < ts + 1000000;
          i++) {
        final s = rec.acc[i];
        mags.add(math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z));
      }
      accStd = math.max(accStd, stddev(mags));
    }
    var gyroMax = 0.0;
    if (hasGyro) {
      for (var i = lowerBound(rec.gyro, t0);
          i < rec.gyro.length && rec.gyro[i].tUs < t1;
          i++) {
        final s = rec.gyro[i];
        gyroMax =
            math.max(gyroMax, math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z));
      }
    }
    return (accStd, gyroMax);
  }
}
