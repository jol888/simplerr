import 'package:flutter/material.dart';

import 'settings.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsStore();
  await settings.load();
  runApp(BreathApp(settings: settings));
}

class BreathApp extends StatelessWidget {
  final SettingsStore settings;

  const BreathApp({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppSettings>(
      valueListenable: settings,
      builder: (context, s, _) => MaterialApp(
        title: 'simplerr',
        themeMode: s.themeMode,
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        darkTheme: ThemeData(
            colorSchemeSeed: Colors.teal,
            brightness: Brightness.dark,
            useMaterial3: true),
        home: HomePage(settings: settings),
      ),
    );
  }
}
