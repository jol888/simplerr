import 'package:flutter/material.dart';

import '../algo/rec_format.dart';

const postures = ['仰卧-胸口', '仰卧-腹部', '侧卧', '坐姿', '其他'];

/// Asks for ground-truth labels after a recording. Returns null if skipped.
Future<Map<String, dynamic>?> showLabelDialog(
    BuildContext context, RecordingMeta meta) {
  final count = TextEditingController();
  final note = TextEditingController();
  var posture = postures.first;
  return showDialog<Map<String, dynamic>>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('标注这次录制'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('时长 ${meta.durationSec.toStringAsFixed(0)} 秒'),
              TextField(
                controller: count,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '你数的呼吸次数（整段，可留空）'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: posture,
                decoration: const InputDecoration(labelText: '姿势 / 位置'),
                items: [
                  for (final p in postures)
                    DropdownMenuItem(value: p, child: Text(p))
                ],
                onChanged: (v) => setState(() => posture = v ?? posture),
              ),
              TextField(
                controller: note,
                decoration: const InputDecoration(labelText: '备注'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('跳过')),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              'manualCount': int.tryParse(count.text.trim()),
              'posture': posture,
              'note': note.text.trim(),
            }),
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
}
