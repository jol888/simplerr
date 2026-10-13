import 'package:flutter/material.dart';

import 'ui/home_page.dart';

void main() => runApp(const BreathApp());

class BreathApp extends StatelessWidget {
  const BreathApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '呼吸监测',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const HomePage(),
    );
  }
}
