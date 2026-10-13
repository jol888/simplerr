import 'dart:convert';
import 'dart:io';

import 'imu.dart';

/// Raw recording layout, one pair of files per session:
///   `rec_<id>.csv`   `t_us,sensor,x,y,z`  sensor ∈ {a: accelerometer m/s², g: gyroscope rad/s}
///   `rec_<id>.json`  metadata + labels (see [RecordingMeta])
const csvHeader = 't_us,sensor,x,y,z';
const formatVersion = 1;

class RecordingMeta {
  final Map<String, dynamic> json;

  RecordingMeta(this.json);

  String get id => json['id'] as String;
  double get durationSec => (json['durationSec'] as num?)?.toDouble() ?? 0;
  Map<String, dynamic> get label =>
      (json['label'] as Map?)?.cast<String, dynamic>() ?? {};

  /// Breaths the user counted during the whole recording, if provided.
  int? get manualCount => (label['manualCount'] as num?)?.toInt();
  String get posture => label['posture'] as String? ?? '';
  String get note => label['note'] as String? ?? '';

  double? get referenceBpm {
    final c = manualCount;
    return c == null || durationSec <= 0 ? null : c / durationSec * 60;
  }

  static Future<RecordingMeta?> load(File f) async {
    if (!await f.exists()) return null;
    return RecordingMeta(
        (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>());
  }

  Future<void> save(File f) =>
      f.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
}

ImuRecording parseCsv(String text) {
  final acc = <ImuSample>[], gyro = <ImuSample>[];
  for (final line in const LineSplitter().convert(text)) {
    if (line.isEmpty || line.startsWith('t_us') || line.startsWith('#')) {
      continue;
    }
    final p = line.split(',');
    if (p.length < 5) continue;
    final s = ImuSample(int.parse(p[0]), double.parse(p[2]), double.parse(p[3]),
        double.parse(p[4]));
    switch (p[1]) {
      case 'a':
        acc.add(s);
      case 'g':
        gyro.add(s);
    }
  }
  int byTime(ImuSample a, ImuSample b) => a.tUs.compareTo(b.tUs);
  acc.sort(byTime);
  gyro.sort(byTime);
  return ImuRecording(acc, gyro);
}

Future<ImuRecording> loadCsv(File f) async => parseCsv(await f.readAsString());

class CsvWriter {
  final IOSink _sink;
  final _buf = StringBuffer();
  int lines = 0;

  CsvWriter(File f) : _sink = f.openWrite() {
    _sink.writeln(csvHeader);
  }

  void add(String sensor, ImuSample s) {
    _buf
      ..write(s.tUs)
      ..write(',')
      ..write(sensor)
      ..write(',')
      ..write(s.x.toStringAsFixed(5))
      ..write(',')
      ..write(s.y.toStringAsFixed(5))
      ..write(',')
      ..writeln(s.z.toStringAsFixed(5));
    if (++lines % 200 == 0) flush();
  }

  void flush() {
    if (_buf.isEmpty) return;
    _sink.write(_buf.toString());
    _buf.clear();
  }

  Future<void> close() async {
    flush();
    await _sink.flush();
    await _sink.close();
  }
}
