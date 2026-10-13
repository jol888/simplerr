// Writes a synthetic recording in the export format, for sanity-checking the
// pipeline without a phone.
//
//   dart run tool/synth.dart <out_dir> [bpm=14] [seconds=90] [jerkAtSec]
import 'dart:io';

import 'package:breath/algo/rec_format.dart';
import 'package:breath/algo/synth.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
        'usage: dart run tool/synth.dart <out_dir> [bpm] [seconds] [jerkAtSec]');
    exit(64);
  }
  final bpm = args.length > 1 ? double.parse(args[1]) : 14.0;
  final seconds = args.length > 2 ? double.parse(args[2]) : 90.0;
  final jerk = args.length > 3 ? double.parse(args[3]) : null;
  final rec = synth(bpm: bpm, seconds: seconds, jerkAtSec: jerk);
  final id = 'synth_${bpm.toStringAsFixed(0)}bpm';
  final dir = await Directory(args[0]).create(recursive: true);

  final w = CsvWriter(File('${dir.path}/rec_$id.csv'));
  for (final s in rec.acc) {
    w.add('a', s);
  }
  for (final s in rec.gyro) {
    w.add('g', s);
  }
  await w.close();
  await RecordingMeta({
    'format': formatVersion,
    'id': id,
    'durationSec': seconds,
    'label': {
      'manualCount': (bpm * seconds / 60).round(),
      'posture': 'synthetic',
    },
  }).save(File('${dir.path}/rec_$id.json'));
  stdout.writeln('wrote ${dir.path}/rec_$id.{csv,json}');
}
