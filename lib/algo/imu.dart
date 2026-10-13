/// Pure Dart (no Flutter imports) so the same code runs on the phone and in
/// `tool/analyze.dart` on the desktop.
library;

class ImuSample {
  /// Microseconds since recording start.
  final int tUs;
  final double x, y, z;

  const ImuSample(this.tUs, this.x, this.y, this.z);
}

class ImuRecording {
  final List<ImuSample> acc;
  final List<ImuSample> gyro;

  ImuRecording(this.acc, this.gyro);

  int get durationUs {
    var end = 0;
    if (acc.isNotEmpty) end = acc.last.tUs;
    if (gyro.isNotEmpty && gyro.last.tUs > end) end = gyro.last.tUs;
    return end;
  }
}

/// Index of the first sample with `tUs >= t`.
int lowerBound(List<ImuSample> s, int t) {
  var lo = 0, hi = s.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (s[mid].tUs < t) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}
