import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'services/storage.dart';

final ValueNotifier<ThemeMode> appThemeMode = ValueNotifier(ThemeMode.system);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Storage.init();
  runApp(const FreeScannerApp());
}

class FreeScannerApp extends StatelessWidget {
  const FreeScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'Free Scanner',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xff38675b), useMaterial3: true, inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder())),
        darkTheme: ThemeData(colorSchemeSeed: const Color(0xff78c9b1), brightness: Brightness.dark, useMaterial3: true),
        themeMode: mode,
        home: const HomeScreen(),
      ),
    );
  }
}
