import 'dart:math' as math;

import 'imu.dart';

/// RBJ-cookbook biquad, Direct Form II transposed.
class Biquad {
  final double b0, b1, b2, a1, a2;

  const Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);

  factory Biquad.lowpass(double f0, double fs, [double q = math.sqrt1_2]) {
    final w0 = 2 * math.pi * f0 / fs;
    final c = math.cos(w0), alpha = math.sin(w0) / (2 * q);
    final a0 = 1 + alpha;
    return Biquad((1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0, -2 * c / a0,
        (1 - alpha) / a0);
  }

  factory Biquad.highpass(double f0, double fs, [double q = math.sqrt1_2]) {
    final w0 = 2 * math.pi * f0 / fs;
    final c = math.cos(w0), alpha = math.sin(w0) / (2 * q);
    final a0 = 1 + alpha;
    return Biquad((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0,
        -2 * c / a0, (1 - alpha) / a0);
  }

  /// Filters in place, with state initialised to the steady state for x[0].
  void apply(List<double> x) {
    if (x.isEmpty) return;
    final x0 = x[0];
    final y0 = x0 * (b0 + b1 + b2) / (1 + a1 + a2);
    var z2 = b2 * x0 - a2 * y0;
    var z1 = b1 * x0 - a1 * y0 + z2;
    for (var i = 0; i < x.length; i++) {
      final xi = x[i];
      final yi = b0 * xi + z1;
      z1 = b1 * xi - a1 * yi + z2;
      z2 = b2 * xi - a2 * yi;
      x[i] = yi;
    }
  }
}

/// Zero-phase filtering with odd-reflection padding.
List<double> filtfilt(List<double> x, List<Biquad> sections, int pad) {
  final n = x.length;
  if (n < 2) return List.of(x);
  pad = math.min(pad, n - 1);
  final y = List<double>.filled(n + 2 * pad, 0);
  for (var i = 0; i < pad; i++) {
    y[i] = 2 * x[0] - x[pad - i];
    y[n + pad + i] = 2 * x[n - 1] - x[n - 2 - i];
  }
  for (var i = 0; i < n; i++) {
    y[pad + i] = x[i];
  }
  for (final s in sections) {
    s.apply(y);
  }
  final r = y.reversed.toList();
  for (final s in sections) {
    s.apply(r);
  }
  return r.reversed.toList().sublist(pad, pad + n);
}

/// Box-average resampling of [s] onto a uniform grid of [n] points starting at
/// [t0Us]. Empty bins are linearly interpolated. Returns `[x, y, z]`.
List<List<double>> resample(List<ImuSample> s, int t0Us, double fs, int n) {
  final sum = List.generate(3, (_) => List<double>.filled(n, 0));
  final cnt = List<int>.filled(n, 0);
  final dtUs = 1e6 / fs;
  for (var i = lowerBound(s, t0Us - (dtUs ~/ 2)); i < s.length; i++) {
    final k = ((s[i].tUs - t0Us) / dtUs).round();
    if (k >= n) break;
    if (k < 0) continue;
    sum[0][k] += s[i].x;
    sum[1][k] += s[i].y;
    sum[2][k] += s[i].z;
    cnt[k]++;
  }
  final out = List.generate(3, (_) => List<double>.filled(n, double.nan));
  for (var k = 0; k < n; k++) {
    if (cnt[k] > 0) {
      for (var c = 0; c < 3; c++) {
        out[c][k] = sum[c][k] / cnt[k];
      }
    }
  }
  for (final ch in out) {
    _fillGaps(ch);
  }
  return out;
}

void _fillGaps(List<double> x) {
  final idx = [
    for (var i = 0; i < x.length; i++)
      if (!x[i].isNaN) i
  ];
  if (idx.isEmpty) {
    x.fillRange(0, x.length, 0);
    return;
  }
  x.fillRange(0, idx.first, x[idx.first]);
  x.fillRange(idx.last + 1, x.length, x[idx.last]);
  for (var k = 0; k + 1 < idx.length; k++) {
    final a = idx[k], b = idx[k + 1];
    for (var j = a + 1; j < b; j++) {
      x[j] = x[a] + (x[b] - x[a]) * (j - a) / (b - a);
    }
  }
}

void detrend(List<double> x) {
  final n = x.length;
  if (n < 2) return;
  final tm = (n - 1) / 2;
  var xm = 0.0;
  for (final v in x) {
    xm += v;
  }
  xm /= n;
  var num = 0.0, den = 0.0;
  for (var i = 0; i < n; i++) {
    num += (i - tm) * (x[i] - xm);
    den += (i - tm) * (i - tm);
  }
  final k = num / den;
  for (var i = 0; i < n; i++) {
    x[i] -= xm + k * (i - tm);
  }
}

/// Centered RMS over ±[half] samples (truncated at the edges).
List<double> movingRms(List<double> x, int half) {
  final n = x.length;
  final cum = List<double>.filled(n + 1, 0);
  for (var i = 0; i < n; i++) {
    cum[i + 1] = cum[i] + x[i] * x[i];
  }
  return List<double>.generate(n, (i) {
    final a = math.max(0, i - half), b = math.min(n, i + half + 1);
    return math.sqrt((cum[b] - cum[a]) / (b - a));
  });
}

double stddev(List<double> x) {
  if (x.isEmpty) return 0;
  var m = 0.0;
  for (final v in x) {
    m += v;
  }
  m /= x.length;
  var s = 0.0;
  for (final v in x) {
    s += (v - m) * (v - m);
  }
  return math.sqrt(s / x.length);
}

List<double> project(List<List<double>> ch, List<double> v) =>
    List<double>.generate(ch[0].length,
        (k) => ch[0][k] * v[0] + ch[1][k] * v[1] + ch[2][k] * v[2]);

/// First principal component of 3 channels: (unit vector, explained variance fraction).
(List<double>, double) pca1(List<List<double>> ch) {
  final n = ch[0].length;
  final cov = List.generate(3, (_) => List<double>.filled(3, 0));
  for (var i = 0; i < 3; i++) {
    for (var j = i; j < 3; j++) {
      var s = 0.0;
      for (var k = 0; k < n; k++) {
        s += ch[i][k] * ch[j][k];
      }
      cov[i][j] = cov[j][i] = s / n;
    }
  }
  var v = [1.0, 0.7, 0.4];
  var lambda = 0.0;
  for (var it = 0; it < 100; it++) {
    final w = List<double>.generate(
        3, (i) => cov[i][0] * v[0] + cov[i][1] * v[1] + cov[i][2] * v[2]);
    final norm = math.sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]);
    if (norm == 0) break;
    lambda = norm;
    v = [w[0] / norm, w[1] / norm, w[2] / norm];
  }
  final trace = cov[0][0] + cov[1][1] + cov[2][2];
  return (v, trace > 0 ? lambda / trace : 0);
}

/// Power spectrum (Hann-windowed DFT) evaluated at arbitrary frequencies.
List<double> powerSpectrum(List<double> x, double fs, List<double> freqs) {
  final n = x.length;
  final w = List<double>.generate(
      n, (i) => x[i] * (0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1))));
  return [
    for (final f in freqs)
      () {
        final dw = 2 * math.pi * f / fs;
        var re = 0.0, im = 0.0;
        for (var i = 0; i < n; i++) {
          re += w[i] * math.cos(dw * i);
          im -= w[i] * math.sin(dw * i);
        }
        return (re * re + im * im) / n;
      }()
  ];
}
